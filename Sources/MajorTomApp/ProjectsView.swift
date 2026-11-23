import AppKit
import GroundControl
import MajorTomCore
import SwiftUI

/// Projects under the configured roots: which are stale, what hibernating them frees, and how to get it back.
struct ProjectsView: View {
    @Environment(GroundControlModel.self) private var model
    @State private var selection: Project.ID?
    @State private var filter: Filter = .all
    @State private var sortOrder = [KeyPathComparator(\ProjectRow.size, order: .reverse)]

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", stale = "Stale", active = "Active", pinned = "Pinned", hibernating = "Hibernating"
        var id: String { rawValue }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            ProjectsHeader(filter: $filter)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if model.projectRoots.isEmpty {
                ContentUnavailableView {
                    Label("No project folders", systemImage: "folder.badge.plus")
                } description: {
                    Text("None of the usual project folders (~/Projects, ~/Developer, ~/Code, ~/src, ~/WebstormProjects, …) exist on this Mac. Add the folder your projects live in; you can change the list in Settings → Projects.")
                } actions: {
                    Button("Add Project Folder…") { FolderPickers.addProjectRoot(model) }
                        .primaryActionButtonStyle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                projectsContent(rows)
            }
        }
        .overlay {
            if model.projects.isEmpty, !model.projectRoots.isEmpty {
                if model.isScanningProjects || model.projectScanState == .idle {
                    ProgressView("Looking for projects…")
                } else {
                    ContentUnavailableView {
                        Label("No projects found", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Major Tom looks in \(model.projectRoots.joined(separator: ", ")).")
                    } actions: {
                        Button("Add Project Folder…") { FolderPickers.addProjectRoot(model) }
                    }
                }
            }
        }
        .task { await model.scanProjectsIfNeeded() }
        .task(id: model.projectsSized) {
            // Dev aid for snapshots: `--select-project <relative path>`.
            if selection == nil, let rel = Snapshotter.argument("--select-project") {
                try? await Task.sleep(for: .milliseconds(200))
                selection = model.projects.first { $0.relativePath == rel }?.id
            }
        }
    }

