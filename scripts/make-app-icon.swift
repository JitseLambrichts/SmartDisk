// Builds the app icon and the sidebar logo from the transparent brand logo:
//   swift scripts/make-app-icon.swift [assets/branding/smartdisk-logo-v2-green.png]
// Writes macos/Resources/AppIcon.icns (logo on a light rounded tile, on Apple's
// 1024 grid) and macos/Resources/SmartDiskLogo.png (the bare logo, trimmed).

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("assets/branding/smartdisk-logo-v2-green.png")
let resources = root.appendingPathComponent("macos/Resources")
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

guard let image = NSImage(contentsOf: source),
      let logo = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(source.path)")
}

/// The part of the image that is not transparent, counted from the top left like `cropping(to:)`.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let alpha = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w where alpha[y * w + x] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func canvas(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

/// Draws the trimmed logo centered in `box`, as large as fits.
func drawLogo(in ctx: CGContext, box: CGRect) {
    let bounds = opaqueBounds(logo)
    let trimmed = logo.cropping(to: bounds)!
    let scale = min(box.width / bounds.width, box.height / bounds.height)
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    ctx.draw(trimmed, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                 width: size.width, height: size.height))
}

func write(_ ctx: CGContext, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Apple's macOS icon grid: an 824 pt tile with rounded corners, centered on 1024, with a soft shadow.
func appIcon() -> CGContext {
    let ctx = canvas(1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(.white)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.925, green: 0.965, blue: 0.945, alpha: 1), // pale mint
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    drawLogo(in: ctx, box: tile.insetBy(dx: 130, dy: 130))
    ctx.restoreGState()
    return ctx
}

// iconutil wants every size as its own PNG in an .iconset folder.
let master = appIcon().makeImage()!
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let ctx = canvas(pixels)
        ctx.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(ctx, to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

// Sidebar logo: shown at 44 pt, so 132 px covers 3x displays.
let sidebar = canvas(132)
drawLogo(in: sidebar, box: CGRect(x: 0, y: 0, width: 132, height: 132))
write(sidebar, to: resources.appendingPathComponent("SmartDiskLogo.png"))

print("Wrote \(resources.path)/AppIcon.icns and SmartDiskLogo.png")
