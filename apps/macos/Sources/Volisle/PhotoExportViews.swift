import SwiftUI
import PhotosUI
import Photos
import VolisleCore

struct PhotoExportPickerSheet: View {
    let complete: (Result<[String], any Error>?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择要导出的照片和视频").font(.title2.weight(.semibold))
            Text("导出未修改的原片。实况照片的图片和配套视频会一起保存；相册中的后期编辑不包含在原片中。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PhotoLibraryPicker(complete: complete).frame(minHeight: 380)
        }.padding(20).frame(width: 660, height: 520)
    }
}

private struct PhotoLibraryPicker: NSViewControllerRepresentable {
    let complete: (Result<[String], any Error>?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }
    func makeNSViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateNSViewController(_ nsViewController: PHPickerViewController, context: Context) { }
    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let complete: (Result<[String], any Error>?) -> Void
        private var finished = false
        init(complete: @escaping (Result<[String], any Error>?) -> Void) { self.complete = complete }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }; finished = true
            guard !results.isEmpty else { complete(nil); return }
            let ids = results.compactMap(\.assetIdentifier)
            guard ids.count == results.count, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
                complete(.failure(PhotoExportError.invalidSelection)); return
            }
            complete(.success(ids))
        }
    }
}

struct PhotoExportPreparationView: View {
    let assetCount: Int
    let completedResources: Int
    let resourceCount: Int
    let fraction: Double
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正在准备 \(assetCount) 个项目的原片").font(.headline)
                Spacer()
                Button("取消准备", action: cancel).controlSize(.small)
            }
            ProgressView(value: fraction).accessibilityLabel("原片准备进度")
            Text("已取得 \(completedResources) / \(resourceCount) 份原片资源")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text("iCloud 中的原片会先下载到 Mac。原片暂存需要可用空间，磁盘写入确认完成后会自动清理。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
