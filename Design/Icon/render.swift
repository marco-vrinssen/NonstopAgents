import AppKit

// Renders AppIcon.svg, the full-bleed icon exported from Figma, into the asset catalog.
// macOS expects the artwork on an 824 pt rounded square inside a 1024 pt canvas; an icon
// without that shape is shrunk onto a gray plate by the system.
//
// Small sizes are drawn on whole pixels: the plate and the mark's four rows land exactly on
// the pixel grid, so edges stay sharp on 1x displays instead of smearing over two pixels.
let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("usage: render-icon AppIcon.svg path/to/AppIcon.appiconset")
    exit(1)
}

// The mark's square in the 1024 design and the number of equal rows it is built from.
let markOrigin = 262.0, markSize = 500.0, markRows = 4.0
let lavender = NSColor(srgbRed: 0xC3 / 255, green: 0x99 / 255, blue: 0xFF / 255, alpha: 1)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = Double(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let plateOrigin = (100 / 1024 * px).rounded(), plateSize = px - 2 * plateOrigin
        let plate = NSRect(x: plateOrigin, y: plateOrigin, width: plateSize, height: plateSize)
        let platePath = NSBezierPath(roundedRect: plate, xRadius: (185 / 1024 * px).rounded(), yRadius: (185 / 1024 * px).rounded())
        lavender.setFill()
        platePath.fill()

        // Each row a whole number of pixels, the mark centred on whole pixels.
        let row = max(1, (markSize / 1024 * plateSize / markRows).rounded())
        let mark = row * markRows
        let markStart = plateOrigin + ((plateSize - mark) / 2).rounded()
        let unit = mark / markSize
        NSRect(x: markStart, y: markStart, width: mark, height: mark).clip()
        source.draw(in: NSRect(x: markStart - markOrigin * unit, y: markStart - markOrigin * unit, width: 1024 * unit, height: 1024 * unit))

        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
    }
}
print("Rendered \(args[1]) into \(args[2])")
