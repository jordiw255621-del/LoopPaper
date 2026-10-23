import AppKit
import AVFoundation

/// Plays a looping, muted video behind the desktop icons on every screen and every Space.
final class DesktopPlayer {
    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var url: URL?
    private var paused = false

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.buildWindows() }
    }

    func play(_ url: URL) {
        stop()
        self.url = url
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
        player = p
        buildWindows()
        if !paused { p.play() }
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { player?.pause() } else { player?.play() }
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        url = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard let player else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            w.contentView = view
            w.orderFront(nil)
            windows.append(w)
        }
    }
}
