import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift script/create_app_icon.swift <input.png> <output.png>\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let iconSize = 1024
let tileInset: Double = 58
let cornerRadius: Double = 102
let edgeFeather: Double = 2.0

guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    FileHandle.standardError.write(Data("failed to load image: \(inputURL.path)\n".utf8))
    exit(1)
}

let bytesPerRow = iconSize * 4
var bitmap = [UInt8](repeating: 0, count: bytesPerRow * iconSize)
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: &bitmap,
    width: iconSize,
    height: iconSize,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("failed to create bitmap context\n".utf8))
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: iconSize, height: iconSize))

func roundedRectSignedDistance(x: Double, y: Double, rect: CGRect, radius: Double) -> Double {
    let centerX = rect.midX
    let centerY = rect.midY
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let qx = abs(x - centerX) - (halfWidth - radius)
    let qy = abs(y - centerY) - (halfHeight - radius)
    let outsideX = max(qx, 0)
    let outsideY = max(qy, 0)
    let outsideDistance = sqrt(outsideX * outsideX + outsideY * outsideY)
    let insideDistance = min(max(qx, qy), 0)
    return outsideDistance + insideDistance - radius
}

func alphaMultiplier(for distance: Double) -> Double {
    if distance <= -edgeFeather { return 1.0 }
    if distance >= edgeFeather { return 0.0 }
    return (edgeFeather - distance) / (edgeFeather * 2)
}

let rect = CGRect(
    x: tileInset,
    y: tileInset,
    width: Double(iconSize) - tileInset * 2,
    height: Double(iconSize) - tileInset * 2
)

for y in 0..<iconSize {
    for x in 0..<iconSize {
        let distance = roundedRectSignedDistance(
            x: Double(x) + 0.5,
            y: Double(y) + 0.5,
            rect: rect,
            radius: cornerRadius
        )
        let multiplier = alphaMultiplier(for: distance)
        let offset = y * bytesPerRow + x * 4
        bitmap[offset + 0] = UInt8(Double(bitmap[offset + 0]) * multiplier)
        bitmap[offset + 1] = UInt8(Double(bitmap[offset + 1]) * multiplier)
        bitmap[offset + 2] = UInt8(Double(bitmap[offset + 2]) * multiplier)
        bitmap[offset + 3] = UInt8(Double(bitmap[offset + 3]) * multiplier)
    }
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let outputImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    FileHandle.standardError.write(Data("failed to encode png\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("failed to write png: \(outputURL.path)\n".utf8))
    exit(1)
}
