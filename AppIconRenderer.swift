//
//  AppIconRenderer.swift
//  MacAMRP
//
//  Renders the app icon programmatically: pink gradient rounded square with a white music note.
//  Everything is drawn in a CGContext at exact pixel sizes, screen-scale independent.
//

import AppKit

enum AppIconRenderer {
    static let cachedIcon: NSImage = render()

    /// Renders an icon at exactly `size` × `size` pixels.
    static func render(size: CGFloat = 1024) -> NSImage {
        let px = Int(size)
        let cornerRadius = size * 0.22

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil,
                width: px,
                height: px,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))

        // Build a grayscale mask: white = opaque, black = transparent.
        // White rounded rect on black background = rounded shape mask.
        guard
            let maskSpace = CGColorSpace(name: CGColorSpace.linearGray),
            let maskCtx = CGContext(
                data: nil,
                width: px,
                height: px,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: maskSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrderDefault.rawValue
            )
        else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        maskCtx.setFillColor(gray: 0, alpha: 1)
        maskCtx.fill(rect)
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                               cornerHeight: cornerRadius, transform: nil))
        maskCtx.fillPath()

        guard let maskImage = maskCtx.makeImage() else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        // Clip main context to the rounded shape before drawing anything.
        ctx.clip(to: rect, mask: maskImage)

        // Pink gradient background
        let gradColors = [CGColor(red: 0.98, green: 0.40, blue: 0.60, alpha: 1),
                          CGColor(red: 0.80, green: 0.15, blue: 0.35, alpha: 1)]
        if let grad = CGGradient(colorsSpace: colorSpace, colors: gradColors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: size * 0.2, y: size),
                                   end: CGPoint(x: size * 0.8, y: 0),
                                   options: [])
        }

        // Gloss overlay
        let glossColors = [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)]
        if let gloss = CGGradient(colorsSpace: colorSpace, colors: glossColors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gloss,
                                   start: CGPoint(x: size / 2, y: size),
                                   end: CGPoint(x: size / 2, y: size * 0.5),
                                   options: [])
        }

        // Draw white music note into a separate context then composite in
        let symbolFraction: CGFloat = 0.56
        let symPx = Int(size * symbolFraction)
        if let symCtx = CGContext(data: nil, width: symPx, height: symPx,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let nsCtx = NSGraphicsContext(cgContext: symCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            let symConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(symPx), weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

            if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(symConfig) {
                let s = symbol.size
                let o = NSPoint(x: (CGFloat(symPx) - s.width) / 2,
                                y: (CGFloat(symPx) - s.height) / 2)
                symbol.draw(in: NSRect(origin: o, size: s),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }

            NSGraphicsContext.restoreGraphicsState()

            if let symImage = symCtx.makeImage() {
                let offset = (size - CGFloat(symPx)) / 2
                ctx.draw(symImage, in: CGRect(x: offset, y: offset,
                                             width: CGFloat(symPx), height: CGFloat(symPx)))
            }
        }

        guard let cgImage = ctx.makeImage() else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        let result = NSImage(size: NSSize(width: size, height: size))
        result.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return result
    }

    /// Write all required AppIcon PNG sizes to the asset catalog on disk.
    static func writeIconAssets(to assetPath: String) {
        let sizes: [(String, Int)] = [
            ("icon_16x16.png",      16),
            ("icon_16x16@2x.png",   32),
            ("icon_32x32.png",      32),
            ("icon_32x32@2x.png",   64),
            ("icon_128x128.png",    128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png",    256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png",    512),
            ("icon_512x512@2x.png", 1024),
        ]

        for (filename, targetPixels) in sizes {
            let image = render(size: CGFloat(targetPixels))
            guard
                let rep = image.representations.first as? NSBitmapImageRep,
                let pngData = rep.representation(using: .png, properties: [:])
            else { continue }
            let url = URL(fileURLWithPath: assetPath).appendingPathComponent(filename)
            try? pngData.write(to: url)
        }
    }
}
