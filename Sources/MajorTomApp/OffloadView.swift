import AppKit
import GroundControl
import MajorTomCore
import SwiftUI

/// Is the NAS there? Shown on top of both offload views.
struct DestinationBanner: View {
    @Environment(GroundControlModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let check = model.destinationCheck
        HStack(spacing: 10) {
            Image(systemName: check.isReady ? "externaldrive.connected.to.line.below.fill" : "externaldrive.badge.xmark")
                .font(.title3)
                .foregroundStyle(check.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.isReady ? "NAS ready — \(model.offloadDestination?.path ?? "")"
                     : check == .notSet ? "No NAS folder chosen" : "NAS not available")
                    .fontWeight(.semibold)
                // No fixedSize here: above a List it inflates the window's content height (drawn off-window).
                Text(check.message.isEmpty ? String(localized: "Checking…") : check.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            if check == .notSet {
                Button("Choose NAS Folder…") { FolderPickers.chooseNASFolder(model) }
            } else if !check.isReady {
                Button("Open Finder") {
                    // Connecting is the user's call (Finder → Go → Connect to Server, ⌘K); Major Tom never mounts anything.
                    NSWorkspace.shared.open(URL(filePath: "/System/Library/CoreServices/Finder.app"))
                }
                .help("Connect the share in Finder with Go → Connect to Server (⌘K), then Check Again")
            }
            Button("Check Again") { model.refreshDestination() }
            Button("Settings…") { openSettings() }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background((check.isReady ? Color.green : Color.orange).opacity(0.10))
    }
}

/// What could go to the NAS: stale projects, Xcode Archives, large cold files.
struct OffloadView: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        if model.offloadDestination == nil {
            VStack(spacing: 0) {
                DestinationBanner()
                Divider()
                ContentUnavailableView {
                    Label("No NAS folder chosen", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Offloading copies stale projects, Xcode archives and cold files to a folder on a mounted network share, verifies the copy, and only then moves the original to the Trash. Connect the share in Finder (Go → Connect to Server, ⌘K), then choose a folder on it.")
                } actions: {
                    Button("Choose NAS Folder…") { FolderPickers.chooseNASFolder(model) }
                        .primaryActionButtonStyle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task { await model.refreshDestinationNow() }
        } else {
            candidatesView
        }
    }

    private var candidatesView: some View {
        VStack(spacing: 0) {
            DestinationBanner()
            Divider()
            OffloadHeader()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            List {
                ForEach(OffloadKind.allCases, id: \.self) { kind in
                    let items = model.offloadCandidates(kind: kind)
                    Section {
                        if items.isEmpty, !model.isScanningOffloadCandidates {
                            Text(emptyText(kind)).foregroundStyle(.secondary)
                        }
                        ForEach(items) { c in
                            CandidateRow(candidate: c)
                        }
                    } header: {
                        HStack {
                            Text(localized(kind.title))
                            Spacer()
                            Text(ByteFormat.string(items.reduce(0) { $0 + ($1.size ?? 0) })).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
            // Rebuilt rather than row-updated when the candidates change: animating variable-height rows into
            // several sections at once trips an NSTableView reentrancy warning and can stall drawing.
            .id(model.offloadCandidates.map(\.id))
            .overlay {
                if model.isScanningOffloadCandidates && model.offloadCandidates.isEmpty {
                    ProgressView("Looking for things to offload…")
                }
            }
        }
        .task {
            // Let the sidebar table finish its update first: changing the model synchronously from here (the view
            // appears inside the sidebar's selection change) is a reentrant NSTableView update and stalls drawing.
            await Task.yield()
            if model.offloadCandidatesState == .idle { await model.scanOffloadCandidates() } else { await model.refreshDestinationNow() }
        }
    }

    private func emptyText(_ kind: OffloadKind) -> String {
        switch kind {
        case .project: String(localized: "No stale projects (no activity for \(model.settings.staleAfterDays)+ days).")
        case .xcodeArchive: String(localized: "No Xcode archives.")
        case .file: String(localized: "No large files unused for \(OffloadEngine.coldFileDays)+ days, and no old files.")
        }
    }
}

private struct OffloadHeader: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        let checked = model.checkedOffloadCandidates
        let bytes = checked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Offload to NAS").font(.title2.weight(.semibold))
                Text("Copy → verify on the NAS → manifest on the NAS and here → only then move the original to the Trash. Anything that fails leaves the original where it is.")
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            if model.isScanningOffloadCandidates {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.scanOffloadCandidates() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
            Button {
                Task { await model.reviewOffload() }
            } label: {
                Text(checked.isEmpty ? "Offload…" : "Offload \(checked.count) (\(ByteFormat.string(bytes)))…")
            }
            .primaryActionButtonStyle()
            .disabled(checked.isEmpty || model.offloadSession != nil)
        }
        .font(.callout)
    }
}

private struct CandidateRow: View {
    @Environment(GroundControlModel.self) private var model
    let candidate: OffloadCandidate

    var body: some View {
        let c = candidate
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(get: { model.isOffloadChecked(c) }, set: { model.setOffloadChecked($0, c) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.displayName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(c.path.path.replacingOccurrences(of: model.environment.context.home.path, with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if c.shouldHibernateFirst {
                    HStack(spacing: 6) {
                        Label("\(ByteFormat.string(c.strippableBytes)) of dependencies and build output (\(c.strippableDirs.prefix(3).joined(separator: ", "))\(c.strippableDirs.count > 3 ? ", …" : "")) would be copied too.",
                              systemImage: "moon.zzz")
                            .foregroundStyle(.orange)
                        Button("Hibernate First…") { Task { await model.hibernateBeforeOffload(c) } }
                            .controlSize(.small)
                    }
                    .font(.caption)
                }
                ForEach(c.warnings, id: \.self) { w in
                    Label("\(w) — included in the archive (the whole repository is copied)", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note = c.note {
                    if c.kind == .project {
                        if note.hasPrefix("contains") { Label(note, systemImage: "square.stack").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(c.size.map(ByteFormat.string) ?? "—").monospacedDigit()
                if let used = c.lastUsed {
                    Text("used \(used.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.path]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.path.path, forType: .string)
            }
        }
    }
}

/// Everything offloaded: where it is on the NAS, what happened to the original, restore.
struct OffloadedView: View {
    @Environment(GroundControlModel.self) private var model
    @State private var confirmRemovePartials = false

    var body: some View {
        VStack(spacing: 0) {
            DestinationBanner()
            Divider()
            if !model.incompleteCopies.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.incompleteCopies.count) incomplete cop\(model.incompleteCopies.count == 1 ? "y" : "ies") on the NAS")
                            .fontWeight(.semibold)
                        Text("Left by an interrupted offload (folders ending in “.partial”). Their originals were never touched.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { confirmRemovePartials = true }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.08))
                Divider()
            }
            if let message = model.offloadMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            List(model.offloadRecords) { record in
                OffloadedRow(record: record, reachable: model.reachableOffloads.contains(record.id))
            }
            .listStyle(.inset)
            .overlay {
                if model.offloadRecords.isEmpty {
                    ContentUnavailableView("Nothing offloaded yet", systemImage: "externaldrive",
                                           description: Text("Things you offload to the NAS show up here, ready to restore."))
                }
            }
        }
        .task {
            await Task.yield()
            await model.refreshDestinationNow()
        }
        .confirmationDialog("Remove the incomplete copies from the NAS?", isPresented: $confirmRemovePartials) {
            Button("Remove \(model.incompleteCopies.count) Incomplete Cop\(model.incompleteCopies.count == 1 ? "y" : "ies")", role: .destructive) {
                Task { await model.removeIncompleteCopies() }
            }
        } message: {
            Text(model.incompleteCopies.map { $0.path }.joined(separator: "\n"))
        }
    }
}

private struct OffloadedRow: View {
    @Environment(GroundControlModel.self) private var model
    let record: OffloadRecord
    let reachable: Bool

    var body: some View {
        let m = record.manifest
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: m.kind.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.displayName).fontWeight(.medium)
                    Text(localized(m.kind.title).lowercased()).font(.caption).foregroundStyle(.secondary)
                }
                Text("From \(m.sourcePath.replacingOccurrences(of: model.environment.context.home.path, with: "~"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("On the NAS: \(m.archivePath)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("\(m.fileCount) files · \(m.format == .tar ? String(localized: "one tar archive") : String(localized: "plain copy")) · verified \(m.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                originalLine
                ForEach(record.restores, id: \.self) { r in
                    Label("Restored to \(r.path.replacingOccurrences(of: model.environment.context.home.path, with: "~")) \(r.date.formatted(.relative(presentation: .named)))",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteFormat.string(m.payloadBytes)).monospacedDigit()
                HStack(spacing: 6) {
                    Button("Restore") { Task { await model.reviewRestore(record) } }
                    Menu {
                        Button("Restore To…") { chooseFolder() }
                        Button("Show on NAS") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: m.payloadPath)]) }
                            .disabled(!reachable)
                        Button("Copy Restore Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(m.restoreCommand, forType: .string)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                .controlSize(.small)
                .disabled(!reachable || model.restoreSession != nil)
                if !reachable {
                    Text("NAS not mounted").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var originalLine: some View {
        switch record.original {
        case .trashed(let date):
            Label("Original moved to the Trash \(date.formatted(.relative(presentation: .named))) — empty the Trash to free the space",
                  systemImage: "trash").font(.caption).foregroundStyle(.secondary)
        case .kept(let why):
            Label("Original kept: \(why)", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.environment.context.home
        panel.prompt = "Restore Here"
        panel.message = "Major Tom restores “\(URL(filePath: record.manifest.sourcePath).lastPathComponent)” into this folder. It never overwrites anything."
        if panel.runModal() == .OK, let url = panel.url { Task { await model.reviewRestore(record, into: url) } }
    }
}

extension OffloadKind {
    var symbol: String {
        switch self {
        case .project: "folder"
        case .xcodeArchive: "archivebox"
        case .file: "doc"
        }
    }
}
