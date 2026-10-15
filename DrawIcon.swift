import AppKit
import Foundation

// Original geometric artwork for Mac Thermal. No fonts, SF Symbols,
// third-party images, or copied vector paths are used by this generator.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawWave(_ points: [NSPoint], width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    path.curve(to: points[3], controlPoint1: points[1], controlPoint2: points[2])
    path.curve(to: points[6], controlPoint1: points[4], controlPoint2: points[5])
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setShouldAntialias(true)
    let inset = size * 0.07
    let background = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2), xRadius: size * 0.21, yRadius: size * 0.21)
    NSGradient(starting: NSColor(calibratedRed: 0.105, green: 0.19, blue: 0.29, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.14, alpha: 1))!.draw(in: background, angle: -80)
    // Draw normalized, independent wave bands, each with a different phase and
    // height. Wide, rounded strokes remain distinct at the 16-pixel size.
    let transform = NSAffineTransform()
    transform.scale(by: size / 1024)
    transform.concat()
    drawWave([
        NSPoint(x: 269, y: 302), NSPoint(x: 225, y: 409), NSPoint(x: 371, y: 450), NSPoint(x: 330, y: 564),
        NSPoint(x: 311, y: 618), NSPoint(x: 265, y: 651), NSPoint(x: 306, y: 724)
    ], width: 78, color: NSColor(calibratedRed: 0.34, green: 0.91, blue: 0.77, alpha: 1))
    drawWave([
        NSPoint(x: 488, y: 267), NSPoint(x: 429, y: 397), NSPoint(x: 592, y: 460), NSPoint(x: 549, y: 583),
        NSPoint(x: 531, y: 636), NSPoint(x: 471, y: 690), NSPoint(x: 519, y: 767)
    ], width: 78, color: NSColor(calibratedRed: 0.33, green: 0.68, blue: 1, alpha: 1))
    drawWave([
        NSPoint(x: 709, y: 303), NSPoint(x: 657, y: 410), NSPoint(x: 797, y: 447), NSPoint(x: 766, y: 554),
        NSPoint(x: 752, y: 604), NSPoint(x: 700, y: 642), NSPoint(x: 727, y: 699)
    ], width: 78, color: NSColor(calibratedRed: 1, green: 0.71, blue: 0.36, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
