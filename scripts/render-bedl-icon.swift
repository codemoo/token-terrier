import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("usage: render-bedl-icon.swift <input-png> <output-png>\n", stderr)
    exit(2)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let size = 1024

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: outputPath)

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fputs("could not load input image: \(inputPath)\n", stderr)
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    fputs("could not allocate bitmap\n", stderr)
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius = CGFloat(size) * 0.22
context.clear(rect)
context.interpolationQuality = .high
context.addPath(CGPath(
    roundedRect: rect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil))
context.clip()
context.draw(image, in: rect)

guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil)
else {
    fputs("could not create png destination\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not encode png\n", stderr)
    exit(1)
}
