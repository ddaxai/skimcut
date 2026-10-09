import AppKit
import SkimCore
import SwiftUI

/// 时间轴：缩略图条 + 刻度 + 选区（白框和两端手柄）+ 播放头（黄色）+ skimmer（红色）。
///
/// - 鼠标悬停移动：skimming（不需要点击）；
/// - 点击 / 拖动：移动播放头；拖动选区两端的手柄：改变起点 / 终点；
/// - 触控板捏合、⌘+ / ⌘-：缩放；横向滑动或滚轮：滚动。
/// 用 AppKit 的 NSTrackingArea 追踪鼠标，只在鼠标移动时产生事件，空闲时没有任何开销。
final class TimelineNSView: KeyHandlingView {
    private var trackingArea: NSTrackingArea?
    /// 正在拖动的手柄。
    private var draggingHandle: SelectionHandle?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(_ newController: PlayerController?) {
        guard newController !== controller else { return }
        controller?.redrawTimeline = nil
        controller?.thumbnails.onUpdate = nil
        controller = newController
        newController?.redrawTimeline = { [weak self] in self?.needsDisplay = true }
        newController?.thumbnails.onUpdate = { [weak self] in self?.needsDisplay = true }
        newController?.resizeTimeline(width: bounds.width)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.resizeTimeline(width: newSize.width)
    }

    // MARK: - 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func localX(_ event: NSEvent) -> Double {
        Double(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerMoved(x: localX(event), timestamp: event.timestamp)
    }

    override func mouseMoved(with event: NSEvent) {
        let x = localX(event)
        updateCursor(x: x)
        controller?.pointerMoved(x: x, timestamp: event.timestamp)
    }

    override func mouseExited(with event: NSEvent) {
        if draggingHandle == nil { NSCursor.arrow.set() }
        controller?.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let x = localX(event)
        if let handle = handleHit(x: x), let controller {
            draggingHandle = handle
            controller.beginHandleDrag()
            controller.dragHandle(handle, x: x)
            return
        }
        controller?.clicked(x: x)
    }

