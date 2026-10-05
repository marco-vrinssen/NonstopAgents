import AppKit

// Renders AppIcon.svg, the full-bleed icon exported from Figma, into the asset catalog.
// macOS expects the artwork on an 824 pt rounded square inside a 1024 pt canvas; an icon
// without that shape is shrunk onto a gray plate by the system.
let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("usage: render-icon AppIcon.svg path/to/AppIcon.appiconset")
    exit(1)
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let unit = CGFloat(px) / 1024
        let plate = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        NSBezierPath(roundedRect: plate, xRadius: 185 * unit, yRadius: 185 * unit).addClip()
        source.draw(in: plate)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
    }
}
print("Rendered \(args[1]) into \(args[2])")
