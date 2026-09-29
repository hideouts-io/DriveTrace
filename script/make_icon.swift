import AppKit
import Foundation

enum IconGenerationError: Error {
    case invalidArguments
    case unreadableSource(String)
    case bitmapAllocationFailed(Int)
    case pngEncodingFailed(Int)
}

guard CommandLine.arguments.count == 3 else { throw IconGenerationError.invalidArguments }
let sourcePath: String = CommandLine.arguments[1]
guard let source = NSImage(contentsOfFile: sourcePath) else { throw IconGenerationError.unreadableSource(sourcePath) }
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels: Int = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconGenerationError.bitmapAllocationFailed(pixels) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconGenerationError.pngEncodingFailed(pixels) }
        let name: String = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: destination.appendingPathComponent(name))
    }
}
