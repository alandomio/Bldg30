import AppKit

// Usage: generate-icon.swift <assets-dir> <iconset-dir>. Renders the R1 SVGs into the iconset and the in-app PNGs.
let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ svg: String, pixels: Int, to url: URL) throws {
    guard let image = NSImage(contentsOf: assets.appendingPathComponent(svg)) else { fatalError("cannot read \(svg)") }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        // The simplified artwork keeps the radar legible at 64 px and below.
        try render(pixels <= 64 ? "icon-r1-small.svg" : "icon-r1.svg", pixels: pixels, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
try render("icon-r1-menubar.svg", pixels: 18, to: assets.appendingPathComponent("MenuBarTemplate.png"))
try render("icon-r1-menubar.svg", pixels: 36, to: assets.appendingPathComponent("MenuBarTemplate@2x.png"))
try render("icon-r1-small.svg", pixels: 96, to: assets.appendingPathComponent("Logo.png"))
