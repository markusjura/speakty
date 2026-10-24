import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generates Speakty's macOS app icon: white waveform bars, like the menu bar's `waveform` symbol, on
// the system-blue rounded square Shotty and Spotty use. Every size is drawn directly at its pixel
// dimensions, so small sizes stay crisp and the output is deterministic.
// Run: swift Scripts/GenerateAppIcon.swift Speakty/Assets.xcassets

let assets = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Speakty/Assets.xcassets", isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws on Apple's 1024-point icon grid, y pointing up.
func png(pixels: Int, draw: (CGContext, CGFloat) -> Void) throws -> Data {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    draw(context, scale)
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

func drawIcon(in context: CGContext, scale: CGFloat) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(CGColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.22, green: 0.6, blue: 1, alpha: 1),
        CGColor(srgbRed: 0, green: 0.42, blue: 0.93, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    context.restoreGState()

    // Seven rounded bars, tallest in the middle, filling the same 452-point square as Shotty's glyph.
    let heights: [CGFloat] = [120, 236, 360, 452, 300, 196, 104]
    let width: CGFloat = 44, gap: CGFloat = 24
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for (index, height) in heights.enumerated() {
        let bar = CGRect(x: 512 - total / 2 + CGFloat(index) * (width + gap), y: 512 - height / 2, width: width, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    }
    context.fillPath()
}

var images: [[String: String]] = []
let folder = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: size * scale, draw: drawIcon).write(to: folder.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) images to \(folder.path)")
