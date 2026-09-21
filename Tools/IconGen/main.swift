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
// A receipt with a check through it: the expense, and the fact that it's been
// logged. No currency symbol, since the parser is deliberately multi-currency.

let size = 1024.0

// MARK: - Palette

let gradientStart = CGColor(red: 0.09, green: 0.78, blue: 0.58, alpha: 1)
let gradientEnd = CGColor(red: 0.02, green: 0.28, blue: 0.24, alpha: 1)
let paperColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let markColor = CGColor(red: 0.04, green: 0.30, blue: 0.24, alpha: 1)

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

// MARK: - Receipt

let left = 300.0
let right = 724.0
let top = 796.0
let tearLine = 332.0      // where the straight body ends
let tearDepth = 54.0      // how far the teeth drop below it
let corner = 52.0
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

context.setFillColor(paperColor)
context.addPath(receipt)
context.fillPath()

// MARK: - Checkmark

context.setStrokeColor(markColor)
context.setLineWidth(92)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 398, y: 566))
context.addLine(to: CGPoint(x: 486, y: 474))
context.addLine(to: CGPoint(x: 648, y: 658))
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
