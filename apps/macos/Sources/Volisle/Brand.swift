import AppKit
import SwiftUI

enum Brand {
    static let markImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "BrandMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("缺少盘屿品牌图片资源")
        }
        image.isTemplate = false
        return image
    }()
    // 从 SwiftPM 资源包明确加载，避免主应用包与资源包查找位置不同。
    static let menuBarImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuBarTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("缺少盘屿菜单栏品牌资源")
        }
        if let retinaURL = Bundle.module.url(forResource: "MenuBarTemplate@2x", withExtension: "png"),
           let data = try? Data(contentsOf: retinaURL),
           let retina = NSBitmapImageRep(data: data) {
            retina.size = NSSize(width: 28, height: 17)
            image.addRepresentation(retina)
        }
        image.size = NSSize(width: 28, height: 17)
        image.isTemplate = true
        return image
    }()
}

struct BrandMark: View {
    var width: CGFloat = 32
    var body: some View {
        Image(nsImage: Brand.markImage)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: width, height: width * 460 / 760)
            .accessibilityHidden(true)
    }
}
