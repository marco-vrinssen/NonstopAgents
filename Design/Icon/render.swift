import AppKit

// Renders AppIcon.svg, the full-bleed icon, into the asset catalog at every size.
let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("usage: render-icon AppIcon.svg path/to/AppIcon.appiconset")
    exit(1)
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = Double(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // macOS wants an 824 pt rounded square in 1024 pt or adds a gray plate; whole pixels keep 1x edges sharp.
        let plateOrigin = (100 / 1024 * px).rounded(), plateSize = px - 2 * plateOrigin
        let plate = NSRect(x: plateOrigin, y: plateOrigin, width: plateSize, height: plateSize)
        NSBezierPath(roundedRect: plate, xRadius: (185 / 1024 * px).rounded(), yRadius: (185 / 1024 * px).rounded()).addClip()
        source.draw(in: plate)

        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
    }
}
print("Rendered \(args[1]) into \(args[2])")
