import Foundation
import MajorTomCore

public enum ProjectStatus: Sendable, Equatable {
    /// Recent activity.
    case active
    /// No activity for longer than the stale threshold, and something to strip.
    case stale
    /// The user pinned it: never offered for hibernation.
    case pinned
    /// Hibernated earlier and nothing has been reinstalled since.
    case hibernated

    public var label: String {
        switch self {
        case .active: "Active"
        case .stale: "Stale"
        case .pinned: "Pinned"
        case .hibernated: "Hibernating"
        }
    }
}

/// Project discovery and hibernation (M3). Hibernation goes through the same review sheet, clean engine,
/// measured result and history as every other clean.
extension GroundControlModel {
    // MARK: Lists and totals

    /// Projects not ignored by the user, in discovery order.
    public var visibleProjects: [Project] {
        let ignored = Set(settings.ignoredProjects)
        return projects.filter { !ignored.contains($0.path.path) }
    }

    public func project(path: String) -> Project? { projects.first { $0.path.path == path } }

    public func isPinned(_ project: Project) -> Bool { settings.pinnedProjects.contains(project.path.path) }

    public func status(of project: Project, now: Date = Date()) -> ProjectStatus {
        if isPinned(project) { return .pinned }
        if project.strippable.isEmpty, hibernations[project.path.path] != nil { return .hibernated }
        return project.isStale(afterDays: settings.staleAfterDays, now: now) ? .stale : .active
    }

    /// Stale (not pinned) projects that still have something to strip.
    public var staleProjects: [Project] {
        visibleProjects.filter { status(of: $0) == .stale && !$0.strippable.isEmpty }
    }

    public var staleStrippable: Int64 { staleProjects.reduce(0) { $0 + $1.strippableSize } }

    public var allStrippable: Int64 {
        visibleProjects.filter { !isPinned($0) }.reduce(0) { $0 + $1.strippableSize }
    }

    public var isScanningProjects: Bool { if case .scanning = projectScanState { true } else { false } }

    // MARK: Scanning

