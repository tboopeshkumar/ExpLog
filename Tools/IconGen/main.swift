import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon to a 1024×1024 PNG:
//
//     ./Tools/make-icon.sh
//
// The icon is drawn in code rather than stored as a binary blob, so colours and
// proportions can be changed here and re-rendered. iOS requires a full square
// with no alpha and no rounded corners — the system applies its own mask.
//
// A log: three lines of decreasing length, with the newest ticked off in a
// badge. No currency symbol, since the parser is deliberately multi-currency.
// The coral is the app's accent colour too (Resources/Assets.xcassets/
// AccentColor.colorset and Shared/Brand.swift).

let size = 1024.0

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

let gradientStart = rgb(0xFF8A5B)
let gradientEnd = rgb(0xD9412B)
let paperColor = rgb(0xFFFFFF)
let markColor = rgb(0xD9412B)

// MARK: - Context

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        // No alpha: iOS and the App Store both reject icons with transparency.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("could not create a drawing context\n".utf8))
    exit(1)
}

context.setShouldAntialias(true)
context.interpolationQuality = .high

// MARK: - Background

if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [gradientStart, gradientEnd] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )
}
// A soft light from the top-left.
if let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1]
) {
    let centre = CGPoint(x: 260, y: 860)
    context.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 760, options: [])
}

// MARK: - Log lines and badge

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: rgb(0x000000, 0.22))
context.setFillColor(paperColor)
for (index, width) in [520.0, 400.0, 300.0].enumerated() {
    let line = CGRect(x: 200, y: 640 - Double(index) * 170, width: width, height: 104)
    context.addPath(CGPath(roundedRect: line, cornerWidth: 52, cornerHeight: 52, transform: nil))
}
context.fillPath()
context.addEllipse(in: CGRect(x: 600, y: 196, width: 268, height: 268))
context.fillPath()
context.restoreGState()

// MARK: - Checkmark

context.setStrokeColor(markColor)
context.setLineWidth(46)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 668, y: 336))
context.addLine(to: CGPoint(x: 718, y: 284))
context.addLine(to: CGPoint(x: 804, y: 384))
context.strokePath()

// MARK: - Write

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    FileHandle.standardError.write(Data("could not open \(outputPath) for writing\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write the PNG\n".utf8))
    exit(1)
}

print("Wrote \(Int(size))×\(Int(size)) icon to \(outputPath)")
