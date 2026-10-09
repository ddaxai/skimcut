@preconcurrency import AVFoundation
import AppKit
import SkimCore

/// 时间轴缩略图：只生成看得见的格子，结果放进有上限的 LRU 缓存。
///
/// - 可见范围变化时取消还没生成的请求；
/// - 不用计时器：只有时间轴请求时才工作；
/// - 关闭视频时 `close()` 释放生成器和缓存。
@MainActor
final class ThumbnailProvider {
    /// 缩略图条的显示高度（点）。
    let thumbnailHeight: CGFloat
    /// 按视频宽高比算出的缩略图宽度（点）。
    let thumbnailWidth: CGFloat
    /// 有新图时调用（时间轴重画）。
    var onUpdate: (() -> Void)?

    private var generator: AVAssetImageGenerator?
    private var cache = LRUCache<ThumbnailKey, CGImage>(countLimit: 600, costLimit: 48 * 1024 * 1024)
    /// 正在生成的批次：请求时间（90000 时间基的 value）→ 格子。
    private var inFlight: [Int64: ThumbnailKey] = [:]
    private var batch = 0
    private var failed: Set<ThumbnailKey> = []

    private static let timescale: CMTimeScale = 90000

    init(url: URL, aspectRatio: Double, thumbnailHeight: CGFloat, backingScale: CGFloat) {
        self.thumbnailHeight = thumbnailHeight
        self.thumbnailWidth = (thumbnailHeight * CGFloat(aspectRatio)).rounded()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: thumbnailHeight * max(backingScale, 1))
        self.generator = generator
    }

    /// 读取缓存里的图（标记为最近使用）。
    func image(for key: ThumbnailKey) -> CGImage? {
        cache.value(for: key)
    }

    /// 时间轴画完一帧后告诉这里需要哪些格子；缺的会排队生成，旧的、看不见的请求会被取消。
    func request(_ slots: [ThumbnailSlot]) {
        guard let generator else { return }
        let missing = slots.filter { !cache.contains($0.key) && !failed.contains($0.key) }
        let wanted = Set(missing.map(\.key))
        let pending = Set(inFlight.values)
        // 正在生成的正好是需要的（或者是它的超集），不用动。
        if wanted.isSubset(of: pending) { return }

        if !inFlight.isEmpty {
            generator.cancelAllCGImageGeneration()
            inFlight.removeAll()
        }
        guard !missing.isEmpty else { return }

        batch += 1
        let currentBatch = batch
        // 容差：格子间隔的一半，最多 2 秒。解码器可以就近取关键帧，生成快很多。
        let tolerance = CMTime(seconds: min((missing.first?.interval ?? 1) / 2, 2), preferredTimescale: Self.timescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var times: [NSValue] = []
        for slot in missing {
            let value = Int64((slot.requestTime * Double(Self.timescale)).rounded())
            inFlight[value] = slot.key
            times.append(NSValue(time: CMTime(value: value, timescale: Self.timescale)))
        }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, result, _ in
            let box = UncheckedSendable(value: image)
            let value = requested.value
            let succeeded = result == .succeeded
            let cancelled = result == .cancelled
            Task { @MainActor [weak self] in
                self?.received(value: value, image: box.value, succeeded: succeeded, cancelled: cancelled, batch: currentBatch)
            }
        }
    }

    private func received(value: Int64, image: CGImage?, succeeded: Bool, cancelled: Bool, batch: Int) {
        guard batch == self.batch, let key = inFlight.removeValue(forKey: value) else { return }
        if succeeded, let image {
            cache.insert(image, for: key, cost: image.bytesPerRow * image.height)
            onUpdate?()
        } else if !cancelled {
            failed.insert(key)
        }
    }

    /// 释放生成器和缓存。
    func close() {
        generator?.cancelAllCGImageGeneration()
        generator = nil
        inFlight.removeAll()
        cache.removeAll()
        failed.removeAll()
        onUpdate = nil
    }
}
