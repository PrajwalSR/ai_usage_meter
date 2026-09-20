import AppKit

/// Official Claude and OpenAI marks (from Simple Icons, CC0), bundled as SVG and
/// used as template images so they follow the menu bar's light/dark appearance.
enum ProviderIcons {
    static let size: CGFloat = 15

    static let claude = load("claude")
    static let codex = load("openai")

    private static func load(_ name: String) -> NSImage {
        let url = Bundle.main.url(forResource: name, withExtension: "svg")
            ?? URL(fileURLWithPath: "assets/\(name).svg")
        let image = NSImage(contentsOf: url) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    /// Menu bar image: icon + figure for each provider, drawn as one template
    /// image. Text attachments are not reliably tinted in the menu bar, so the
    /// whole label is rendered here and macOS tints it for light or dark.
    static func menuBarImage(codex: String?, claude: String?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        var items: [(NSImage, String)] = []
        if let codex { items.append((ProviderIcons.codex, codex)) }
        if let claude { items.append((ProviderIcons.claude, claude)) }
        if items.isEmpty { items.append((NSImage(), "AI …")) }

        let iconGap: CGFloat = 4, itemGap: CGFloat = 10, height: CGFloat = 18
        let widths = items.map { size + iconGap + ($0.1 as NSString).size(withAttributes: attrs).width }
        let total = widths.reduce(0, +) + itemGap * CGFloat(items.count - 1)

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, (icon, text)) in items.enumerated() {
                icon.draw(in: NSRect(x: x, y: (height - size) / 2, width: size, height: size))
                let textSize = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: x + size + iconGap,
                                                    y: (height - textSize.height) / 2),
                                        withAttributes: attrs)
                x += widths[i] + itemGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
