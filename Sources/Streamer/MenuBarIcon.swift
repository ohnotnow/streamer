import AppKit

/// The menubar icon: a broadcast mast drawn in code as a template image, so it follows the bar's
/// light or dark look. Off is a hollow mast with no waves; ready fills the mast and adds one wave
/// either side; on air adds a second, outer wave, the "glow".
enum MenuBarIcon {
    enum State { case off, ready, onAir }

    /// Points. Menubar template images are 18 high on macOS.
    static let size = NSSize(width: 18, height: 18)

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch state {
        case .off: "Streamer, off"
        case .ready: "Streamer, ready, nobody listening"
        case .onAir: "Streamer, on air"
        }
        return image
    }

    /// Everything is black on clear; the template mechanism recolours it.
    private static func draw(_ state: State) {
        NSColor.black.set()
        let stroke: CGFloat = 1.5
        let centre = NSPoint(x: 9, y: 10.5)

        // Mast: a stalk down to a small base.
        let mast = NSBezierPath()
        mast.move(to: NSPoint(x: centre.x, y: centre.y - 2))
        mast.line(to: NSPoint(x: centre.x, y: 2))
        mast.move(to: NSPoint(x: centre.x - 2.5, y: 2))
        mast.line(to: NSPoint(x: centre.x + 2.5, y: 2))
        mast.lineWidth = stroke
        mast.lineCapStyle = .round
        mast.stroke()

        // Head of the mast: hollow when off, filled when serving.
        let head = NSBezierPath(ovalIn: NSRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4))
        if state == .off {
            head.lineWidth = 1.25
            head.stroke()
        } else {
            head.fill()
        }

        // Waves: one pair when ready, two when on air.
        let radii: [CGFloat] = switch state {
        case .off: []
        case .ready: [4.5]
        case .onAir: [4.5, 7.5]
        }
        for radius in radii {
            for (start, end) in [(-40.0, 40.0), (140.0, 220.0)] {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: end)
                wave.lineWidth = stroke
                wave.lineCapStyle = .round
                wave.stroke()
            }
        }
    }
}
