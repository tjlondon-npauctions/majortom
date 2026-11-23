import AppKit
import GroundControl
import MajorTomCore
import QuickLook
import SwiftUI

struct RuleDetailView: View {
    @Environment(GroundControlModel.self) private var model
    let rule: Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RuleInfoHeader(rule: rule)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            let actions = model.actions(ruleID: rule.id)
            if !actions.isEmpty {
                RuleActionsBox(rule: rule, actions: actions)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            Divider()
            ItemTable(rule: rule)
        }
    }
}

private struct RuleInfoHeader: View {
    @Environment(GroundControlModel.self) private var model
    let rule: Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localized(rule.title)).font(.title2.weight(.semibold))
                TierBadge(tier: rule.tier)
                Spacer()
                Button {
                    Task { await model.scan(ruleIDs: [rule.id]) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.scanningRuleIDs.contains(rule.id))
                .help("Rescan only this rule")
            }
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                infoRow("If you delete it", localized(rule.impact))
                infoRow("How it comes back", localized(rule.recovery))
                infoRow("What it costs", localized(rule.regenCost))
                infoRow("How it's removed", methodText)
            }
            .font(.callout)
            if let result = model.results[rule.id], let error = result.error {
                if result.deniedPaths.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else {
                    AccessDeniedBox(message: error, paths: result.deniedPaths)
                }
            }
        }
    }

    private var methodText: String {
        switch rule.method {
        case .delete: String(localized: "Deleted outright (a cache in the Trash frees nothing).")
        case .deleteContents: String(localized: "Contents deleted outright; each app's folder itself is kept, since the app expects it.")
        case .trash: String(localized: "Moved to the Trash, so you can still put it back.")
        case .command(let argv): String(localized: "By the owning tool: \(argv.joined(separator: " "))")
        case .reportOnly: String(localized: "Report only. Major Tom shows it but never removes it.")
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ text: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// A rule could only partly look: macOS privacy protection kept it out of some folders. Says which, and how to fix it.
private struct AccessDeniedBox: View {
    @Environment(GroundControlModel.self) private var model
    let message: String
    let paths: [String]

    static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Can't look in \(paths.joined(separator: ", "))").fontWeight(.medium)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    if paths.contains(where: { !$0.hasPrefix("~/Library") }) {
                        Button("Open Files & Folders…") { NSWorkspace.shared.open(Self.filesAndFoldersURL) }
                    }
                    Button("Open Full Disk Access…") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Button("Check Again") {
                        Task {
                            await model.refreshFullDiskAccess()
                            await model.scan(ruleIDs: model.rules.filter { model.results[$0.id]?.deniedPaths.isEmpty == false }.map(\.id))
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RuleActionsBox: View {
    @Environment(GroundControlModel.self) private var model
    let rule: Rule
    let actions: [RuleAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions) { action in
                HStack(alignment: .top, spacing: 10) {
                    if action.runnable {
                        Toggle(isOn: Binding(get: { model.isChecked(ruleID: rule.id, actionID: action.id) },
                                             set: { model.setChecked($0, ruleID: rule.id, actionID: action.id) })) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Include this command in the next clean")
                    } else {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(localized(action.title)).fontWeight(.medium)
                            TierBadge(tier: action.tier)
                            if !action.runnable {
                                Text("run it yourself").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(localized(action.explanation))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(action.commandLine)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(action.commandLine, forType: .string)
                    } label: {
                        Label("Copy Command", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the command")
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Item {
    var sortSize: Int64 { size ?? 0 }
    var sortDate: Date { lastUsed ?? .distantPast }
}

private struct ItemTable: View {
    @Environment(GroundControlModel.self) private var model
    let rule: Rule
    @State private var selection = Set<Item.ID>()
    @State private var sortOrder = [KeyPathComparator(\Item.sortSize, order: .reverse)]
    /// The file Quick Look is showing (nil = panel closed).
    @State private var previewURL: URL?

    var body: some View {
        let items = model.items(ruleID: rule.id).sorted(using: sortOrder)
        let selectedPaths = items.filter { selection.contains($0.id) }.compactMap(\.path)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                let cleanable = items.filter(\.isCleanable)
                Text(summary(items))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if items.contains(where: { $0.path != nil }) {
                    Button {
                        previewURL = previewURL == nil ? selectedPaths.first : nil
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .keyboardShortcut("y", modifiers: .command)
                    .disabled(selectedPaths.isEmpty)
                    .help("Quick Look the selected item (⌘Y)")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(selectedPaths)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(selectedPaths.isEmpty)
                    .help("Reveal the selected items in Finder (⌥⌘R)")
                    Divider().frame(height: 14)
                }
                if cleanable.contains(where: \.isFlagged) {
                    Button("Select Flagged") {
                        for item in cleanable where item.isFlagged {
                            model.setChecked(true, ruleID: rule.id, itemID: item.id)
                        }
                    }
                    .help("Select items marked as good candidates (orphaned, unused, superseded)")
                }
                Button(model.checkState(ruleID: rule.id) == .all ? "Deselect All" : "Select All") {
                    model.setAllChecked(model.checkState(ruleID: rule.id) != .all, ruleID: rule.id)
                }
                .disabled(cleanable.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Table(items, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { item in
                    Toggle(isOn: Binding(get: { model.isChecked(ruleID: rule.id, itemID: item.id) },
                                         set: { model.setChecked($0, ruleID: rule.id, itemID: item.id) })) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!item.isCleanable)
                }
                .width(22)

                TableColumn("Name", value: \.displayName) { item in
                    ItemNameCell(item: item)
                }
                .width(min: 200, ideal: 340)

                TableColumn("Size", value: \.sortSize) { item in
                    Text(item.size.map(ByteFormat.string) ?? "—")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 80, max: 110)

                TableColumn("Last used", value: \.sortDate) { item in
                    if let date = item.lastUsed {
                        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .foregroundStyle(.secondary)
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 110, max: 160)
            }
            .contextMenu(forSelectionType: Item.ID.self) { ids in
                contextMenu(for: items.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                model.toggle(ruleID: rule.id, itemIDs: ids)
            }
            .onKeyPress(.space) {
                guard !selection.isEmpty else { return .ignored }
                model.toggle(ruleID: rule.id, itemIDs: selection)
                return .handled
            }
            .quickLookPreview($previewURL, in: items.compactMap(\.path))
            .onChange(of: selection) {
                // Quick Look follows the table selection while it's open (like Finder).
                if previewURL != nil, let first = items.first(where: { selection.contains($0.id) })?.path { previewURL = first }
            }
            .task(id: items.count) {
                // Dev aid for snapshots: `--quick-look-first` selects the first item and opens Quick Look on it.
                guard CommandLine.arguments.contains("--quick-look-first"), previewURL == nil,
                      let first = items.first(where: { $0.path != nil }) else { return }
                selection = [first.id]
                previewURL = first.path
            }
            .overlay {
                if items.isEmpty, model.results[rule.id] != nil, !model.scanningRuleIDs.contains(rule.id) {
                    ContentUnavailableView("Nothing to clean here",
                                           systemImage: "checkmark.seal",
                                           description: Text("Ground Control reports all clear for this rule."))
                } else if items.isEmpty, model.scanningRuleIDs.contains(rule.id) || model.results[rule.id] == nil {
                    ProgressView("Scanning…")
                }
            }
        }
    }

    private func summary(_ items: [Item]) -> String {
        let checked = items.filter { model.isChecked(ruleID: rule.id, itemID: $0.id) }
        let checkedBytes = checked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let count = String(localized: "\(items.count) item\(items.count == 1 ? "" : "s")")
        return checked.isEmpty ? count
            : String(localized: "\(checked.count) of \(count) selected · \(ByteFormat.string(checkedBytes))")
    }

    @ViewBuilder
    private func contextMenu(for items: [Item]) -> some View {
        let cleanable = items.filter(\.isCleanable)
        if !cleanable.isEmpty {
            Button("Toggle Selection") { model.toggle(ruleID: rule.id, itemIDs: cleanable.map(\.id)) }
        }
        let paths = items.compactMap(\.path)
        if !paths.isEmpty {
            Button("Quick Look") { previewURL = paths.first }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(paths) }
            Button(paths.count == 1 ? "Copy Path" : "Copy Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button(items.count == 1 ? "Never Offer This Item" : "Never Offer These Items") {
                for item in items { model.ignore(item) }
            }
        }
    }
}

private struct ItemNameCell: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                if item.isFlagged {
                    Image(systemName: "flag.fill").foregroundStyle(.orange).help("Good candidate")
                }
                if item.isProtected {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Protected — never cleaned")
                }
                if item.methodOverride == .reportOnly {
                    Text("report only").font(.caption).foregroundStyle(.secondary)
                } else if item.methodOverride == .trash {
                    Image(systemName: "trash").foregroundStyle(.secondary).help("Goes to the Trash")
                }
            }
            if let note = item.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .help([item.path?.path ?? item.displayName, item.note].compactMap { $0 }.joined(separator: "\n\n"))
    }
}
