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

let size = 1024.0

// MARK: - Palette

/// Deep green through to a brighter mint. Money without resorting to a currency
/// symbol, which wouldn't survive being multi-currency anyway.
let gradientTop = CGColor(red: 0.27, green: 0.84, blue: 0.60, alpha: 1)
let gradientBottom = CGColor(red: 0.04, green: 0.35, blue: 0.29, alpha: 1)
let bubbleColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let markColor = CGColor(red: 0.05, green: 0.30, blue: 0.25, alpha: 1)

// MARK: - Context

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        // No alpha: the App Store and iOS both reject icons with transparency.
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
    colors: [gradientTop, gradientBottom] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )
}

// MARK: - Speech bubble

// The message the expense comes from. Drawn as one path — body and tail — so
// the fill has no seam where they meet.
let body = CGRect(x: 232, y: 400, width: 560, height: 440)
let bubble = CGMutablePath()
bubble.addRoundedRect(in: body, cornerWidth: 132, cornerHeight: 132)
// A broad base, so the tail reads as part of the bubble rather than a spike.
bubble.move(to: CGPoint(x: 356, y: 470))
bubble.addLine(to: CGPoint(x: 300, y: 250))
bubble.addLine(to: CGPoint(x: 548, y: 430))
bubble.closeSubpath()

context.setFillColor(bubbleColor)
context.addPath(bubble)
context.fillPath()

// MARK: - Checkmark

// "Logged" — the whole point of the app is that the message becomes a record.
context.setStrokeColor(markColor)
context.setLineWidth(84)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 400, y: 622))
context.addLine(to: CGPoint(x: 486, y: 532))
context.addLine(to: CGPoint(x: 644, y: 712))
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
