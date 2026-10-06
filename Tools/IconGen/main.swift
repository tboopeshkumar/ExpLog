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
// A receipt with a tick, in front of the message it came from: a bank text
// in, a logged expense out. No currency symbol, since the parser is
// deliberately multi-currency. The teal is the app's accent colour too
// (Resources/Assets.xcassets/AccentColor.colorset and Shared/Brand.swift).

let size = 1024.0

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

let gradientStart = rgb(0x2DD4BF)
let gradientEnd = rgb(0x0B6E7A)
let paperColor = rgb(0xFFFFFF)
let bubbleColor = rgb(0xFFFFFF, 0.34)
let markColor = rgb(0x0B7285)

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

// MARK: - Message bubble, behind

let bubbleRect = CGRect(x: 150, y: 430, width: 500, height: 400)
let bubble = CGMutablePath()
bubble.addRoundedRect(in: bubbleRect, cornerWidth: 120, cornerHeight: 120)
// The tail, bottom-left.
bubble.move(to: CGPoint(x: bubbleRect.minX + 96, y: bubbleRect.minY + 40))
bubble.addQuadCurve(
    to: CGPoint(x: bubbleRect.minX + 28, y: bubbleRect.minY - 118),
    control: CGPoint(x: bubbleRect.minX + 96, y: bubbleRect.minY - 60)
)
bubble.addQuadCurve(
    to: CGPoint(x: bubbleRect.minX + 300, y: bubbleRect.minY + 4),
    control: CGPoint(x: bubbleRect.minX + 170, y: bubbleRect.minY - 96)
)
bubble.closeSubpath()

context.setFillColor(bubbleColor)
context.addPath(bubble)
context.fillPath()

// MARK: - Receipt, in front

let left = 392.0
let right = 800.0
let top = 720.0
let tearLine = 262.0      // where the straight body ends
let tearDepth = 50.0      // how far the teeth drop below it
let corner = 50.0
let teeth = 6

let receipt = CGMutablePath()
receipt.move(to: CGPoint(x: left, y: tearLine))
receipt.addLine(to: CGPoint(x: left, y: top - corner))
receipt.addArc(
    tangent1End: CGPoint(x: left, y: top),
    tangent2End: CGPoint(x: left + corner, y: top),
    radius: corner
)
receipt.addLine(to: CGPoint(x: right - corner, y: top))
receipt.addArc(
    tangent1End: CGPoint(x: right, y: top),
    tangent2End: CGPoint(x: right, y: top - corner),
    radius: corner
)
receipt.addLine(to: CGPoint(x: right, y: tearLine))

// Torn bottom edge, walked right to left: down to a point, back up, repeat.
let toothWidth = (right - left) / Double(teeth)
for index in 0..<teeth {
    let start = right - Double(index) * toothWidth
    receipt.addLine(to: CGPoint(x: start - toothWidth / 2, y: tearLine - tearDepth))
    receipt.addLine(to: CGPoint(x: start - toothWidth, y: tearLine))
}
receipt.closeSubpath()

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: rgb(0x000000, 0.22))
context.setFillColor(paperColor)
context.addPath(receipt)
context.fillPath()
context.restoreGState()

// MARK: - Checkmark

context.setStrokeColor(markColor)
context.setLineWidth(78)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 492, y: 492))
context.addLine(to: CGPoint(x: 572, y: 410))
context.addLine(to: CGPoint(x: 712, y: 572))
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
