import AppKit
import GroundControl
import MajorTomCore
import SwiftUI

/// The status item: a drive icon that gains a warning badge below the alert threshold. It's always alive,
/// so it also hands SwiftUI's `openWindow` to AppKit-side callers (notification taps).
struct MenuBarLabel: View {
    @Environment(SpaceWatch.self) private var watch
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(lowSpace: watch.isBelowThreshold))
            .accessibilityLabel(watch.isBelowThreshold ? "Major Tom — low disk space" : "Major Tom")
            .onAppear {
                AppServices.shared.openWindow = openWindow
                AppServices.shared.ensureMainWindowAtLaunch()
            }
    }
}

/// The app icon's planet-and-orbit, as a monochrome template image for the menu bar (macOS tints it).
/// Below the free-space threshold it gains a badge dot.
enum MenuBarIcon {
    @MainActor private static var cache: [Bool: NSImage] = [:]

    @MainActor static func image(lowSpace: Bool) -> NSImage {
        if let cached = cache[lowSpace] { return cached }
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: 10, y: 7.5)
            let rot: CGFloat = 0.32
            func orbit(_ a0: CGFloat, _ a1: CGFloat) -> CGPath {
                let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rot).scaledBy(x: 1, y: 0.34)
                let p = CGMutablePath()
                p.addArc(center: .zero, radius: 9.2, startAngle: a0, endAngle: a1, clockwise: false, transform: t)
                return p
            }
            ctx.setStrokeColor(.black)
            ctx.setFillColor(.black)
            ctx.setLineCap(.round)
            // Far side of the orbit, then the planet, then a gap and the near side over it.
            ctx.setLineWidth(1.4)
            ctx.addPath(orbit(0.15, .pi - 0.15))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: c.x - 4.3, y: c.y - 4.3, width: 8.6, height: 8.6))
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3.0)
            ctx.addPath(orbit(.pi + 0.35, 2 * .pi - 0.35))
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setLineWidth(1.4)
            ctx.addPath(orbit(.pi, 2 * .pi))
            ctx.strokePath()
            if lowSpace {
                let badge = CGRect(x: 16.4, y: 10.4, width: 5.2, height: 5.2)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: badge.insetBy(dx: -1.2, dy: -1.2))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: badge)
            }
            return true
        }
        image.isTemplate = true
        cache[lowSpace] = image
        return image
    }
}

/// The menu bar popover: free space, what's safe to clean, stale projects, Quick clean and open window.
struct MenuBarView: View {
    @Environment(GroundControlModel.self) private var model
    @Environment(SpaceWatch.self) private var watch
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GaugeBar(disk: model.disk, tiers: model.reclaimableByTier)
                .frame(height: 8)
            if watch.isBelowThreshold { lowSpaceWarning }
            Divider()
            VStack(spacing: 8) {
                safeRow
                projectsRow
            }
            actions
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            AppServices.shared.openWindow = openWindow
            model.refreshDisk()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(ByteFormat.string(model.disk.freeBytes)) free")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(watch.isBelowThreshold ? .orange : .primary)
                Text("\(ByteFormat.string(model.disk.usedBytes)) used of \(ByteFormat.string(model.disk.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.environment.isFixture {
                Text("Fixture").font(.caption.weight(.medium)).foregroundStyle(.purple)
            }
        }
    }

    private var lowSpaceWarning: some View {
        Label("Below your \(model.settings.lowSpaceThresholdGB) GB alert threshold",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
    }

    private var safeRow: some View {
        row(icon: "sparkles", color: Tier.safe.color, title: String(localized: "Safe to clean")) {
            if model.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.hasScanned ? ByteFormat.string(model.safeReclaimable) : String(localized: "Scanning…"))
                }
            } else if model.hasScanned {
                Text(ByteFormat.string(model.safeReclaimable))
            } else {
                Text("Not scanned yet")
            }
        }
        .help("Caches that regenerate on their own. Quick clean selects exactly these and shows them for review.")
    }

    private var projectsRow: some View {
        row(icon: "moon.zzz", color: .indigo, title: String(localized: "Stale projects")) {
            if model.isScanningProjects && !model.projectsSized {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring…")
                }
            } else if model.projectScanState == .idle {
                Text("Not scanned yet")
            } else {
                let n = model.staleProjects.count
                Text(n == 0 ? "None" : "\(n) · \(ByteFormat.string(model.staleStrippable))")
            }
        }
        .help("Projects untouched for \(model.settings.staleAfterDays) days with dependencies or build output to strip. Hibernate them from the Projects list — never part of Quick clean.")
    }

    private func row(icon: String, color: Color, title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
            Spacer()
            value()
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                AppServices.shared.quickCleanFromShortcut()
            } label: {
                Label("Quick Clean…", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .primaryActionButtonStyle()
            .disabled(quickCleanDisabled)
            .help("Selects every safe item and opens the review sheet. Nothing is removed until you confirm.")

            Button {
                dismiss()
                AppServices.shared.showMainWindow()
            } label: {
                Text("Open Major Tom")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }

    /// Enabled before the first scan too (it scans first), but not when a scan found nothing safe.
    private var quickCleanDisabled: Bool {
        model.cleanSession != nil || (model.hasScanned && !model.isScanning && model.safeReclaimable == 0)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Rescan") {
                model.startScanAll()
                model.startProjectScan()
            }
            .disabled(model.isScanning)
            Button("Settings…") {
                dismiss()
                NSApp.activate()
                openSettings()
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}