    override func mouseDragged(with event: NSEvent) {
        let x = localX(event)
        if let handle = draggingHandle {
            controller?.dragHandle(handle, x: x)
        } else {
            controller?.clicked(x: x)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard draggingHandle != nil else { return }
        draggingHandle = nil
        controller?.endHandleDrag()
        updateCursor(x: localX(event))
    }

    /// 鼠标是否在选区两端的手柄上。
    private func handleHit(x: Double) -> SelectionHandle? {
        guard let controller else { return nil }
        let geometry = controller.timeline
        return SelectionHandle.hitTest(
            x: x,
            startX: geometry.x(for: controller.selection.start),
            endX: geometry.x(for: controller.selection.end),
            tolerance: Double(TimelineMetrics.handleWidth) + 2)
    }

    private func updateCursor(x: Double) {
        if handleHit(x: x) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func magnify(with event: NSEvent) {
        guard let controller else { return }
        let x = localX(event)
        controller.zoom(by: 1 + Double(event.magnification), anchorX: x)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return super.scrollWheel(with: event) }
        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard delta != 0 else { return }
        controller.scrollTimeline(byPixels: -delta)
        // 内容在鼠标下面移动了：skimmer 跟着更新。
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            controller.pointerMoved(x: Double(point.x), timestamp: event.timestamp)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        bounds.fill()
        guard let controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geometry = controller.timeline
        let strip = NSRect(
            x: 0, y: TimelineMetrics.padding,
            width: bounds.width, height: TimelineMetrics.thumbnailHeight)
        let rulerBottom = strip.maxY

        drawThumbnails(controller, geometry: geometry, strip: strip, ctx: ctx)
        drawRuler(geometry, bottom: rulerBottom)

        // 视频开头之前、结尾之后的区域（两端的空白）。
        let startX = CGFloat(geometry.x(for: 0))
        let endX = CGFloat(geometry.x(for: controller.duration))
        NSColor(white: 0.06, alpha: 1).setFill()
        if startX > 0 {
            NSRect(x: 0, y: 0, width: startX, height: bounds.height).fill()
        }
        if endX < bounds.width {
            NSRect(x: endX, y: 0, width: bounds.width - endX, height: bounds.height).fill()
        }

        drawSelection(controller, geometry: geometry, strip: strip)

        // 播放头：黄色，顶部带一个小三角。
        let playheadX = CGFloat(geometry.x(for: controller.playhead)).rounded(.down) + 0.5
        if playheadX >= -2, playheadX <= bounds.width + 2 {
            NSColor.systemYellow.setFill()
            NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height).fill()
            let top = bounds.height
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: playheadX - 6, y: top))
            triangle.line(to: NSPoint(x: playheadX + 6, y: top))
            triangle.line(to: NSPoint(x: playheadX, y: top - 8))
            triangle.close()
            triangle.fill()
        }

        // skimmer：红色细线。
        if let skimmer = controller.skimmerTime {
            let x = CGFloat(geometry.x(for: skimmer)).rounded(.down) + 0.5
            NSColor.systemRed.setFill()
            NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    private func drawThumbnails(_ controller: PlayerController, geometry: TimelineGeometry, strip: NSRect, ctx: CGContext) {
        let thumbnails = controller.thumbnails
        let thumbWidth = thumbnails.thumbnailWidth
        guard thumbWidth > 0 else { return }
        let level = ThumbnailLadder.level(
            pixelsPerSecond: geometry.pixelsPerSecond,
            thumbnailWidth: Double(thumbWidth),
            minimumInterval: controller.frameGrid.secondsPerFrame)
        let slots = ThumbnailLadder.slots(level: level, visible: geometry.visibleRange, duration: controller.duration)
        let endX = CGFloat(geometry.x(for: controller.duration))

        ctx.saveGState()
        ctx.clip(to: strip)
        ctx.interpolationQuality = .medium
        for slot in slots {
            let x0 = CGFloat(geometry.x(for: slot.startTime))
            let x1 = min(CGFloat(geometry.x(for: slot.startTime + slot.interval)), endX)
            guard x1 > x0 else { continue }
            let slotRect = CGRect(x: x0, y: strip.minY, width: x1 - x0, height: strip.height)
            if let image = thumbnails.image(for: slot.key) {
                ctx.saveGState()
                ctx.clip(to: slotRect)
                // 格子比缩略图宽时重复画同一帧（Final Cut Pro 的胶片条也是这样）。
                var x = x0
                while x < x1 {
                    ctx.draw(image, in: CGRect(x: x, y: strip.minY, width: thumbWidth, height: strip.height))
                    x += thumbWidth
                }
                ctx.restoreGState()
            } else {
                NSColor(white: 0.18, alpha: 1).setFill()
                slotRect.fill()
            }
            // 格子之间的细分隔线。
            NSColor(white: 0, alpha: 0.35).setFill()
            NSRect(x: x0, y: strip.minY, width: 1, height: strip.height).fill()
        }
        ctx.restoreGState()
        thumbnails.request(slots)
    }

    /// 选区：区间外的缩略图变暗，区间加白框，两端是可以拖动的手柄。
    private func drawSelection(_ controller: PlayerController, geometry: TimelineGeometry, strip: NSRect) {
        let selection = controller.selection
        let videoStart = CGFloat(geometry.x(for: 0))
        let videoEnd = CGFloat(geometry.x(for: controller.duration))
        let sx = CGFloat(geometry.x(for: selection.start))
        let ex = CGFloat(geometry.x(for: selection.end))

        NSColor(white: 0, alpha: 0.6).setFill()
        if sx > videoStart {
            NSRect(x: videoStart, y: strip.minY, width: sx - videoStart, height: strip.height).fill()
        }
        if ex < videoEnd {
            NSRect(x: ex, y: strip.minY, width: videoEnd - ex, height: strip.height).fill()
        }

        let color = NSColor.white
        color.setFill()
        // 上下边框。
        NSRect(x: sx, y: strip.maxY - 2, width: ex - sx, height: 2).fill()
        NSRect(x: sx, y: strip.minY, width: ex - sx, height: 2).fill()

        // 两端手柄：起点手柄在起点左边，终点手柄在终点右边。
        let w = TimelineMetrics.handleWidth
        for x in [sx - w, ex] {
            let rect = NSRect(x: x, y: strip.minY, width: w, height: strip.height)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            // 手柄上的握把线。
            NSColor(white: 0.3, alpha: 1).setFill()
            NSRect(x: rect.midX - 0.5, y: rect.midY - 8, width: 1, height: 16).fill()
        }
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor(white: 0.75, alpha: 1),
    ]

    private func drawRuler(_ geometry: TimelineGeometry, bottom: CGFloat) {
        let interval = TimelineTicks.interval(pixelsPerSecond: geometry.pixelsPerSecond, minimumPixels: 80)
        let visible = geometry.visibleRange
        var t = (visible.lowerBound / interval).rounded(.down) * interval
        NSColor(white: 0.5, alpha: 1).setFill()
        while t <= visible.upperBound + interval {
            let x = CGFloat(geometry.x(for: t)).rounded(.down) + 0.5
            if x >= -60, x <= bounds.width {
                NSRect(x: x - 0.5, y: bottom, width: 1, height: 6).fill()
                let label = TimelineTicks.label(t, interval: interval) as NSString
                label.draw(at: NSPoint(x: x + 3, y: bottom + 3), withAttributes: Self.labelAttributes)
            }
            t += interval
        }
    }
}

struct TimelineStrip: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView(frame: .zero)
        view.attach(controller)
        return view
    }

    func updateNSView(_ nsView: TimelineNSView, context: Context) {
        nsView.attach(controller)
    }

    static func dismantleNSView(_ nsView: TimelineNSView, coordinator: ()) {
        nsView.attach(nil)
    }
}
