import GroundControl
import MajorTomCore
import SwiftUI

/// Used / free / reclaimable-by-tier for the volume holding the home folder.
struct DiskGaugeHeader: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        let disk = model.disk
        let tiers = model.reclaimableByTier
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormat.string(disk.freeBytes)) free")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("\(ByteFormat.string(disk.usedBytes)) used of \(ByteFormat.string(disk.totalBytes)) on \(volumeName)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if model.hasScanned {
                        Text("\(ByteFormat.string(model.totalReclaimable)) reclaimable")
                            .font(.title3.weight(.medium))
                            .monospacedDigit()
                    }
                    ScanStatusLine()
                }
            }
            GaugeBar(disk: disk, tiers: tiers)
                .frame(height: 12)
            HStack(spacing: 16) {
                ForEach(Tier.allCases, id: \.self) { tier in
                    LegendDot(color: tier.color, label: tier.title, value: tiers[tier] ?? 0)
                        .help(tier.explanation)
                }
                LegendDot(color: .secondary.opacity(0.5), label: String(localized: "Other used"), value: nil)
                LegendDot(color: .secondary.opacity(0.15), label: String(localized: "Free"), value: disk.freeBytes)
                Spacer()
            }
            .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var volumeName: String {
        (try? model.environment.volumeURL.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? String(localized: "this disk")
    }
}

struct ScanStatusLine: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        Group {
            switch model.scanState {
            case .idle:
                Text("Not scanned yet")
            case .scanning(let done, let total):
                HStack(spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 90)
                    Text("Scanning \(done) of \(total) rules…").monospacedDigit()
                }
            case .done(let at, let duration):
                Text("Scanned \(at, format: .relative(presentation: .named)) in \(duration, format: .number.precision(.fractionLength(1))) s")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct GaugeBar: View {
    let disk: DiskStatus
    let tiers: [Tier: Int64]

    /// Reclaimable bytes are part of "used"; never draw more than that.
    static func segments(used: Double, tiers: [Tier: Int64]) -> (other: Double, [(Color, Double)]) {
        var remaining = used
        let segs: [(Color, Double)] = Tier.allCases.map { tier in
            let v = min(Double(tiers[tier] ?? 0), remaining)
            remaining -= v
            return (tier.color, v)
        }
        return (remaining, segs)
    }

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(disk.totalBytes, 1))
            let used = Double(disk.usedBytes)
            let (other, segments) = Self.segments(used: used, tiers: tiers)
            HStack(spacing: 0) {
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: geo.size.width * other / total)
                ForEach(Array(segments.enumerated().reversed()), id: \.offset) { _, seg in
                    Rectangle().fill(seg.0).frame(width: geo.size.width * seg.1 / total)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(ByteFormat.string(disk.usedBytes)) used, \(ByteFormat.string(disk.freeBytes)) free")
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let value: Int64?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            if let value {
                Text(ByteFormat.string(value)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
