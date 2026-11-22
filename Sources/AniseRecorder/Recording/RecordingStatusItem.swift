import AppKit

/// 1118 Loop：录制中的菜单栏状态项——HUD 与主窗口状态页之外的第三个
/// 停止入口。录制开始时出现、停止 / 意外停止时移除；点图标弹菜单：
/// 暂停 / 继续、新标记、停止。`NSStatusItem` 不激活本 App，不抢用户
/// 当前应用的焦点。
@MainActor
final class RecordingStatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var onPauseToggle: (() -> Void)?
    private var onMarker: (() -> Void)?
    private var onStop: (() -> Void)?

    private var isPaused = false

    func show(
        onPauseToggle: @escaping () -> Void,
        onMarker: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        hide()
        self.onPauseToggle = onPauseToggle
        self.onMarker = onMarker
        self.onStop = onStop
        isPaused = false

        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        item.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "正在录制，点按打开录制菜单"
        )
        item.button?.contentTintColor = NSColor.systemRed
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        guard let button = statusItem?.button else { return }
        button.contentTintColor = isPaused
            ? NSColor.controlTextColor : NSColor.systemRed
    }

    func hide() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        onPauseToggle = nil
        onMarker = nil
        onStop = nil
    }

    // MARK: NSMenuDelegate

    /// 每次打开菜单时重建条目：暂停 / 继续标题、标记可用性与当前
    /// 录制状态保持一致。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pause = NSMenuItem(
            title: isPaused ? "继续录制" : "暂停录制",
            action: #selector(togglePauseAction),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let marker = NSMenuItem(
            title: "新标记",
            action: #selector(markerAction),
            keyEquivalent: ""
        )
        marker.target = self
        marker.isEnabled = !isPaused
        menu.addItem(marker)

        menu.addItem(.separator())

        let stop = NSMenuItem(
            title: "停止录制",
            action: #selector(stopAction),
            keyEquivalent: ""
        )
        stop.target = self
        menu.addItem(stop)
    }

    @objc private func togglePauseAction() {
        onPauseToggle?()
    }

    @objc private func markerAction() {
        onMarker?()
    }

    @objc private func stopAction() {
        onStop?()
    }
}
