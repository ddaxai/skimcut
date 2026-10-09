@preconcurrency import AVFoundation
import AppKit
import SkimCore
import SwiftUI

/// 接收播放快捷键的 NSView 基类：播放画面和时间轴都继承它，
/// 点击后成为第一响应者，空格、J/K/L、方向键直接送到这里。
/// 文本框有焦点时按键先给文本框，不会被拦截。
class KeyHandlingView: NSView {
    weak var controller: PlayerController?

    override var acceptsFirstResponder: Bool { controller != nil }

    override func keyDown(with event: NSEvent) {
        if let controller, let command = Self.command(for: event), !isZoom(command) {
            controller.perform(command)
        } else {
            super.keyDown(with: event)
        }
    }

    /// ⌘+ / ⌘= / ⌘- 走按键等价（菜单之前），这样 ⌘= 也能放大。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller, window?.isKeyWindow == true, let command = Self.command(for: event), isZoom(command) {
            controller.perform(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isZoom(_ command: PlaybackCommand) -> Bool {
        command == .zoomIn || command == .zoomOut
    }

    static func command(for event: NSEvent) -> PlaybackCommand? {
        let flags = event.modifierFlags
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return PlaybackKeyMap.command(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: modifiers)
    }

    /// 视频打开后让播放画面接收键盘。
    func becomeKeyTarget() {
        guard let window, window.firstResponder !== self else { return }
        // 文本框正在编辑时不抢焦点。
        if window.firstResponder is NSText { return }
        window.makeFirstResponder(self)
    }
}

/// 播放画面：AVPlayerLayer，不带系统播放控件。
final class PlayerLayerView: KeyHandlingView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 先设置 layer 再打开 wantsLayer：layer-hosting 视图。
        layer = playerLayer
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ controller: PlayerController?) {
        guard self.controller !== controller || playerLayer.player !== controller?.player else { return }
        self.controller = controller
        playerLayer.player = controller?.player
        if controller != nil {
            Task { @MainActor [weak self] in self?.becomeKeyTarget() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if controller != nil { becomeKeyTarget() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // 双击画面：播放 / 暂停。
        if event.clickCount == 2 { controller?.perform(.togglePlay) }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.attach(controller)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.attach(controller)
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: ()) {
        nsView.attach(nil)
    }
}
