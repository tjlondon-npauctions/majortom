import AppKit
import GroundControl
import MajorTomCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    /// `--settings-tab projects` (dev aid for snapshots) opens a specific tab.
    @State private var tab = Snapshotter.argument("--settings-tab") ?? "rules"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Rules", systemImage: "list.bullet.rectangle", value: "rules") { RulesSettings() }
            Tab("Projects", systemImage: "moon.zzz", value: "projects") { ProjectSettings() }
            Tab("Files", systemImage: "doc.on.doc", value: "files") { FilesSettings() }
            Tab("Alerts", systemImage: "bell.badge", value: "alerts") { AlertsSettings() }
            Tab("NAS", systemImage: "externaldrive.connected.to.line.below", value: "nas") { NASSettings() }
            Tab("Ignored", systemImage: "eye.slash", value: "ignored") { IgnoredSettings() }
            Tab("Access", systemImage: "lock.shield", value: "access") { AccessSettings() }
            Tab("About", systemImage: "info.circle", value: "about") { AboutSettings() }
        }
        .frame(width: 560, height: 520)
    }
}

private struct RulesSettings: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Form {
            ForEach(RuleCategory.allCases, id: \.self) { category in
                let rules = model.environment.rules.filter { $0.category == category }
                if !rules.isEmpty {
                    Section(localized(category.title)) {
                        ForEach(rules) { rule in
                            Toggle(isOn: Binding(get: { !model.settings.disabledRuleIDs.contains(rule.id) },
                                                 set: { model.setRuleEnabled($0, ruleID: rule.id) })) {
                                HStack(spacing: 6) {
                                    Text(localized(rule.title))
                                    TierBadge(tier: rule.tier)
                                }
                                Text(localized(rule.regenCost))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProjectSettings: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.projectRoots.isEmpty {
                    Text("No project folders. Add the folder your projects live in.").foregroundStyle(.secondary)
                }
                ForEach(model.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { model.removeProjectRoot(root) }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Button("Add Folder…") { FolderPickers.addProjectRoot(model) }
                    Spacer()
                    if !model.settings.projectRootsAreAutomatic {
                        Button("Detect Automatically") { model.useDetectedProjectRoots() }
                            .help("Use whichever of ~/Projects, ~/Developer, ~/Code, ~/WebstormProjects, … exist")
                    }
                }
            } header: {
                Text("Project folders")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.settings.projectRootsAreAutomatic {
                        Text("Detected automatically from the usual folders (~/Projects, ~/Developer, ~/Code, ~/src, ~/WebstormProjects, ~/IdeaProjects, …). Adding or removing one switches to your own list.")
                    }
                    Text("Major Tom looks for projects (a folder with .git, package.json, Podfile, Cargo.toml, …) up to \(ProjectScanner.maxContainerDepth) levels below these folders.")
                }
                .foregroundStyle(.secondary)
            }
            Section("Staleness") {
                Stepper(value: Binding(get: { model.settings.staleAfterDays }, set: { model.setStaleAfterDays($0) }),
                        in: 7...730, step: 15) {
                    LabeledContent("Stale after", value: String(localized: "\(model.settings.staleAfterDays) days without activity"))
                }
                Text("Activity is the newest of the last git commit and the newest file change outside dependency and build folders.")
                    .foregroundStyle(.secondary)
            }
            Section("Pinned (never offered for hibernation)") {
                if model.settings.pinnedProjects.isEmpty {
                    Text("Nothing pinned. Right-click a project and choose “Pin”.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.pinnedProjects, id: \.self) { path in
                    pathRow(path, label: "Unpin") { model.unpinProject(path: path) }
                }
            }
            Section("Hidden projects") {
                if model.settings.ignoredProjects.isEmpty {
                    Text("Nothing hidden. Right-click a project and choose “Hide This Project”.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.ignoredProjects, id: \.self) { path in
                    pathRow(path, label: "Show Again") { model.unignoreProject(path: path) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ path: String, label: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(path.replacingOccurrences(of: model.environment.context.home.path, with: "~"))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Button(localized(label), action: action).controlSize(.small)
        }
    }

}

private struct IgnoredSettings: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.settings.ignoredPaths.isEmpty {
                    Text("Nothing ignored. Right-click an item and choose “Never Offer This Item” to hide it from scans.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings.ignoredPaths, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button("Offer Again") { model.unignore(path: path) }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Items Major Tom never offers")
            }
        }
        .formStyle(.grouped)
    }
}

/// Thresholds for the general-cleanup file rules (large files, old files).
private struct FilesSettings: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Large files are at least", selection: binding(\.largeFileThresholdMB)) {
                    ForEach(options([100, 250, 500, 1000, 2000, 5000], current: model.settings.largeFileThresholdMB), id: \.self) {
                        Text(ByteFormat.string(Int64($0) * 1_000_000)).tag($0)
                    }
                }
                Picker("Old files haven't been used for", selection: binding(\.oldFileDays)) {
                    ForEach(options([90, 180, 365, 730, 1095], current: model.settings.oldFileDays), id: \.self) { days in
                        Text(days % 365 == 0 ? "\(days / 365) year\(days == 365 ? "" : "s")" : "\(days) days").tag(days)
                    }
                }
                Picker("…and are at least", selection: binding(\.oldFileMinimumMB)) {
                    ForEach(options([10, 25, 50, 100, 250], current: model.settings.oldFileMinimumMB), id: \.self) {
                        Text(ByteFormat.string(Int64($0) * 1_000_000)).tag($0)
                    }
                }
            } header: {
                Text("Downloads, Movies, Desktop and Documents")
            } footer: {
                Text("Files inside projects, git repositories, app bundles and Photos/Music/TV libraries are never listed. Everything here goes to the Trash, never straight to deletion, and is never part of Quick clean.")
                    .foregroundStyle(.secondary)
            }
            Section("Leftovers from removed apps") {
                Text("Only folders named after an app's bundle ID, untouched for 30 days, with no app of that ID or vendor in /Applications, ~/Applications, /System/Applications, Spotlight or LaunchServices. Apple's own data, developer tools and your own projects' apps are skipped. Containers are only checked with Full Disk Access.")
                    .foregroundStyle(.secondary)
            }
            OwnBundleIDSection()
        }
        .formStyle(.grouped)
    }

    private func binding(_ key: WritableKeyPath<MajorTomCore.Settings, Int>) -> Binding<Int> {
        Binding(get: { model.settings[keyPath: key] }, set: { v in model.updateSettings { $0[keyPath: key] = v } })
    }

    /// Preset values plus whatever is in the settings file, so a hand-edited value still shows.
    private func options(_ presets: [Int], current: Int) -> [Int] {
        Array(Set(presets + [current])).sorted()
    }
}