    /// Discovers projects (fast, list appears first), then measures their strippable directories.
    public func scanProjects() async {
        let scanner = environment.projectScanner(settings: settings)
        projectScanState = .scanning(completed: 0, total: 0)
        let start = Date()
        let found = await scanner.discover()
        if Task.isCancelled { return }
        // Keep known sizes while the new ones are measured, so the list doesn't flash empty on a rescan.
        let previous = Dictionary(projects.flatMap(\.strippable).map { ($0.path.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        projects = found.map { p in
            var p = p
            for i in p.strippable.indices { p.strippable[i].size = previous[p.strippable[i].path.path] ?? nil }
            return p
        }
        projectsSized = false
        pruneProjectSelection()
        let total = found.reduce(0) { $0 + $1.strippable.count }
        projectScanState = .scanning(completed: 0, total: total)
        let sized = await ProjectScanner.sized(found)
        if Task.isCancelled { return }
        projects = sized
        projectsSized = true
        pruneProjectSelection()
        projectScanState = .done(at: Date(), duration: Date().timeIntervalSince(start))
    }

    public func startProjectScan() {
        projectScanTask?.cancel()
        projectScanTask = Task { await self.scanProjects() }
    }

    /// Starts the first project scan if none has run, and waits for the current one either way.
    public func scanProjectsIfNeeded() async {
        if projectScanTask == nil, projectScanState == .idle { startProjectScan() }
        await projectScanTask?.value
    }

    // MARK: Selection

    /// Only unpinned projects with something to strip can be selected.
    public func canHibernate(_ project: Project) -> Bool {
        !isPinned(project) && !project.strippable.isEmpty && !settings.ignoredProjects.contains(project.path.path)
    }

    public func isProjectChecked(_ project: Project) -> Bool { checkedProjects.contains(project.path.path) }

    public func setProjectChecked(_ on: Bool, _ project: Project) {
        if on, canHibernate(project) {
            checkedProjects.insert(project.path.path)
        } else {
            checkedProjects.remove(project.path.path)
        }
    }

    /// Replaces the project selection with every stale, unpinned project that has something to strip.
    public func selectStaleProjects() {
        checkedProjects = Set(staleProjects.filter(canHibernate).map(\.path.path))
    }

    private func pruneProjectSelection() {
        checkedProjects = checkedProjects.filter { path in project(path: path).map(canHibernate) ?? false }
    }

    // MARK: Hibernation

    /// The review plan for hibernating the given projects (default: the checked ones).
    public func hibernationPlan(paths: Set<String>? = nil) -> CleanPlan {
        let wanted = paths ?? checkedProjects
        let groups: [CleanPlan.Group] = visibleProjects.filter { wanted.contains($0.path.path) && canHibernate($0) }.map { p in
            let rule = ProjectHibernation.rule(path: p.path, project: p, git: environment.git)
            let items = p.strippable.map {
                Item(id: $0.path.path, displayName: $0.relativePath, path: $0.path, size: $0.size, note: $0.reason,
                     methodOverride: .delete)
            }
            return CleanPlan.Group(ruleID: rule.id, title: String(localized: "Hibernate \(p.relativePath)"), tier: rule.tier,
                                   impact: rule.impact, recovery: rule.recovery, regenCost: rule.regenCost,
                                   items: items, actions: [], warnings: p.warnings, notes: p.notes)
        }
        return CleanPlan(groups: groups)
    }

    /// Opens the review sheet for hibernating the checked projects (or `paths`).
    public func reviewHibernation(paths: Set<String>? = nil) async {
        await review(hibernationPlan(paths: paths))
    }

    func recordHibernations(_ report: CleanReport) {
        let records = HibernationRecord.records(from: report, projects: projects)
        do {
            try environment.hibernations.append(records)
        } catch {
            settingsError = "Couldn't record the hibernation: \(error.localizedDescription)"
        }
        checkedProjects.removeAll()
        reloadHibernations()
    }

    public func reloadHibernations() {
        hibernations = environment.hibernations.latestByProject()
    }

    // MARK: Pin / ignore / settings

    public func setPinned(_ on: Bool, _ project: Project) {
        let path = project.path.path
        updateSettings { s in
            s.pinnedProjects.removeAll { $0 == path }
            if on { s.pinnedProjects.append(path) }
        }
        if on { checkedProjects.remove(path) }
    }

    public func ignoreProject(_ project: Project) {
        let path = project.path.path
        updateSettings { s in if !s.ignoredProjects.contains(path) { s.ignoredProjects.append(path) } }
        checkedProjects.remove(path)
    }

    public func unignoreProject(path: String) {
        updateSettings { s in s.ignoredProjects.removeAll { $0 == path } }
    }

    public func unpinProject(path: String) {
        updateSettings { s in s.pinnedProjects.removeAll { $0 == path } }
    }

    public func setStaleAfterDays(_ days: Int) {
        updateSettings { $0.staleAfterDays = min(3650, max(1, days)) }
    }

    /// The project folders in use: the user's list, or the common ones detected in the home folder.
    public var projectRoots: [String] { settings.effectiveProjectRoots(home: environment.context.home) }

    /// Adds a root (stored with `~` when inside the home folder) and rescans projects. The first change turns
    /// automatic detection into an explicit list (starting from what was detected).
    public func addProjectRoot(_ url: URL) {
        let home = environment.context.home.path
        var path = url.standardizedFileURL.path
        if path == home { path = "~" } else if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        let current = projectRoots
        guard !current.contains(path) else { return }
        updateSettings { $0.projectRoots = current + [path] }
        startProjectScan()
    }

    /// Removes a root (the list may become empty: the Projects view then asks for a folder).
    public func removeProjectRoot(_ root: String) {
        let current = projectRoots
        updateSettings { $0.projectRoots = current.filter { $0 != root } }
        startProjectScan()
    }

    /// Back to detecting the common project folders automatically.
    public func useDetectedProjectRoots() {
        updateSettings { $0.projectRoots = nil }
        startProjectScan()
    }

    // MARK: Own bundle-ID prefixes (orphaned app data)

    public func addOwnBundleIDPrefix(_ prefix: String) {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.contains("."), !settings.ownBundleIDPrefixes.contains(p) else { return }
        updateSettings { $0.ownBundleIDPrefixes.append(p) }
    }

    public func removeOwnBundleIDPrefix(_ prefix: String) {
        updateSettings { $0.ownBundleIDPrefixes.removeAll { $0 == prefix } }
    }

    // MARK: Fixture-only automation

    /// `--demo hibernate-review` opens the review for every stale fixture project; `--demo hibernate` also confirms.
    func runHibernateDemo(confirm: Bool) async {
        guard environment.isFixture else { return }
        await scanProjects()
        selectStaleProjects()
        await reviewHibernation()
        if confirm { await confirmClean() }
    }
}
