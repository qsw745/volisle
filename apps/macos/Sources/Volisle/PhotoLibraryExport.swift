import Foundation
import Observation
@preconcurrency import Photos
import VolisleCore

enum PhotoLibraryExportError: Error, LocalizedError {
    case permission
    var errorDescription: String? {
        String(localized: "导出原片需要照片访问权限。请在“系统设置 → 隐私与安全性 → 照片”中允许盘屿访问，然后重试。")
    }
}

/// Only invoked by the user's export action. The picker supplies identifiers;
/// resources are fetched for exactly those identifiers, never a library scan.
@MainActor @Observable final class PhotoLibraryExport {
    let cache = PhotoExportCache.shared
    var showingPicker = false
    private(set) var preparing = false
    private(set) var assetCount = 0
    private(set) var completedResources = 0
    private(set) var resourceCount = 0
    private(set) var fraction = 0.0
    @ObservationIgnored private var selection: CheckedContinuation<[String]?, any Error>?
    @ObservationIgnored private var resources: [String: PHAssetResource] = [:]
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var sleepGuard = CopySleepGuard()

    func choose() async throws -> [String]? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        try Task.checkCancellation()
        guard status == .authorized || status == .limited else { throw PhotoLibraryExportError.permission }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                selection = continuation
                showingPicker = true
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishSelection(nil) }
        }
    }

    func finishSelection(_ result: Result<[String], any Error>?) {
        guard let continuation = selection else { return }
        selection = nil
        showingPicker = false
        if let result { continuation.resume(with: result.map(Optional.some)) }
        else { continuation.resume(returning: nil) }
    }

    func prepare(_ identifiers: [String]) async throws -> PhotoExportBatch {
        guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }), Set(identifiers).count == identifiers.count else { throw PhotoExportError.invalidSelection }
        try Task.checkCancellation()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
        guard assets.count == identifiers.count, identifiers.allSatisfy({ assets[$0] != nil }) else { throw PhotoExportError.invalidSelection }
        resources = [:]
        var descriptors: [PhotoExportAsset] = []
        for identifier in identifiers {
            let asset = assets[identifier]!
            let originals = PHAssetResource.assetResources(for: asset)
            let chosen: [PHAssetResource]
            let kind: PhotoExportAsset.Kind
            if asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive) {
                guard let photo = originals.first(where: { $0.type == .photo }),
                      let motion = originals.first(where: { $0.type == .pairedVideo }) else { throw PhotoExportError.missingOriginalResources }
                chosen = [photo, motion]; kind = .livePhoto
            } else if asset.mediaType == .image {
                chosen = originals.filter { $0.type == .photo || $0.type == .alternatePhoto }; kind = .photo
            } else if asset.mediaType == .video {
                chosen = Array(originals.filter { $0.type == .video }.prefix(1)); kind = .video
            } else { throw PhotoExportError.invalidSelection }
            guard !chosen.isEmpty else { throw PhotoExportError.missingOriginalResources }
            let values = chosen.enumerated().map { index, original in
                let id = identifier + ":" + String(index)
                resources[id] = original
                let role: PhotoExportResource.Role = original.type == .pairedVideo ? .pairedVideo : original.type == .video ? .video : .photo
                return PhotoExportResource(id: id, filename: original.originalFilename, role: role)
            }
            descriptors.append(.init(id: identifier, kind: kind, resources: values))
        }
        let token = UUID()
        preparationID = token
        preparing = true; assetCount = descriptors.count; completedResources = 0
        resourceCount = descriptors.flatMap(\.resources).count; fraction = 0
        sleepGuard.update(copying: true)
        defer {
            preparationID = nil; preparing = false; resources = [:]
            sleepGuard.update(copying: false)
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let folder = String(localized: "相册导出") + " " + formatter.string(from: Date()) + " " + token.uuidString.prefix(8)
        return try await cache.prepare(assets: descriptors, folderName: folder, writer: { [self] resource, url, progress in
            try await write(resource.id, to: url, progress: progress)
        }, progress: { [weak self] progress in
            Task { @MainActor in
                guard let self, self.preparationID == token else { return }
                self.completedResources = max(self.completedResources, progress.finishedResources)
                self.fraction = max(self.fraction, progress.fraction)
            }
        })
    }

    private func write(_ id: String, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let resource = resources[id] else { throw PhotoExportError.invalidSelection }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress
        let request = try PhotoResourceTransfer(destination: url, cancelRequest: { PHAssetResourceManager.default().cancelDataRequest($0) })
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.begin(continuation) else { return }
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: request.dataReceivedHandler, completionHandler: request.completionHandler)
                request.register(id)
            }
        } onCancel: { request.cancel() }
    }
}
