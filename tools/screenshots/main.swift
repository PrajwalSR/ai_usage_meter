import AppKit
import SwiftUI

// Renders README screenshots from made-up data, so no real usage, project name
// or account detail can ever end up in the images.
//
// Run with: ./scripts/render-screenshots.sh   (writes docs/images/*.png)

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/images")
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let now = Date()

func window(_ pct: Double, minutes: Int, resetsIn: TimeInterval, limitId: String? = nil) -> AllowanceWindow {
    AllowanceWindow(usedPercent: pct, windowMinutes: minutes,
                    resetsAt: now.addingTimeInterval(resetsIn), limitId: limitId)
}

let sample = UsageReport(
    claude: ProviderReading(
        provider: .claude,
        readings: [AllowanceReading(recordedAt: now.addingTimeInterval(-90), source: .anthropicLive,
                                  planType: nil,
                                  windows: [window(38, minutes: 300, resetsIn: 2 * 3600 + 21 * 60),
                                            window(63, minutes: 10080, resetsIn: 28 * 3600)])],
        unavailableNote: "",
        last5Hours: TokenTotals(input: 1_200_000, output: 180_000, cacheRead: 9_000_000, cacheWrite: 1_100_000, messages: 212),
        last7Days: TokenTotals(input: 21_000_000, output: 2_900_000, cacheRead: 160_000_000, cacheWrite: 19_000_000, messages: 3_104),
        filesSeen: 42, filesReadThisPass: 1, newestLogEntry: now.addingTimeInterval(-240)),
    codex: ProviderReading(
        provider: .codex,
        readings: [AllowanceReading(recordedAt: now.addingTimeInterval(-50 * 60), source: .codexLog,
                                  planType: "prolite",
                                  windows: [window(55, minutes: 10080, resetsIn: 2 * 86400 + 21 * 3600,
                                                   limitId: "codex")])],
        unavailableNote: "",
        last5Hours: TokenTotals(input: 900_000, output: 60_000, cacheRead: 2_400_000, messages: 34),
        last7Days: TokenTotals(input: 60_000_000, output: 3_100_000, cacheRead: 300_000_000, messages: 2_880),
        filesSeen: 97, filesReadThisPass: 0, newestLogEntry: now.addingTimeInterval(-50 * 60)),
    scannedAt: now, scanDuration: 0.02)

func savePNG(_ rep: NSBitmapImageRep, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

// MARK: Panel, light and dark

MainActor.assumeIsolated {
    for (name, appearance) in [("panel-light.png", NSAppearance.Name.aqua),
                               ("panel-dark.png", NSAppearance.Name.darkAqua)] {
        let panel = UsagePanel(
            report: sample, isScanning: false, isWatching: true, liveClaudeEnabled: true,
            webSignedIn: true, onSignInToClaudeWeb: {},
            launchAtLoginAvailable: true, launchesAtLogin: true, errorText: nil, now: now,
            onRefresh: {}, onToggleLiveClaude: { _ in }, onToggleLaunchAtLogin: { _ in }, onQuit: {})
        let host = NSHostingView(rootView: panel
            .background(appearance == .darkAqua ? Color(white: 0.16) : Color(white: 0.97)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        savePNG(rep, name)
    }

    // MARK: Menu bar, light and dark

    let codexText = UsageStore.menuBarText(sample.codex!, now: now)
    let claudeText = UsageStore.menuBarText(sample.claude!, now: now)
    let label = ProviderIcons.menuBarImage(codex: codexText, claude: claudeText)

    for (name, background, ink) in [("menubar-light.png", NSColor(white: 0.93, alpha: 1), NSColor.black),
                                    ("menubar-dark.png", NSColor(white: 0.10, alpha: 1), NSColor.white)] {
        let scale: CGFloat = 2
        let padding: CGFloat = 12
        let size = NSSize(width: label.size.width + padding * 2, height: 28)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        NSRect(origin: .zero, size: size).fill()

        // A template image is drawn black; tint it the way the menu bar would.
        let tinted = NSImage(size: label.size, flipped: false) { rect in
            label.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: padding, y: (size.height - label.size.height) / 2,
                               width: label.size.width, height: label.size.height))
        NSGraphicsContext.restoreGraphicsState()
        savePNG(rep, name)
    }
}