/// Bundle-ID prefixes of apps the user builds: their data is never listed as left over from a removed app.
private struct OwnBundleIDSection: View {
    @Environment(GroundControlModel.self) private var model
    @State private var newPrefix = ""

    var body: some View {
        Section {
            ForEach(model.settings.ownBundleIDPrefixes, id: \.self) { prefix in
                HStack {
                    Text(prefix).monospaced()
                    Spacer()
                    Button("Remove") { model.removeOwnBundleIDPrefix(prefix) }.controlSize(.small)
                }
            }
            HStack {
                TextField("Prefix", text: $newPrefix, prompt: Text("com.example."))
                    .onSubmit(add)
                Button("Add", action: add).disabled(!newPrefix.contains("."))
            }
        } header: {
            Text("Apps you build yourself")
        } footer: {
            Text("Data of apps whose bundle ID starts with one of these is never called a leftover — your own apps are often not installed in /Applications. Folders named after projects in your project folders are recognised automatically too.")
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        model.addOwnBundleIDPrefix(newPrefix)
        newPrefix = ""
    }
}

private struct AboutSettings: View {
    private static let repository = URL(string: "https://github.com/tjlondon-npauctions/majortom")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppVersion.current)
                LabeledContent("Source and releases") {
                    Link(Self.repository.absoluteString, destination: Self.repository)
                }
                Text("To update, run the install command from the README again, or download the latest release. Major Tom is open source (MIT) and comes with no warranty.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccessSettings: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Form {
            Section("Full Disk Access") {
                LabeledContent("Status") {
                    switch model.fullDiskAccess {
                    case .granted: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied: Label("Not granted", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                    case .unknown: Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    }
                }
                Text("Without it, the Trash and some app caches can't be measured. Major Tom never needs admin rights; anything that does is shown as a command for you to run.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Privacy & Security…") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Button("Check Again") { Task { await model.refreshFullDiskAccess() } }
                }
            }
            Section("Data") {
                LabeledContent("History log") {
                    pathButton(model.environment.history.url)
                }
                LabeledContent("Settings file") {
                    pathButton(model.environment.settingsStore.url)
                }
                if let error = model.settingsError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pathButton(_ url: URL) -> some View {
        Button(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
            let fm = FileManager.default
            NSWorkspace.shared.activateFileViewerSelecting([fm.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()])
        }
        .buttonStyle(.link)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// Menu bar, low-space alert, launch at login and weekly rescan (M4). The two options that change system
/// state (notification permission, login item) do nothing until the user switches them on here.
private struct AlertsSettings: View {
    @Environment(GroundControlModel.self) private var model
    @Environment(SpaceWatch.self) private var watch

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.settings.lowSpaceNotifications },
                                     set: { on in Task { await watch.setNotificationsEnabled(on) } })) {
                    Text("Notify me when free space is low")
                    Text("macOS asks for permission the first time you turn this on.")
                }
                .disabled(watch.notificationAuthorization == .unavailable)
                Stepper(value: Binding(get: { model.settings.lowSpaceThresholdGB },
                                       set: { gb in Task { await watch.setThresholdGB(gb) } }),
                        in: 5...200, step: 5) {
                    LabeledContent("Alert below", value: String(localized: "\(model.settings.lowSpaceThresholdGB) GB free"))
                }
                LabeledContent("Free now") {
                    HStack(spacing: 5) {
                        if watch.isBelowThreshold {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Text(ByteFormat.string(watch.freeBytes ?? model.disk.freeBytes)).monospacedDigit()
                    }
                }
                authorizationNote
            } header: {
                Text("Low disk space")
            } footer: {
                Text("Free space is checked every 5 minutes and on wake — a volume query, no scan. You get one notification each time it drops below the threshold; it re-arms once free space is back above \(ByteFormat.string(watch.rearmBytes)). Its Quick Clean button opens the review sheet — nothing is removed until you confirm.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(get: { watch.loginItemStatus.isOn }, set: { watch.setLaunchAtLogin($0) })) {
                    Text("Open Major Tom at login")
                    Text("Keeps the menu bar item and the low-space check running.")
                }
                .disabled(watch.loginItemStatus == .unavailable)
                if watch.loginItemStatus == .requiresApproval {
                    HStack {
                        Label("Waiting for approval in System Settings → Login Items.", systemImage: "hand.raised")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                } else if watch.loginItemStatus == .unavailable {
                    Text("Only available when running the bundled app (scripts/bundle.sh).").foregroundStyle(.secondary)
                }
                if let error = watch.loginItemError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle(isOn: Binding(get: { model.settings.weeklyRescan }, set: { watch.setWeeklyRescan($0) })) {
                    Text("Rescan in the background once a week")
                    Text("Keeps the menu bar totals current while the window stays closed.")
                }
                LabeledContent("Last full scan") {
                    if let last = model.lastFullScan {
                        Text(last, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Background rescan")
            }
        }
        .formStyle(.grouped)
        .task { await watch.refreshAuthorization() }
    }

    @ViewBuilder private var authorizationNote: some View {
        switch watch.notificationAuthorization {
        case .denied:
            HStack {
                Label("Notifications for Major Tom are off in System Settings.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Notifications…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .controlSize(.small)
            }
        case .unavailable:
            Text("Notifications need the bundled app (scripts/bundle.sh).").foregroundStyle(.secondary)
        case .notDetermined, .authorized:
            EmptyView()
        }
    }
}

/// NAS offload (M6): destination folder on the mounted share, checksum cap, and how things are stored.
struct NASSettings: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Destination") {
                    Text(model.offloadDestination?.path ?? String(localized: "Not chosen")).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…") { FolderPickers.chooseNASFolder(model) }
                    Button("Clear") { model.setOffloadDestination(nil) }
                        .disabled(model.offloadDestination == nil)
                        .help("Turn offloading off until a folder is chosen again")
                    Spacer()
                    Button("Check Again") { model.refreshDestination() }
                }
                LabeledContent("Status") {
                    Label(model.destinationCheck.isReady ? "Mounted network share" : "Not available",
                          systemImage: model.destinationCheck.isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(model.destinationCheck.isReady ? .green : .orange)
                }
                Text(model.destinationCheck.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("NAS destination")
            } footer: {
                Text("Must be a folder on a mounted network share (SMB, AFP or NFS). A folder on this Mac — like an empty mount point left behind in /Volumes when the share isn't mounted — is refused, so offloading can never fill the internal disk.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Full checksum for files up to", selection: Binding(get: { model.settings.offloadChecksumCapMB },
                                                                          set: { model.setChecksumCapMB($0) })) {
                    ForEach(Array(Set([256, 1024, 4096, 16384, 1_000_000, model.settings.offloadChecksumCapMB])).sorted(), id: \.self) { mb in
                        Text(mb >= 1_000_000 ? String(localized: "Any size") : ByteFormat.string(Int64(mb) * 1_000_000)).tag(mb)
                    }
                }
                Text("After copying, every file is read back from the NAS (bypassing this Mac's cache) and compared by SHA-256. Bigger files are compared by size plus their first and last 4 MiB, so verifying a huge video doesn't take as long as copying it twice.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Verification")
            }
            Section("On the NAS") {
                Text("<share>/projects|xcode-archives|files/<name>/<date-time>/ holds the copy and manifest.json. Folders (projects, archives, app bundles) are stored as one standard tar file — keeps symlinks, permissions, extended attributes, long and odd names and case intact, and is much faster over SMB than thousands of small files. Single files are copied as they are, with SMB-safe names; their real name and attributes are in the manifest. A folder ending in “.partial” is an incomplete copy.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Local manifests") {
                    Button(model.environment.offloads.directory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
                        let dir = model.environment.offloads.directory
                        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: dir.path) ? dir : dir.deletingLastPathComponent()])
                    }
                    .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .task { model.refreshDestination() }
    }

}
