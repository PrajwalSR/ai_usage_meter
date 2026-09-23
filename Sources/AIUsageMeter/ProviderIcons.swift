import AppKit

/// Official Claude and OpenAI marks (from Simple Icons, CC0), bundled as SVG and
/// tinted with the menu bar's label colour so they follow light/dark appearance.
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

    /// One provider's figure in the menu bar: the text, plus the used percentage
    /// that picks its colour (nil when there is no current number).
    struct MenuBarFigure {
        var text: String
        var usedPercent: Double?
    }

    /// Colour band for a used percentage: plain below 25%, then yellow, orange
    /// and red: a warmth scale, so there's no "all good" green. Only the percentage is coloured; the countdown and logo stay in
    /// the menu bar's own colour.
    enum UsageBand: Equatable {
        case plain, low, medium, high

        init(usedPercent: Double) {
            switch usedPercent {
            case ..<25: self = .plain
            case ..<50: self = .low
            case ..<80: self = .medium
            default: self = .high
            }
        }

        var color: NSColor {
            switch self {
            case .plain: return .labelColor
            case .low: return .systemYellow
            case .medium: return .systemOrange
            case .high: return .systemRed
            }
        }
    }

    /// Menu bar image: icon + figure for each provider. Not a template image,
    /// because templates are one colour. Instead the drawing handler runs at
    /// display time under the menu bar's appearance, so `labelColor` resolves to
    /// white on a dark menu bar and black on a light one.
    static func menuBarImage(codex: MenuBarFigure?, claude: MenuBarFigure?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let measure: [NSAttributedString.Key: Any] = [.font: font]
        var items: [(NSImage, MenuBarFigure)] = []
        if let codex { items.append((ProviderIcons.codex, codex)) }
        if let claude { items.append((ProviderIcons.claude, claude)) }
        if items.isEmpty { items.append((NSImage(), MenuBarFigure(text: "AI …"))) }

        let iconGap: CGFloat = 4, itemGap: CGFloat = 10, height: CGFloat = 18
        let widths = items.map { size + iconGap + ($0.1.text as NSString).size(withAttributes: measure).width }
        let total = widths.reduce(0, +) + itemGap * CGFloat(items.count - 1)

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, (icon, figure)) in items.enumerated() {
                tinted(icon, .labelColor).draw(in: NSRect(x: x, y: (height - size) / 2,
                                                          width: size, height: size))
                let label = attributed(figure, font: font)
                label.draw(at: NSPoint(x: x + size + iconGap, y: (height - label.size().height) / 2))
                x += widths[i] + itemGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// "38%" in its band colour, the rest ("in 2h 21m", "?", "—") in the label colour.
    private static func attributed(_ figure: MenuBarFigure, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: figure.text,
                                            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let used = figure.usedPercent,
           let pctEnd = figure.text.firstIndex(of: "%") {
            let range = NSRange(figure.text.startIndex...pctEnd, in: figure.text)
            out.addAttribute(.foregroundColor, value: UsageBand(usedPercent: used).color, range: range)
        }
        return out
    }

    /// The template logos drawn in one colour.
    private static func tinted(_ icon: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
