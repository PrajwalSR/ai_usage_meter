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
        readings: [AllowanceReading(recordedAt: now.addingTimeInterval(-90), source: .claudeWeb,
                                  planType: nil,
                                  windows: [window(38, minutes: 300, resetsIn: 2 * 3600 + 21 * 60),
                                            window(63, minutes: 10080, resetsIn: 28 * 3600)])],
        unavailableNote: ""),
    codex: ProviderReading(
        provider: .codex,
        readings: [AllowanceReading(recordedAt: now.addingTimeInterval(-40), source: .chatgptWeb,
                                  planType: "plus",
                                  windows: [window(86, minutes: 10080, resetsIn: 2 * 86400 + 21 * 3600,
                                                   limitId: "codex")])],
        unavailableNote: ""),
    scannedAt: now, scanDuration: 0.02)

func savePNG(_ rep: NSBitmapImageRep, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

// MARK: Panel, light and dark

MainActor.assumeIsolated {
    for (name, appearance, settings) in [("panel-light.png", NSAppearance.Name.aqua, false),
                                         ("panel-dark.png", NSAppearance.Name.darkAqua, false),
                                         ("settings-dark.png", NSAppearance.Name.darkAqua, true)] {
        let panel = UsagePanel(
            model: PanelModel(report: sample, isScanning: false, isWatching: true,
                              showingSettings: settings, claudeSignedIn: true, chatGPTSignedIn: false,
                              launchAtLoginAvailable: true,
                              launchesAtLogin: true, errors: [], now: now),
            actions: PanelActions(refresh: {}, toggleSettings: {}, signInToClaude: {},
                                  signInToChatGPT: {},
                                  toggleLaunchAtLogin: { _ in }, quit: {}))
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

    let label = ProviderIcons.menuBarImage(codex: UsageStore.menuBarFigure(sample.codex!, now: now),
                                           claude: UsageStore.menuBarFigure(sample.claude!, now: now))

    for (name, background, appearance) in [("menubar-light.png", NSColor(white: 0.93, alpha: 1), NSAppearance.Name.aqua),
                                           ("menubar-dark.png", NSColor(white: 0.10, alpha: 1), NSAppearance.Name.darkAqua)] {
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

        // The label resolves its colours under the current appearance, as the
        // menu bar would.
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            label.draw(in: NSRect(x: padding, y: (size.height - label.size.height) / 2,
                                  width: label.size.width, height: label.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        savePNG(rep, name)
    }
}
