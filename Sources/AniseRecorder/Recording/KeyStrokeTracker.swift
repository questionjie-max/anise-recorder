import AppKit
import Carbon.HIToolbox
import AniseRecorderCore

/// 按键显示的数据采集：录制进行中把按键转为「修饰键符号 + 键名」
/// 的小条数据。隐私边界（与 PRIVACY.md 一致）：
/// - 只在录制进行中挂监听，停止即移除；
/// - 系统安全输入（如密码框）激活期间整体跳过，不记录任何键；
/// - 数据只写本机工程文件，不上传。
/// 时间戳与点击/光标同一时钟（captureClock.outputTime），暂停期不记录。
final class KeyStrokeTracker {
    private let clock: CaptureClock
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var events: [KeyStrokeEvent] = []

    init(clock: CaptureClock) {
        self.clock = clock
    }

    func start() {
        stop()
        // 本应用窗口内的按键走 local monitor；被录制的其他应用走 global。
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            self?.record(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            self?.record(event)
        }
    }

    func stop() -> [KeyStrokeEvent] {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        return events
    }

    private func record(_ event: NSEvent) {
        // 系统安全输入激活（密码框等）：不记录，防止捕获凭据。
        guard !IsSecureEventInputEnabled() else { return }
        guard let text = Self.displayText(
            characters: event.charactersIgnoringModifiers ?? "",
            keyCode: Int(event.keyCode),
            command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option),
            shift: event.modifierFlags.contains(.shift),
            control: event.modifierFlags.contains(.control)
        ) else {
            return
        }
        guard
            let sourceTime = clock.outputTime(
                forHostTime: CACurrentMediaTime()
            ),
            sourceTime >= 0
        else {
            return
        }
        events.append(
            KeyStrokeEvent(
                sourceTime: (sourceTime * 1000).rounded() / 1000,
                text: text
            )
        )
    }

    /// 纯函数（可测试）：keyDown → 小条文本。纯修饰键、不可见字符、
    /// 超长粘贴输入返回 nil（不上条）。
    static func displayText(
        characters: String,
        keyCode: Int,
        command: Bool,
        option: Bool,
        shift: Bool,
        control: Bool
    ) -> String? {
        // 纯修饰键的 keyDown（个别键盘布局会发）：不上条。
        let modifierKeyCodes: Set<Int> = [
            54, 55, 56, 57, 58, 59, 60, 61, 62, 63,  // ⌘⌥⇧⌃ 左右两侧
        ]
        guard !modifierKeyCodes.contains(keyCode) else { return nil }

        let named: [Int: String] = [
            kVK_Return: "⏎",
            kVK_ANSI_KeypadEnter: "⏎",
            kVK_Tab: "⇥",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_Escape: "esc",
            kVK_Space: "space",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
        ]
        let key: String
        if let name = named[keyCode] {
            key = name
        } else if
            let first = characters.lowercased().first,
            first.isLetter || first.isNumber
        {
            key = characters.uppercased()
        } else if
            let first = characters.first,
            first.isSymbol || first.isPunctuation
        {
            key = String(first)
        } else {
            return nil
        }

        var prefix = ""
        if control { prefix += "⌃" }
        if option { prefix += "⌥" }
        if shift { prefix += "⇧" }
        if command { prefix += "⌘" }
        return prefix + key
    }
}
