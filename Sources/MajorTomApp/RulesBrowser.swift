import GroundControl
import MajorTomCore
import SwiftUI

/// Rule list on the left, the selected rule's copy, actions and items on the right.
struct RulesBrowser: View {
    @Environment(GroundControlModel.self) private var model
    let category: RuleCategory?
    @Binding var selectedRuleID: String?

    var body: some View {
        let rules = model.rules(in: category)
        HSplitView {
            RuleListView(rules: rules, selection: $selectedRuleID)
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 440)
            Group {
                if let id = selectedRuleID, let rule = model.rule(id: id) {
                    RuleDetailView(rule: rule)
                        .id(rule.id)
                } else {
                    ContentUnavailableView("Select a rule", systemImage: "sidebar.left",
                                           description: Text("Pick a rule to see what it would remove and what that costs you."))
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // `--select-rule <id>` (dev aid for snapshots) opens a specific rule.
            if let wanted = Snapshotter.argument("--select-rule"), rules.contains(where: { $0.id == wanted }) {
                selectedRuleID = wanted
            } else if selectedRuleID == nil {
                selectedRuleID = rules.first?.id
            }
        }
        .onChange(of: category) { selectedRuleID = model.rules(in: category).first?.id }
    }
}

struct RuleListView: View {
    @Environment(GroundControlModel.self) private var model
    let rules: [Rule]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(rules) { rule in
                RuleRow(rule: rule).tag(rule.id)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView("No rules here", systemImage: "moon.stars",
                                       description: Text("All rules in this category are turned off in Settings."))
            }
        }
    }
}

private struct RuleRow: View {
    @Environment(GroundControlModel.self) private var model
    let rule: Rule

    var body: some View {
        let items = model.items(ruleID: rule.id)
        let reclaimable = model.reclaimable(ruleID: rule.id)
        let result = model.results[rule.id]
        HStack(alignment: .top, spacing: 8) {
            RuleCheckbox(rule: rule)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(localized(rule.title)).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 6)
                    if model.scanningRuleIDs.contains(rule.id) {
                        ProgressView().controlSize(.small)
                    } else if result != nil {
                        Text(reclaimable > 0 ? ByteFormat.string(reclaimable) : sizeWhenNothingCleanable(items))
                            .monospacedDigit()
                            .foregroundStyle(reclaimable > 0 ? .primary : .secondary)
                    }
                }
                HStack(spacing: 6) {
                    TierBadge(tier: rule.tier)
                    if let result {
                        if !result.deniedPaths.isEmpty {
                            Text(items.isEmpty ? "nothing found" : "\(items.count) item\(items.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                            Label("\(result.deniedPaths.joined(separator: ", ")) locked", systemImage: "lock.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        } else if result.error != nil {
                            Label("Couldn't read", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.orange)
                        } else {
                            Text(items.isEmpty ? "nothing found" : "\(items.count) item\(items.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                Text(localized(rule.regenCost))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func sizeWhenNothingCleanable(_ items: [Item]) -> String {
        let found = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return found > 0 ? String(localized: "\(ByteFormat.string(found)) (report)") : "—"
    }
}

/// Tri-state checkbox for all cleanable items in a rule.
struct RuleCheckbox: View {
    @Environment(GroundControlModel.self) private var model
    let rule: Rule

    var body: some View {
        let cleanable = model.items(ruleID: rule.id).filter(\.isCleanable)
        let bindings = cleanable.map { item in
            Binding(get: { model.isChecked(ruleID: rule.id, itemID: item.id) },
                    set: { model.setChecked($0, ruleID: rule.id, itemID: item.id) })
        }
        Group {
            if cleanable.isEmpty {
                // Toggle(sources:) over nothing reads as "on"; show an empty, disabled box instead.
                Toggle(isOn: .constant(false)) { EmptyView() }.disabled(true)
            } else {
                Toggle(sources: bindings, isOn: \.self) { EmptyView() }
            }
        }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(cleanable.isEmpty ? "Nothing cleanable" : "Select all \(cleanable.count) cleanable items")
    }
}
