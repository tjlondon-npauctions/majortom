import AppKit
import GroundControl
import MajorTomCore
import SwiftUI

struct HistoryView: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No cleans yet", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Ground Control has nothing to report. Every clean you run is logged here."))
            } else {
                List {
                    Section {
                        ForEach(model.history) { entry in
                            HistoryRow(entry: entry, ruleTitle: { model.rule(id: $0).map { localized($0.title) } ?? $0 })
                        }
                    } header: {
                        HStack {
                            Text("\(model.history.count) clean\(model.history.count == 1 ? "" : "s") · \(ByteFormat.string(model.totalReclaimedAllTime)) reclaimed in total")
                            Spacer()
                            Button("Show Log File") {
                                NSWorkspace.shared.activateFileViewerSelecting([model.environment.history.url])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { model.reloadHistory() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let ruleTitle: (String) -> String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.succeeded ? "checkmark.circle"
                          : item.partial == true ? "circle.lefthalf.filled" : "xmark.circle")
                        .foregroundStyle(item.succeeded ? Color.secondary : item.partial == true ? Color.orange : Color.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                        Text([ruleTitle(item.ruleID), localized(item.method), item.path].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let error = item.error {
                            Text(item.partial == true ? String(localized: "Partly done: \(error)") : error)
                                .font(.caption).foregroundStyle(item.partial == true ? Color.orange : Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        ForEach(item.leftBehind ?? [], id: \.self) { left in
                            Text("Left: \(left.path) — \(left.advice)")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let underlying = item.underlyingError {
                            Text(underlying).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(3).truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Text(item.estimatedBytes.map(ByteFormat.string) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date, format: .dateTime.weekday().day().month().year().hour().minute())
                        .fontWeight(.medium)
                    Text(entry.ruleIDs.map(ruleTitle).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(ByteFormat.string(entry.reclaimedBytes)) reclaimed").monospacedDigit()
                    Text("\(entry.items.count) item\(entry.items.count == 1 ? "" : "s") · est. \(ByteFormat.string(entry.estimatedBytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 3)
        }
    }
}
