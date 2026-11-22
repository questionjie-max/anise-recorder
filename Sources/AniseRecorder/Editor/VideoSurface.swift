import AVFoundation
import AVKit
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.wantsLayer = true
        // 信箱填充边随浅色主题走纸白（成片内容本身不受影响）
        view.layer?.backgroundColor = NSColor.white.cgColor
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
