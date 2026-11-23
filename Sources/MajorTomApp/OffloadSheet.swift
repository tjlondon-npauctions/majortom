import GroundControl
import MajorTomCore
import SwiftUI

/// Offload: review (dry run) → copy + verify with progress → per-item result.
struct OffloadSheet: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Group {
            if let session = model.offloadSession {
                switch session.phase {
                case .reviewing(let report):
                    OffloadReview(session: session, report: report)
                case .running(let progress, let cancelling):
                    TransferProgressView(title: "Offloading to the NAS", progress: progress, cancelling: cancelling,
                                         note: "The original of each item stays where it is until its copy on the NAS has been verified.",
                                         cancel: { model.cancelOffload() })
                case .finished(let report):
                    OffloadResult(report: report)
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 440, idealHeight: 580)
    }
}

private struct OffloadReview: View {
    @Environment(GroundControlModel.self) private var model
    let session: OffloadSession
    let report: OffloadReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review before offloading").font(.title2.weight(.semibold))
                Text("\(session.candidates.count) item\(session.candidates.count == 1 ? "" : "s"), about \(ByteFormat.string(session.estimatedBytes)), to \(model.offloadDestination?.path ?? "—")")
                    .foregroundStyle(.secondary)
                if let report {
                    Label(report.destination.message, systemImage: report.destination.isReady ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(report.destination.isReady ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            List {
                ForEach(session.candidates) { c in
                    let result = report?.results.first { $0.id == c.id }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: c.kind.symbol).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName).fontWeight(.medium)
                            Text(c.path.path.replacingOccurrences(of: model.environment.context.home.path, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if c.shouldHibernateFirst {
                                Label("Includes \(ByteFormat.string(c.strippableBytes)) of dependencies/build output — consider hibernating it first.",
                                      systemImage: "moon.zzz").font(.caption).foregroundStyle(.orange)
                            }
                            switch result?.status {
                            case .skipped(let why)?, .failed(let why)?:
                                Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .wouldOffload?:
                                let isFolder = (try? c.path.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true
                                Text("\(ByteFormat.string(result?.payloadBytes ?? 0)) to copy as \(isFolder ? String(localized: "one tar archive") : String(localized: "a plain file"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            default:
                                EmptyView()
                            }
                        }
                        Spacer()
                        Text(c.size.map(ByteFormat.string) ?? "—").monospacedDigit()
                        statusIcon(result?.status)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Each item: copied to the NAS → every file verified (SHA-256 up to \(ByteFormat.string(Int64(model.settings.offloadChecksumCapMB) * 1_000_000)), size + first/last 4 MiB above) → manifest written on the NAS and on this Mac → original moved to the Trash. Nothing on the NAS is overwritten.",
                      systemImage: "checklist")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if report == nil {
                        ProgressView().controlSize(.small)
                        Text("Checking the share and every item…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { model.dismissOffload() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        model.confirmOffload()
                    } label: {
                        Text(confirmTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.canConfirm)
                }
            }
            .padding(20)
        }
    }

    private var confirmTitle: String {
        guard let report else { return String(localized: "Offload") }
        let ok = report.results.filter { $0.status == .wouldOffload }
        let bytes = ok.reduce(Int64(0)) { $0 + ($1.candidate.size ?? 0) }
        return ok.isEmpty ? String(localized: "Offload") : String(localized: "Offload \(ok.count) (\(ByteFormat.string(bytes)))")
    }

    @ViewBuilder private func statusIcon(_ status: OffloadItemResult.Status?) -> some View {
        switch status {
        case nil: ProgressView().controlSize(.mini)
        case .wouldOffload?: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        default: Image(systemName: "xmark.circle").foregroundStyle(.orange)
        }
    }
}

/// Shared by offload and restore.
struct TransferProgressView: View {
    let title: LocalizedStringKey
    let progress: OffloadProgress?
    let cancelling: Bool
    let note: LocalizedStringKey
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            if let p = progress {
                ProgressView(value: p.overallFraction) {
                    Text(p.itemCount > 1 ? String(localized: "Item \(p.itemIndex + 1) of \(p.itemCount): \(p.itemName)") : p.itemName)
                        .lineLimit(1).truncationMode(.middle)
                } currentValueLabel: {
                    Text("\(Int((p.overallFraction * 100).rounded())) % overall")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "\(localized(p.phase.rawValue))…")).fontWeight(.medium)
                    if p.bytesTotal > 0 {
                        ProgressView(value: min(1, Double(p.bytesDone) / Double(max(1, p.bytesTotal))))
                        HStack {
                            Text("\(ByteFormat.string(p.bytesDone)) of \(ByteFormat.string(p.bytesTotal))").monospacedDigit()
                            Spacer()
                            if let speed = p.bytesPerSecond, speed > 0 {
                                let remaining = Double(p.bytesTotal - p.bytesDone) / speed
                                Text("\(ByteFormat.string(Int64(speed)))/s · \(Self.duration(remaining)) left in this step").monospacedDigit()
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Starting…").foregroundStyle(.secondary)
            }
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                if cancelling {
                    ProgressView().controlSize(.small)
                    Text("Stopping — removing the incomplete copy…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(cancelling)
            }
        }
        .padding(24)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : s < 3600 ? "\(s / 60) min \(s % 60) s" : "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

private struct OffloadResult: View {
    @Environment(GroundControlModel.self) private var model
    let report: OffloadReport

    var body: some View {
        let trashed = report.results.filter { $0.status == .offloaded(trashed: true) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(trashed.count == report.results.count ? "Offloaded" : "Offload finished with problems")
                    .font(.title2.weight(.semibold))
                Text("\(trashed.count) of \(report.results.count) item\(report.results.count == 1 ? "" : "s") copied, verified and moved to the Trash (\(ByteFormat.string(report.trashedBytes))). Empty the Trash to get the space back.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            List(report.results) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon(r.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.candidate.displayName).fontWeight(.medium)
                        Text(detail(r)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let note = r.partialNote {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let path = r.record?.manifest.archivePath {
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text(ByteFormat.string(r.payloadBytes)).monospacedDigit()
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.dismissOffload() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
    }

    private func detail(_ r: OffloadItemResult) -> String {
        switch r.status {
        case .offloaded(trashed: true):
            if r.copySeconds > 0 {
                let speed = ByteFormat.string(Int64(Double(r.payloadBytes) / r.copySeconds))
                return String(localized: "Copied at \(speed)/s, verified, manifest written; original moved to the Trash.")
            }
            return String(localized: "Copied, verified, manifest written; original moved to the Trash.")
        case .offloaded(trashed: false):
            if case .kept(let why)? = r.record?.original { return String(localized: "Copied and verified, but the original was left in place: \(why)") }
            return String(localized: "Copied and verified; the original was left in place.")
        case .failed(let why): return String(localized: "Failed — the original is untouched. \(why)")
        case .skipped(let why): return String(localized: "Skipped — nothing was copied. \(why)")
        case .cancelled: return String(localized: "Cancelled — the original is untouched.")
        case .wouldOffload: return ""
        }
    }

    @ViewBuilder private func icon(_ s: OffloadItemResult.Status) -> some View {
        switch s {
        case .offloaded(trashed: true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .offloaded(trashed: false): Image(systemName: "checkmark.circle").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        default: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// Restore: review → copy back + verify → result.
struct RestoreSheet: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Group {
            if let session = model.restoreSession {
                let m = session.record.manifest
                switch session.phase {
                case .reviewing(let result):
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Restore \(m.displayName)").font(.title2.weight(.semibold))
                        LabeledContent("From the NAS", value: m.payloadPath)
                        LabeledContent("To", value: result?.target.path ?? "…")
                        LabeledContent("Size", value: String(localized: "\(ByteFormat.string(m.contentBytes)) in \(m.fileCount) files"))
                        if let error = result?.error {
                            Label(error.description, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if result != nil {
                            Label("Ready. Major Tom copies it into a hidden folder next to the target, verifies every file against the manifest, then moves it into place. Nothing is overwritten, and the copy on the NAS stays.",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(m.notes, id: \.self) { Text($0).foregroundStyle(.secondary).textSelection(.enabled) }
                        Spacer()
                        HStack {
                            if result == nil { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Cancel", role: .cancel) { model.dismissRestore() }.keyboardShortcut(.cancelAction)
                            Button("Restore") { model.confirmRestore() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(!session.canConfirm)
                        }
                    }
                    .padding(24)
                case .running(let progress, let cancelling):
                    TransferProgressView(title: "Restoring \(m.displayName)", progress: progress, cancelling: cancelling,
                                         note: "Nothing is moved into place until every file has been checked. The copy on the NAS is never deleted.",
                                         cancel: { model.cancelRestore() })
                case .finished(let result):
                    VStack(alignment: .leading, spacing: 14) {
                        Text(result.succeeded ? "Restored" : "Restore failed").font(.title2.weight(.semibold))
                        if let error = result.error {
                            Label(error.description, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Nothing was put in place; the partial copy was removed. The NAS copy is unchanged.")
                                .foregroundStyle(.secondary)
                        } else {
                            Label("\(m.displayName) is back at \(result.target.path), verified against its manifest (\(ByteFormat.string(result.bytes)) in \(TransferProgressView.duration(result.seconds))).",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .fixedSize(horizontal: false, vertical: true)
                            if result.xattrFailures > 0 {
                                Text("\(result.xattrFailures) extended attribute(s) couldn't be set again (macOS-managed).").foregroundStyle(.secondary)
                            }
                            ForEach(m.notes, id: \.self) { Text($0).textSelection(.enabled) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.target]) }
                        }
                        Spacer()
                        HStack {
                            Spacer()
                            Button("Done") { model.dismissRestore() }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 360, idealHeight: 420)
    }
}
