import AppKit

/// The menu bar dot. A template image, so macOS draws it black or white to match the
/// menu bar, its wallpaper tint and the highlighted state. Digits are cut out of the
/// fill rather than drawn on top, which keeps them legible in light and dark bars.
enum StatusDot {
    static let height: CGFloat = 15
    private static let small: CGFloat = 9
    private static let stroke: CGFloat = 1.5
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)

    /// - Parameters:
    ///   - count: agents working, shown inside the dot.
    ///   - filled: the Mac is being kept awake.
    ///   - dimmed: Until is off or paused.
    static func image(count: Int?, filled: Bool, dimmed: Bool) -> NSImage {
        let text = count.map { $0 > 99 ? "99+" : String($0) }
        let textWidth = text.map { ($0 as NSString).size(withAttributes: [.font: font]).width } ?? 0
        let badge = text != nil
        let width = badge ? max(height, ceil(textWidth) + 8) : height
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let alpha: CGFloat = dimmed ? 0.45 : 1
            let color = NSColor.black.withAlphaComponent(alpha)
            let side = badge ? height : small
            let shape = NSRect(x: (rect.width - (badge ? width : side)) / 2, y: (rect.height - side) / 2,
                               width: badge ? width : side, height: side)

            if filled {
                color.setFill()
                NSBezierPath(roundedRect: shape, xRadius: side / 2, yRadius: side / 2).fill()
            } else {
                color.setStroke()
                let ring = NSBezierPath(roundedRect: shape.insetBy(dx: stroke / 2, dy: stroke / 2),
                                        xRadius: (side - stroke) / 2, yRadius: (side - stroke) / 2)
                ring.lineWidth = stroke
                ring.stroke()
            }

            if let text {
                let size = (text as NSString).size(withAttributes: [.font: font])
                let origin = NSPoint(x: shape.midX - size.width / 2, y: (rect.height - font.capHeight) / 2 + font.descender)
                if filled { NSGraphicsContext.current?.compositingOperation = .destinationOut }
                (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: filled ? NSColor.black : color])
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
