import AppKit

private let size = 1024
private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

private func polygon(_ points: [NSPoint], fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.close()
    fill.setFill()
    path.fill()
}

private func ellipse(_ rect: NSRect, fill: NSColor) {
    fill.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

private func strokeCurve(_ points: [NSPoint], control1: NSPoint, control2: NSPoint,
                         color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: points[0])
    path.curve(to: points[1], controlPoint1: control1, controlPoint2: control2)
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Jalankan dengan path PNG keluaran.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let tile = NSBezierPath(roundedRect: NSRect(x: 34, y: 34, width: 956, height: 956),
                        xRadius: 212, yRadius: 212)
let shadow = NSShadow()
shadow.shadowColor = color(122, 83, 25).withAlphaComponent(0.18)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
color(255, 247, 221).setFill()
tile.fill()
NSShadow().set()
tile.lineWidth = 8
color(249, 225, 170).setStroke()
tile.stroke()

// A faceted database symbol recalls TablePlus's warm origami palette without
// reproducing its elephant mark.
ellipse(NSRect(x: 214, y: 290, width: 584, height: 214), fill: color(223, 101, 0))
polygon([NSPoint(x: 214, y: 398), NSPoint(x: 798, y: 398),
         NSPoint(x: 798, y: 717), NSPoint(x: 214, y: 717)], fill: color(255, 152, 0))
polygon([NSPoint(x: 214, y: 398), NSPoint(x: 425, y: 326),
         NSPoint(x: 425, y: 740), NSPoint(x: 214, y: 717)], fill: color(255, 178, 17))
polygon([NSPoint(x: 628, y: 340), NSPoint(x: 798, y: 398),
         NSPoint(x: 798, y: 717), NSPoint(x: 628, y: 740)], fill: color(239, 114, 0))
ellipse(NSRect(x: 214, y: 607, width: 584, height: 214), fill: color(255, 196, 35))
polygon([NSPoint(x: 234, y: 734), NSPoint(x: 494, y: 807),
         NSPoint(x: 425, y: 624)], fill: color(255, 218, 74))
polygon([NSPoint(x: 494, y: 807), NSPoint(x: 778, y: 734),
         NSPoint(x: 628, y: 624), NSPoint(x: 425, y: 624)], fill: color(255, 170, 0))

let dark = color(104, 65, 31)
strokeCurve([NSPoint(x: 313, y: 542), NSPoint(x: 694, y: 548)],
            control1: NSPoint(x: 404, y: 444), control2: NSPoint(x: 617, y: 446),
            color: dark, width: 48)
polygon([NSPoint(x: 689, y: 548), NSPoint(x: 622, y: 541),
         NSPoint(x: 668, y: 483)], fill: dark)
strokeCurve([NSPoint(x: 688, y: 398), NSPoint(x: 316, y: 389)],
            control1: NSPoint(x: 605, y: 302), control2: NSPoint(x: 394, y: 304),
            color: color(255, 240, 186), width: 45)
polygon([NSPoint(x: 317, y: 389), NSPoint(x: 385, y: 391),
         NSPoint(x: 337, y: 449)], fill: color(255, 240, 186))

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Gagal membuat PNG ikon.")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
