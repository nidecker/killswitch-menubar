import AppKit

/// App emblem: a keyhole, filled with the current color.
/// Shared by the menu bar icon and the app icon generator.
/// Drawn as a single outline: with a semi-transparent color (the menu bar text
/// color), two overlapping shapes would leave a darker band.
func drawKeyhole(in rect: NSRect) {
    let size = min(rect.width, rect.height)
    let origin = NSPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: origin.x + size * x, y: origin.y + size * y)
    }

    // Round head traced over the top, then the flared foot
    let path = NSBezierPath()
    path.appendArc(withCenter: point(0.5, 0.73), radius: size * 0.25, startAngle: -66, endAngle: 246)
    path.line(to: point(0.30, 0.02))
    path.line(to: point(0.70, 0.02))
    path.close()
    path.fill()
}
