@preconcurrency import AVFoundation
import SkimCore

/// 用 AVFoundation 读出播放需要的信息。
///
/// AVAsset 只在这个 nonisolated 函数里创建和使用，不跨 actor 传递；
/// 返回的是只含值类型的 Sendable 结构。
struct AssetInspection: Sendable {
    var isPlayable: Bool
    var hasVideo: Bool
    var duration: Double
    var frameRate: Double
    /// 一帧的时长（来自 minFrameDuration，没有时按帧率推算）。
    var frameDuration: RationalTime
    /// 已经应用旋转后的显示尺寸。
    var displaySize: CGSize

    var frameGrid: FrameGrid { FrameGrid(frameDuration: frameDuration) }

    /// 宽高比；没有尺寸时按 16:9。
    var aspectRatio: Double {
        guard displaySize.width > 0, displaySize.height > 0 else { return 16.0 / 9.0 }
        return Double(displaySize.width / displaySize.height)
    }
}

enum AssetInspector {
    static func inspect(_ url: URL) async -> AssetInspection {
        let asset = AVURLAsset(url: url)
        var result = AssetInspection(
            isPlayable: false, hasVideo: false, duration: 0, frameRate: 30,
            frameDuration: RationalTime(value: 1, timescale: 30), displaySize: .zero)
        result.isPlayable = (try? await asset.load(.isPlayable)) ?? false
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            result.duration = duration.seconds
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return result }
        result.hasVideo = true
        if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            result.frameRate = Double(fps)
        }
        result.frameDuration = FrameGrid(framesPerSecond: result.frameRate).frameDuration
        if let minFrame = try? await track.load(.minFrameDuration), minFrame.isNumeric, minFrame.value > 0,
           minFrame.timescale > 0 {
            // 只在和帧率一致时采用（可变帧率的视频 minFrameDuration 会偏小）。
            let fromMin = Double(minFrame.value) / Double(minFrame.timescale)
            if abs(1 / fromMin - result.frameRate) < 0.5 {
                result.frameDuration = RationalTime(value: minFrame.value, timescale: minFrame.timescale)
            }
        }
        if let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            result.displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
        }
        return result
    }
}

/// 把不是 Sendable 的值（例如 CGImage）交给主线程时用。调用方保证不会同时访问。
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
