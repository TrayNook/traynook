import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/generate-icon.swift path/to/AppIcon.iconset")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(pixels: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 512)
    scale.concat()
    NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 448, height: 448), xRadius: 100, yRadius: 100).fill()
    NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 328, width: 312, height: 58), xRadius: 18, yRadius: 18).fill()
    NSBezierPath(roundedRect: NSRect(x: 196, y: 126, width: 216, height: 180), xRadius: 24, yRadius: 24).fill()
    NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.38, alpha: 1).setFill()
    for x in [280, 324, 368] {
        NSBezierPath(ovalIn: NSRect(x: x, y: 345, width: 24, height: 24)).fill()
    }
    for y in [166, 210, 254] {
        NSBezierPath(roundedRect: NSRect(x: 230, y: y, width: 146, height: 16), xRadius: 8, yRadius: 8).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, name: "icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