    private func projectsContent(_ rows: [ProjectRow]) -> some View {
        GeometryReader { geo in
            let tableHeight = max(170, (geo.size.height * 0.55).rounded())
            VStack(spacing: 0) {
                ProjectTable(rows: rows, selection: $selection, sortOrder: $sortOrder)
                    // Rebuilt (not row-animated) when measuring finishes and the order settles.
                    .id(model.projectsSized)
                    .frame(height: tableHeight)
                Divider()
                Group {
                    if let id = selection, let project = model.project(path: id) {
                        ProjectDetail(project: project)
                    } else {
                        Text(rows.isEmpty ? "" : "Select a project to see what hibernating it removes.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var rows: [ProjectRow] {
        model.visibleProjects
            .map { ProjectRow(project: $0, status: model.status(of: $0)) }
            .filter { row in
                switch filter {
                case .all: true
                case .stale: row.status == .stale
                case .active: row.status == .active
                case .pinned: row.status == .pinned
                case .hibernating: row.status == .hibernated
                }
            }
            // Sizes arrive after discovery; sorting by them before they're all in makes rows jump around
            // (and trips an NSTableView reentrancy warning), so keep name order until measuring is done.
            .sorted(using: model.projectsSized || !sortOrder.contains { $0.keyPath == \ProjectRow.size }
                    ? sortOrder : [KeyPathComparator(\ProjectRow.name)])
    }
}

struct ProjectRow: Identifiable {
    let project: Project
    let status: ProjectStatus
    var id: String { project.id }
    var name: String { project.relativePath }
    var size: Int64 { project.strippableSize }
    var activity: Date { project.lastActivity ?? .distantPast }
    var statusOrder: Int {
        switch status {
        case .stale: 0
        case .active: 1
        case .hibernated: 2
        case .pinned: 3
        }
    }
}

private struct ProjectsHeader: View {
    @Environment(GroundControlModel.self) private var model
    @Binding var filter: ProjectsView.Filter

    var body: some View {
        let stale = model.staleProjects
        let staleCount = model.visibleProjects.filter { model.status(of: $0) == .stale }.count
        let checked = model.hibernationPlan()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects").font(.title2.weight(.semibold))
                if model.isScanningProjects {
                    ProgressView().controlSize(.small)
                    Text(model.projects.isEmpty ? "Looking for projects…" : "Measuring…").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.startProjectScan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.isScanningProjects)
            }
            Text(summary(staleCount: staleCount))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(ProjectsView.Filter.allCases) { Text(localized($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Select Stale") { model.selectStaleProjects() }
                    .disabled(stale.isEmpty)
                    .help("Select every stale, unpinned project that has something to strip")
                if !model.checkedProjects.isEmpty {
                    Button("Deselect") { model.checkedProjects.removeAll() }
                }
                Button {
                    Task { await model.reviewHibernation() }
                } label: {
                    Text(checked.isEmpty ? "Hibernate…"
                         : "Hibernate \(checked.groups.count) (\(ByteFormat.string(checked.estimatedBytes)))…")
                }
                .primaryActionButtonStyle()
                .disabled(checked.isEmpty || model.cleanSession != nil)
                .help("Review exactly which directories go before anything is removed")
            }
            .controlSize(.regular)
        }
    }

    private func summary(staleCount: Int) -> String {
        let projects = model.visibleProjects
        guard !projects.isEmpty else {
            return model.projectRoots.isEmpty ? String(localized: "No project folders yet") : String(localized: "Looking in \(model.projectRoots.joined(separator: ", "))")
        }
        var text = String(localized: "\(projects.count) projects · \(staleCount) stale (no activity for \(model.settings.staleAfterDays)+ days)")
        if model.projectsSized {
            text += String(localized: " · \(ByteFormat.string(model.staleStrippable)) strippable in stale projects, \(ByteFormat.string(model.allStrippable)) in all")
        }
        return text
    }
}

private struct ProjectTable: View {
    @Environment(GroundControlModel.self) private var model
    let rows: [ProjectRow]
    @Binding var selection: Project.ID?
    @Binding var sortOrder: [KeyPathComparator<ProjectRow>]

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                Toggle(isOn: Binding(get: { model.isProjectChecked(row.project) },
                                     set: { model.setProjectChecked($0, row.project) })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!model.canHibernate(row.project))
            }
            .width(22)

            TableColumn("Project", value: \.name) { row in
                ProjectNameCell(project: row.project)
            }
            .width(min: 200, ideal: 330)

            TableColumn("Status", value: \.statusOrder) { row in
                ProjectStatusBadge(status: row.status)
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Last activity", value: \.activity) { row in
                if let date = row.project.lastActivity {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Strippable", value: \.size) { row in
                Group {
                    if row.project.strippable.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else if model.projectsSized || row.size > 0 {
                        Text(ByteFormat.string(row.size)).monospacedDigit()
                    } else {
                        Text("measuring…").foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 96, max: 120)
        }
        .contextMenu(forSelectionType: Project.ID.self) { ids in
            if let id = ids.first, let project = model.project(path: id) {
                ProjectMenu(project: project)
            }
        } primaryAction: { ids in
            for id in ids {
                if let p = model.project(path: id) { model.setProjectChecked(!model.isProjectChecked(p), p) }
            }
        }
        .onKeyPress(.space) {
            guard let id = selection, let p = model.project(path: id) else { return .ignored }
            model.setProjectChecked(!model.isProjectChecked(p), p)
            return .handled
        }
    }
}

private struct ProjectNameCell: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(project.name).lineLimit(1).truncationMode(.middle)
                if !project.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(project.warnings.joined(separator: "\n"))
                }
            }
            let parent = (project.relativePath as NSString).deletingLastPathComponent
            Text(parent.isEmpty ? project.root.lastPathComponent : parent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(project.path.path)
    }
}

struct ProjectStatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        Text(localized(status.label))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var color: Color {
        switch status {
        case .stale: .orange
        case .active: .green
        case .pinned: .blue
        case .hibernated: .purple
        }
    }
}

private struct ProjectMenu: View {
    @Environment(GroundControlModel.self) private var model
    let project: Project

