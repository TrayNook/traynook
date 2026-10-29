import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/generate-icon.swift path/to/AppIcon.iconset")
}
let artworkURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Support/AppIcon.png")
guard let artwork = NSImage(contentsOf: artworkURL),
      let representation = artwork.representations.first,
      representation.pixelsWide > 0,
      representation.pixelsWide == representation.pixelsHigh else {
    fatalError("Support/AppIcon.png must be a readable square image.")
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
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 512)
    scale.concat()
    // Preserve the existing 448/512 tile footprint after the master's transparent inset.
    artwork.draw(in: NSRect(x: 14, y: 14, width: 484, height: 484),
                 from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, name: "icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
