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
        /// The value part: "38% in 2h 21m", "38% · 63%", "2h 21m", "?" or "—".
        var text: String
        /// The headline percentage, which colours the first "N%" in `text`.
        var usedPercent: Double? = nil
        /// Percentages for any further "N%" in `text`, in order (All limits).
        var morePercents: [Double] = []
        /// Account name drawn before the value, in the plain label colour.
        var name: String? = nil
        var showsLogo = true

        var percents: [Double] { (usedPercent.map { [$0] } ?? []) + morePercents }
    }

    /// Colour band for a used percentage: plain below 25%, then yellow, orange
    /// and red: a warmth scale, so there's no "all good" green. Only the
    /// percentages are coloured (or the countdown, when it is shown alone); the
    /// name and logo stay in the menu bar's own colour.
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
        var figures: [(Provider, MenuBarFigure)] = []
        if let codex { figures.append((.codex, codex)) }
        if let claude { figures.append((.claude, claude)) }
        return menuBarImage(figures)
    }

    static func menuBarImage(_ figures: [(Provider, MenuBarFigure)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        var items: [(NSImage?, NSAttributedString)] = figures.map { provider, figure in
            (figure.showsLogo ? (provider == .codex ? codex : claude) : nil,
             attributed(figure, font: font))
        }
        if items.isEmpty {
            items.append((nil, NSAttributedString(string: "AI …", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor])))
        }

        let iconGap: CGFloat = 4, itemGap: CGFloat = 10, height: CGFloat = 18
        let widths = items.map { icon, label in
            (icon == nil ? 0 : size + iconGap) + label.size().width
        }
        let total = widths.reduce(0, +) + itemGap * CGFloat(items.count - 1)

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, (icon, label)) in items.enumerated() {
                var textX = x
                if let icon {
                    tinted(icon, .labelColor).draw(in: NSRect(x: x, y: (height - size) / 2,
                                                              width: size, height: size))
                    textX += size + iconGap
                }
                label.draw(at: NSPoint(x: textX, y: (height - label.size().height) / 2))
                x += widths[i] + itemGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Name in the label colour, then the value with each "N%" in its band
    /// colour. A value with no "%" (time left only) is coloured as a whole by
    /// the headline percentage, so the warning still shows.
    static func attributed(_ figure: MenuBarFigure, font: NSFont) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString()
        if let name = figure.name, !name.isEmpty {
            out.append(NSAttributedString(string: name + " ", attributes: plain))
        }
        let valueStart = out.length
        out.append(NSAttributedString(string: figure.text, attributes: plain))

        let percents = figure.percents
        guard !percents.isEmpty else { return out }
        let value = figure.text as NSString
        let matches = percentPattern.matches(in: figure.text, range: NSRange(location: 0, length: value.length))
        if matches.isEmpty {
            out.addAttribute(.foregroundColor, value: UsageBand(usedPercent: percents[0]).color,
                             range: NSRange(location: valueStart, length: value.length))
        }
        for (match, used) in zip(matches, percents) {
            out.addAttribute(.foregroundColor, value: UsageBand(usedPercent: used).color,
                             range: NSRange(location: valueStart + match.range.location,
                                            length: match.range.length))
        }
        return out
    }

    private static let percentPattern = try! NSRegularExpression(pattern: "[0-9]+%")

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
