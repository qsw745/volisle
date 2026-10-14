// SPDX-License-Identifier: GPL-2.0-only
// Composes one Mac App Store screenshot (2880 × 1800): a headline and a line of
// text over the brand background, with a window capture of the app.
//   swiftc -parse-as-library scripts/store/compose-screenshot.swift -o <tool>
//   <tool> <window.png> <out.png> <headline> <subline> [side]
// "side" puts the text on the left and the window on the right (for a tall window).
import AppKit
import SwiftUI

private let canvas = CGSize(width: 2880, height: 1800)
private let brand = Color(red: 0x17 / 255, green: 0x69 / 255, blue: 0xE0 / 255)
private let ink = Color(red: 0x10 / 255, green: 0x1D / 255, blue: 0x38 / 255)
private let muted = Color(red: 0x4A / 255, green: 0x5A / 255, blue: 0x78 / 255)

struct Shot: View {
    let window: NSImage
    let headline: String
    let subline: String
    let side: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.96, green: 0.975, blue: 1.0), Color(red: 0.86, green: 0.91, blue: 0.985)],
                           startPoint: .top, endPoint: .bottom)
            if side {
                HStack(spacing: 120) {
                    words(alignment: .leading).frame(width: 1180, alignment: .leading)
                    picture(maxWidth: 1200, maxHeight: 1620)
                }
            } else {
                VStack(spacing: 56) {
                    words(alignment: .center).padding(.top, 96)
                    picture(maxWidth: 2600, maxHeight: 1420)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    private func words(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 28) {
            Capsule().fill(brand).frame(width: 96, height: 12)
            Text(headline).font(.system(size: 104, weight: .bold)).foregroundStyle(ink)
            Text(subline).font(.system(size: 50, weight: .regular)).foregroundStyle(muted)
                .lineSpacing(10).fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private func picture(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        Image(nsImage: window).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

@main struct Compose {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 5, let window = NSImage(contentsOfFile: args[1]) else {
            FileHandle.standardError.write(Data("用法：<窗口截图.png> <输出.png> <标题> <说明> [side]\n".utf8)); exit(1)
        }
        let renderer = ImageRenderer(content: Shot(window: window, headline: args[3], subline: args[4], side: args.count > 5 && args[5] == "side"))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(canvas)
        guard let image = renderer.cgImage else { FileHandle.standardError.write(Data("渲染失败\n".utf8)); exit(1) }
        // Opaque RGB: App Store Connect refuses screenshots with an alpha channel.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { FileHandle.standardError.write(Data("写文件失败\n".utf8)); exit(1) }
        print("\(args[2])：\(image.width) × \(image.height)")
    }
}
