#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func pngData(from image: NSImage, pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("bitmap failed\n", stderr)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr)
        exit(1)
    }
    return data
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    try! pngData(from: image, pixels: pixels).write(to: url)
}

// メニューバーと同じ checkmark.shield を、Finder 用にオレンジの角丸へ置く
let orange = NSColor(srgbRed: 0.886, green: 0.290, blue: 0.071, alpha: 1)
let cream = NSColor(srgbRed: 0.953, green: 0.902, blue: 0.816, alpha: 1)
let navy = NSColor(srgbRed: 0.102, green: 0.153, blue: 0.267, alpha: 1)
let config = NSImage.SymbolConfiguration(pointSize: 640, weight: .bold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [cream, navy]))
guard let symbol = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else {
    fputs("SF Symbol checkmark.shield.fill missing\n", stderr)
    exit(1)
}

let appIcon = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
    let clip = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.223, yRadius: rect.width * 0.223)
    clip.addClip()
    orange.setFill()
    NSBezierPath(rect: rect).fill()
    let size = symbol.size
    let dest = NSRect(
        x: (rect.width - size.width) / 2,
        y: (rect.height - size.height) / 2 - rect.height * 0.02,
        width: size.width,
        height: size.height
    )
    symbol.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
    return true
}
writePNG(appIcon, pixels: 1024, to: assets.appendingPathComponent("AppIcon-1024.png"))
print("app icon rasterized")
