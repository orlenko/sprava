// Renders the app icon's images from the drawn sketches in Resources/AppIcon. Run through
// scripts/make-app-icon.sh, which turns them into AppIcon.icns and Assets.car.
//
// iconset: the light sketch is a cream tile on a white background. The tile is cut out with a continuous-corner
// rounded rectangle matched to the drawn one, its own rim and shadow left behind, and placed on the macOS icon
// grid: an 824-point tile centred on the 1024 canvas, with a soft shadow of its own. Smaller sizes are halved
// from the 1024 master one step at a time, so the 16 and 32 pixel images stay smooth.
// folder: the folder layer of the Icon Composer file, keyed out of the dark sketch.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The drawn tile in the sketch, in its pixels (top-left origin), measured from icon-light.png; the crop sits a
/// few pixels inside it so the tile's darker rim and the white background stay out.
let drawnTile = CGRect(x: 95, y: 96, width: 1062, height: 1060)
let rimInset: CGFloat = 4
/// The macOS icon grid: the tile and its corner on the 1024 canvas.
let canvas = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("make-app-icon: " + message + "\n").utf8))
    exit(1)
}

/// The continuous-curvature corner macOS uses for app icons, as a rounded rectangle path.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    enum Step { case line(CGFloat, CGFloat), curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) }
    // One corner, from the edge it leaves to the edge it joins, in units of the radius: (along the edge left,
    // along the edge joined), measured from the corner. The corner is symmetric, so mirroring it across the
    // diagonal walks it the other way round.
    let start: (CGFloat, CGFloat) = (1.52866, 0)
    let corner: [Step] = [
        .curve(0.66993, 0.06550, 1.08849, 0, 0.86841, 0),
        .line(0.63149, 0.07491),
        .curve(0.07491, 0.63149, 0.37282, 0.16906, 0.16906, 0.37282),
        .line(0.06550, 0.66993),
        .curve(0, 1.52866, 0, 0.86841, 0, 1.08849),
    ]
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866)
    let path = CGMutablePath()
    // Clockwise on screen (y grows upward): each corner's position, the directions into the rectangle, and
    // whether it is left along a vertical edge.
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
        (rect.maxX, rect.maxY, -1, -1, false),  // top right: from the top edge to the right edge
        (rect.maxX, rect.minY, -1, 1, true),    // bottom right: from the right edge to the bottom edge
        (rect.minX, rect.minY, 1, 1, false),    // bottom left: from the bottom edge to the left edge
        (rect.minX, rect.maxY, 1, -1, true),    // top left: from the left edge to the top edge
    ]
    for (index, (cx, cy, sx, sy, vertical)) in corners.enumerated() {
        func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            let (h, v) = vertical ? (b, a) : (a, b)
            return CGPoint(x: cx + sx * h * r, y: cy + sy * v * r)
        }
        if index == 0 { path.move(to: point(start.0, start.1)) } else { path.addLine(to: point(start.0, start.1)) }
        for step in corner {
            switch step {
            case let .line(a, b):
                path.addLine(to: point(a, b))
            case let .curve(a, b, c1a, c1b, c2a, c2b):
                path.addCurve(to: point(a, b), control1: point(c1a, c1b), control2: point(c2a, c2b))
            }
        }
    }
    path.closeSubpath()
    return path
}

func context(_ size: Int) -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create a \(size)-pixel bitmap") }
    ctx.interpolationQuality = .high
    return ctx
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fail("cannot write \(path)") }
}

func readSketch(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let sketch = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read \(path)") }
    guard sketch.width == 1254, sketch.height == 1254 else {
        fail("\(path) is \(sketch.width)x\(sketch.height); the tile was measured on a 1254x1254 sketch")
    }
    return sketch
}

/// The tile's face: the sketch inside the drawn tile, without its rim.
func face(_ sketch: CGImage) -> CGImage {
    guard let face = sketch.cropping(to: drawnTile.insetBy(dx: rimInset, dy: rimInset)) else { fail("cannot crop the tile") }
    return face
}

/// The legacy icon: the light tile cut out on the macOS grid, at every iconset size.
func iconset(sketch: String, output: String) {
    let master = context(canvas)
    let shape = continuousRoundedRect(tile, radius: cornerRadius)
    master.saveGState()
    master.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.28))
    master.addPath(shape)
    master.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.91, alpha: 1))
    master.fillPath()
    master.restoreGState()
    master.addPath(shape)
    master.clip()
    master.draw(face(readSketch(sketch)), in: tile)
    guard var image = master.makeImage() else { fail("cannot render the icon") }

    do {
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(output)")
    }
    // iconutil's names: icon_<points>x<points>[@2x].png for these point sizes.
    let points: Set<Int> = [16, 32, 128, 256, 512]
    var size = canvas
    while size >= 16 {
        if points.contains(size) { write(image, to: "\(output)/icon_\(size)x\(size).png") }
        if points.contains(size / 2) { write(image, to: "\(output)/icon_\(size / 2)x\(size / 2)@2x.png") }
        let half = context(size / 2)
        half.draw(image, in: CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
        guard let next = half.makeImage() else { fail("cannot scale the icon") }
        image = next
        size /= 2
    }
}

/// The folder alone, for the Icon Composer file: keyed out of the dark sketch, where the navy tile and the
/// folder's shadow are far darker than any part of the folder, on a transparent 1024 canvas that the system
/// fills (cream, navy, or tinted) and masks to the icon's shape. The folder sits where it sits on the light
/// tile's face, so both icons match.
func folder(sketch: String, output: String) {
    let dark = context(canvas)
    dark.draw(face(readSketch(sketch)), in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    guard let data = dark.data else { fail("cannot read the sketch's pixels") }
    let pixels = data.bindMemory(to: UInt8.self, capacity: dark.bytesPerRow * canvas)
    // The navy behind the folder, and the brightness between it and the folder's darkest edge where the key
    // goes from clear to solid.
    let navy: [Double] = [30, 34, 43]
    let clear = 60.0, solid = 100.0
    // The folder with a margin, in the canvas's pixels from the top left; outside it the tile's lit rim and the
    // white past its corners would key as solid.
    let folderArea = CGRect(x: 115, y: 170, width: 795, height: 680)
    for y in 0..<canvas {
        for x in 0..<canvas {
            let p = y * dark.bytesPerRow + x * 4
            let c = (0..<3).map { Double(pixels[p + $0]) }
            let luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
            let inside = folderArea.contains(CGPoint(x: x, y: y))
            let t = inside ? min(max((luma - clear) / (solid - clear), 0), 1) : 0
            let alpha = t * t * (3 - 2 * t)
            for i in 0..<3 {
                // Unmix the navy from the edge pixels, then store premultiplied.
                let colour = alpha > 0 ? min(max(navy[i] + (c[i] - navy[i]) / alpha, 0), 255) : 0
                pixels[p + i] = UInt8((colour * alpha).rounded())
            }
            pixels[p + 3] = UInt8((alpha * 255).rounded())
        }
    }
    guard let image = dark.makeImage() else { fail("cannot render the folder") }
    write(image, to: output)
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (4, "iconset"): iconset(sketch: args[2], output: args[3])
case (4, "folder"): folder(sketch: args[2], output: args[3])
default: fail("usage: make-app-icon.swift iconset <icon-light.png> <out.iconset> | folder <icon-dark.png> <out.png>")
}

