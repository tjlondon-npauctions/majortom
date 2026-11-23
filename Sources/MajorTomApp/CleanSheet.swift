import GroundControl
import MajorTomCore
import SwiftUI

/// Review -> confirm -> progress -> measured result.
struct CleanSheet: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Group {
            if let session = model.cleanSession {
                switch session.phase {
                case .reviewing:
                    ReviewView(session: session)
                case .cleaning(let done, let total, let current):
                    CleaningView(done: done, total: total, current: current)
                case .finished(let report):
                    ResultView(report: report)
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 620)
    }
}

private struct ReviewView: View {
    @Environment(GroundControlModel.self) private var model
    let session: CleanSession

    var body: some View {
        let plan = session.plan
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.hibernatesProjects ? "Review before hibernating" : "Review before cleaning").font(.title2.weight(.semibold))
                Text(headline(plan))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(Tier.allCases, id: \.self) { tier in
                        if let bytes = plan.estimatedBytesByTier[tier] {
                            HStack(spacing: 4) {
                                TierBadge(tier: tier)
                                Text(ByteFormat.string(bytes)).monospacedDigit()
                            }
                        }
                    }
                }
                .font(.callout)
            }
            .padding(20)

            Divider()

            List {
                ForEach(plan.groups) { group in
                    Section {
                        ForEach(group.actions) { action in
                            PlanRow(name: localized(action.title), detail: action.commandLine, method: String(localized: "runs command"),
                                    bytes: nil, status: session.dryRunStatus(ruleID: group.ruleID, actionID: action.id),
                                    monospacedDetail: true)
                        }
                        ForEach(group.items) { item in
                            PlanRow(name: item.displayName, detail: item.path?.path, method: methodLabel(item),
                                    bytes: item.size, status: session.dryRunStatus(ruleID: group.ruleID, itemID: item.id))
                        }
                    } header: {
                        GroupHeader(group: group)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                warnings(plan)
                HStack {
                    if case .reviewing(.none) = session.phase {
                        ProgressView().controlSize(.small)
                        Text("Re-checking every path…").foregroundStyle(.secondary)
                    } else if let skipped = skippedCount, skipped > 0 {
                        Label("\(skipped) will be skipped (see reasons above)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelReview() }
                        .keyboardShortcut(.cancelAction)
                    Button(role: .destructive) {
                        Task { await model.confirmClean() }
                    } label: {
                        Text(confirmTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.canConfirm)
                    .help("⌘↩")
                }
            }
            .padding(20)
        }
    }

    private var skippedCount: Int? {
        guard case .reviewing(let report?) = session.phase else { return nil }
        return report.outcomes.filter { $0.status != .wouldClean }.count
    }

    private var confirmTitle: String {
        let verb = session.plan.hibernatesProjects ? String(localized: "Hibernate") : String(localized: "Clean")
        if let bytes = session.confirmedEstimate, bytes > 0 { return String(localized: "\(verb) \(ByteFormat.string(bytes))") }
        return verb
    }

    private func headline(_ plan: CleanPlan) -> String {
        var parts: [String] = []
        if plan.itemCount > 0 {
            parts.append(String(localized: "\(plan.itemCount) item\(plan.itemCount == 1 ? "" : "s"), about \(ByteFormat.string(plan.estimatedBytes))"))
        }
        if plan.actionCount > 0 { parts.append(String(localized: "\(plan.actionCount) command\(plan.actionCount == 1 ? "" : "s")")) }
        let summary = ListFormatter.localizedString(byJoining: parts)
        if model.environment.isFixture {
            return String(localized: "This removes exactly what is listed below from the fixture folder: \(summary).")
        }
        return String(localized: "This removes exactly what is listed below: \(summary).")
    }

    private func methodLabel(_ item: Item) -> String {
        switch item.methodOverride {
        case .trash: String(localized: "to Trash")
        case .command: String(localized: "via tool")
        case .deleteContents: String(localized: "empty folder")
        default: String(localized: "delete")
        }
    }

    @ViewBuilder
    private func warnings(_ plan: CleanPlan) -> some View {
        let costly = plan.groups.filter { $0.tier == .costsTime }
        let review = plan.groups.filter { $0.tier == .review }
        if plan.hibernatesProjects {
            Label("Each project needs its restore command (shown above) before it builds or runs again.",
                  systemImage: "moon.zzz")
                .foregroundStyle(.orange)
        } else if !costly.isEmpty {
            Label("\(costly.count) rule\(costly.count == 1 ? "" : "s") will cost you time to get back — see “What it costs” above.",
                  systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
        if !review.isEmpty {
            let trashed = plan.trashedItemCount
            Label(trashed > 0
                  ? "\(trashed) item\(trashed == 1 ? "" : "s") go to the Trash; the rest of the review-tier items can't be put back."
                  : "Review-tier items can't be put back.",
                  systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
        }
        Text("Space is measured from the disk's free space before and after, so the result can differ from the estimate.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct GroupHeader: View {
    let group: CleanPlan.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(localized(group.title)).font(.headline).foregroundStyle(.primary)
                TierBadge(tier: group.tier)
                Spacer()
                if group.estimatedBytes > 0 {
                    Text(ByteFormat.string(group.estimatedBytes)).monospacedDigit().foregroundStyle(.primary)
                }
            }
            Text(localized(group.impact)).fixedSize(horizontal: false, vertical: true)
            Text("Comes back: \(localized(group.recovery))  ·  Cost: \(localized(group.regenCost))")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(group.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(group.notes, id: \.self) { note in
                Text(note).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .textCase(nil)
    }
}

private struct PlanRow: View {
    let name: String
    let detail: String?
    let method: String
    let bytes: Int64?
    let status: CleanOutcome.Status?
    var monospacedDetail = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusIcon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(monospacedDetail ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let reason = skipReason {
                    Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(method).font(.caption).foregroundStyle(.secondary)
            Text(bytes.map(ByteFormat.string) ?? "").monospacedDigit().frame(width: 72, alignment: .trailing)
        }
    }

    private var skipReason: String? {
        switch status {
        case .skipped(let why), .failed(let why): String(localized: "Will be skipped: \(why)")
        default: nil
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case nil: ProgressView().controlSize(.mini)
        case .wouldClean?, .cleaned?: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .partial?: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .skipped?, .failed?: Image(systemName: "minus.circle").foregroundStyle(.orange)
        }
    }
}

private struct CleaningView: View {
    let done: Int
    let total: Int
    let current: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Cleaning…").font(.title2.weight(.semibold))
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(maxWidth: 420)
            Text(current.isEmpty ? "Starting…" : "\(done) of \(total): \(current)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

private struct ResultView: View {
    @Environment(GroundControlModel.self) private var model
    let report: CleanReport

    var body: some View {
        let cleaned = report.outcomes.filter { $0.status == .cleaned }
        let partial = report.outcomes.filter { if case .partial = $0.status { true } else { false } }
        let problems = report.outcomes.filter { $0.status != .cleaned }
        VStack(alignment: .leading, spacing: 0) {
            if problems.isEmpty { Spacer() }
            VStack(spacing: 8) {
                Image(systemName: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(problems.isEmpty ? .green : .orange)
                Text(reclaimedTitle).font(.title.weight(.semibold)).monospacedDigit()
                Text("Measured from free space before and after. Estimated from the scan: \(ByteFormat.string(report.estimatedBytes)).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(partial.isEmpty
                     ? "\(cleaned.count) of \(report.outcomes.count) done · logged to History"
                     : "\(cleaned.count) of \(report.outcomes.count) done, \(partial.count) partly · logged to History")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(24)

            if !problems.isEmpty {
                Divider()
                List(problems, id: \.itemID) { o in
                    ProblemRow(outcome: o, statusText: statusText(o.status))
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.dismissResult() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
    }

    private var reclaimedTitle: String {
        let bytes = report.reclaimedBytes ?? 0
        return bytes > 0 ? String(localized: "\(ByteFormat.string(bytes)) reclaimed") : String(localized: "No measurable change in free space")
    }

    private func statusText(_ s: CleanOutcome.Status) -> String {
        switch s {
        case .skipped(let why): String(localized: "Skipped: \(why)")
        case .failed(let why): String(localized: "Failed: \(why)")
        case .partial(let what): String(localized: "Partly done: \(what)")
        case .cleaned: String(localized: "Done")
        case .wouldClean: String(localized: "Not run")
        }
    }
}

/// A result row for anything not fully done: the reason, then (for deletes) each entry left behind and what to do.
private struct ProblemRow: View {
    let outcome: CleanOutcome
    let statusText: String
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.displayName)
                Text(statusText).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if outcome.leftBehindCount > 0 {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(outcome.leftBehind, id: \.self) { left in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(left.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Text(left.advice).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Text(left.underlying).font(.caption2).foregroundStyle(.secondary)
                                }
                                .textSelection(.enabled)
                            }
                            if outcome.leftBehindCount > outcome.leftBehind.count {
                                Text("… and \(outcome.leftBehindCount - outcome.leftBehind.count) more")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Text(leftLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if case .partial = outcome.status { return "circle.lefthalf.filled" }
        return "exclamationmark.circle"
    }

    private var leftLabel: String {
        let n = outcome.leftBehindCount
        let size = outcome.leftBehindBytes > 0 ? " (\(ByteFormat.string(outcome.leftBehindBytes)))" : ""
        return String(localized: "\(n) entr\(n == 1 ? "y" : "ies") left behind\(size)")
    }
}
