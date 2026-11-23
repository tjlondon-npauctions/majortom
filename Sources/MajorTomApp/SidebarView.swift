import GroundControl
import MajorTomCore
import SwiftUI

struct SidebarView: View {
    @Environment(GroundControlModel.self) private var model
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Reclaimable") {
                row(String(localized: "Everything"), systemImage: "square.stack.3d.up", bytes: model.reclaimable(category: nil))
                    .tag(SidebarSelection.all)
                ForEach(model.categories, id: \.self) { category in
                    row(localized(category.title), systemImage: category.symbol, bytes: model.reclaimable(category: category),
                        scanning: model.rules(in: category).contains { model.scanningRuleIDs.contains($0.id) })
                        .tag(SidebarSelection.category(category))
                }
            }
            Section("Hibernation") {
                Label {
                    HStack {
                        Text("Projects")
                        Spacer()
                        if model.isScanningProjects && !model.projectsSized {
                            ProgressView().controlSize(.mini)
                        } else if !model.staleProjects.isEmpty {
                            Text(ByteFormat.string(model.staleStrippable))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help("\(model.staleProjects.count) stale projects could free this by hibernating")
                        }
                    }
                } icon: {
                    Image(systemName: "moon.zzz")
                }
                .tag(SidebarSelection.projects)
            }
            Section("NAS") {
                Label {
                    HStack {
                        Text("Offload")
                        Spacer()
                        if model.isScanningOffloadCandidates {
                            ProgressView().controlSize(.mini)
                        } else if model.offloadCandidateTotal > 0 {
                            Text(ByteFormat.string(model.offloadCandidateTotal))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: model.destinationCheck.isReady ? "externaldrive.connected.to.line.below" : "externaldrive.badge.xmark")
                }
                .help(model.destinationCheck.isReady ? String(localized: "Copy to the NAS, verify, then move to the Trash") : model.destinationCheck.message)
                .tag(SidebarSelection.offload)
                Label("Offloaded", systemImage: "shippingbox.and.arrow.backward")
                    .badge(model.offloadRecords.isEmpty ? nil : Text("\(model.offloadRecords.count)"))
                    .tag(SidebarSelection.offloaded)
            }
            Section("Ground Control") {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .badge(model.history.isEmpty ? nil : Text("\(model.history.count)"))
                    .tag(SidebarSelection.history)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, systemImage: String, bytes: Int64, scanning: Bool = false) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if scanning {
                    ProgressView().controlSize(.mini)
                } else if model.hasScanned {
                    Text(bytes > 0 ? ByteFormat.string(bytes) : "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

extension RuleCategory {
    var symbol: String {
        switch self {
        case .xcode: "hammer"
        case .android: "smartphone"
        case .javascript: "curlybraces"
        case .packageManagers: "shippingbox"
        case .ides: "chevron.left.forwardslash.chevron.right"
        case .containers: "cube"
        case .system: "gearshape"
        case .projects: "folder"
        case .files: "doc"
        }
    }
}

extension Tier {
    var color: Color {
        switch self {
        case .safe: .green
        case .costsTime: .orange
        case .review: .red
        }
    }

    var title: String {
        switch self {
        case .safe: String(localized: "Safe")
        case .costsTime: String(localized: "Costs time")
        case .review: String(localized: "Review")
        }
    }

    var explanation: String {
        switch self {
        case .safe: String(localized: "Comes back by itself; nothing for you to do.")
        case .costsTime: String(localized: "Works again after a re-download or rebuild you'll notice.")
        case .review: String(localized: "Your data, or not automatically recoverable.")
        }
    }
}

struct TierBadge: View {
    let tier: Tier

    var body: some View {
        Text(tier.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tier.color)
            .background(tier.color.opacity(0.14), in: Capsule())
            .help(tier.explanation)
    }
}