    var body: some View {
        if model.canHibernate(project) {
            Button("Hibernate…") { Task { await model.reviewHibernation(paths: [project.path.path]) } }
            Divider()
        }
        Button(model.isPinned(project) ? "Unpin" : "Pin (Never Hibernate)") { model.setPinned(!model.isPinned(project), project) }
        Button("Hide This Project") { model.ignoreProject(project) }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.path]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path.path, forType: .string)
        }
    }
}

private struct ProjectDetail: View {
    @Environment(GroundControlModel.self) private var model
    let project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 5) {
                    info("Last activity", activityText)
                    if let git = project.git {
                        info("Git", git.branch.map { String(localized: "on \($0)") } ?? String(localized: "detached HEAD"))
                    } else {
                        info("Git", String(localized: "not a git repository"))
                    }
                    info("Comes back", restoreText)
                }
                .font(.callout)

                if !project.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(project.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Text("Informational: hibernation never touches tracked or uncommitted files, only the directories below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                if let record = model.hibernations[project.path.path] {
                    HibernationRecordBox(record: record)
                }

                DirList(title: "Removed by hibernation", dirs: project.strippable, showSize: true,
                        empty: "Nothing to strip.")
                if !project.restoreCommands.isEmpty {
                    CommandBox(commands: project.restoreCommands)
                }
                ForEach(project.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if !project.skipped.isEmpty {
                    DirList(title: "Left alone", dirs: project.skipped, showSize: false, empty: "")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(project.name).font(.title3.weight(.semibold))
            ProjectStatusBadge(status: model.status(of: project))
            Button(project.path.path.replacingOccurrences(of: model.environment.context.home.path, with: "~")) {
                NSWorkspace.shared.activateFileViewerSelecting([project.path])
            }
            .buttonStyle(.link)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Show in Finder")
            Spacer()
            Toggle("Pinned", isOn: Binding(get: { model.isPinned(project) }, set: { model.setPinned($0, project) }))
                .toggleStyle(.checkbox)
                .help("Pinned projects are never offered for hibernation")
            Button("Hibernate…") { Task { await model.reviewHibernation(paths: [project.path.path]) } }
                .disabled(!model.canHibernate(project) || model.cleanSession != nil)
        }
    }

    private var restoreText: String {
        if project.strippable.isEmpty, let record = model.hibernations[project.path.path], !record.restoreCommands.isEmpty {
            let commands = record.restoreCommands.map { "`\($0)`" }.joined(separator: String(localized: ", then "))
            return String(localized: "Run \(commands).")
        }
        return project.restoreSummary
    }

    private var activityText: String {
        var parts: [String] = []
        if let c = project.lastCommit { parts.append(String(localized: "last commit \(c.formatted(date: .abbreviated, time: .omitted))")) }
        if let f = project.newestFileChange { parts.append(String(localized: "newest file change \(f.formatted(date: .abbreviated, time: .omitted))")) }
        return parts.isEmpty ? String(localized: "unknown") : parts.joined(separator: " · ")
    }

    private func info(_ label: LocalizedStringKey, _ text: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct DirList: View {
    let title: LocalizedStringKey
    let dirs: [StrippableDir]
    let showSize: Bool
    let empty: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if dirs.isEmpty {
                Text(empty).foregroundStyle(.secondary).font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(dirs.sorted { ($0.size ?? 0) > ($1.size ?? 0) }) { dir in
                    GridRow {
                        Text(dir.relativePath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(showSize ? .primary : .secondary)
                        Text(dir.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if showSize {
                            Text(dir.size.map(ByteFormat.string) ?? "…").monospacedDigit().font(.callout)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct CommandBox: View {
    let commands: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("To restore").font(.caption).foregroundStyle(.secondary)
                ForEach(commands, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commands.joined(separator: " && "), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy the restore commands")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct HibernationRecordBox: View {
    let record: HibernationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Hibernated \(record.date.formatted(date: .abbreviated, time: .shortened)) — \(ByteFormat.string(record.estimatedBytes)) removed",
                  systemImage: "moon.zzz")
                .font(.callout.weight(.medium))
            Text(record.removed.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !record.restoreCommands.isEmpty {
                Text("Restore: " + record.restoreCommands.joined(separator: " && "))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
