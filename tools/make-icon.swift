// Generates the app iconset: the white keyhole inside the green ring,
// on a dark plate following macOS icon proportions.
// Compiled with Sources/Keyhole.swift by tools/make-icon.sh.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("Usage: make-icon <folder.iconset>")
    exit(1)
}
let iconset = URL(fileURLWithPath: arguments[1])

func icon(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024

    // Apple grid: 824 plate on a 1024 canvas, 185 corner radius
    let plate = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                             xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(white: 0.26, alpha: 1), ending: NSColor(white: 0.09, alpha: 1))!
        .draw(in: plate, angle: -90)

    let ring = NSBezierPath(ovalIn: NSRect(x: 212 * s, y: 212 * s, width: 600 * s, height: 600 * s))
    ring.lineWidth = 46 * s
    NSColor.systemGreen.setStroke()
    ring.stroke()

    NSColor.white.setFill()
    let box = 330 * s
    drawKeyhole(in: NSRect(x: 512 * s - box / 2, y: 512 * s - box / 2, width: box, height: box))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! icon(size * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
