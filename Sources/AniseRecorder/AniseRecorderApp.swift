import AppKit
import SwiftUI

@main
struct AniseRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("八角录屏") {
            RootView(model: model)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .defaultSize(width: 1220, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    model.undoProjectEdit()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!model.canUndo)

                Button("重做") {
                    model.redoProjectEdit()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }

            CommandGroup(replacing: .newItem) {
                Button("新建录制") {
                    model.showRecorder()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("导入工程…") {
                    model.chooseProjectToImport()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.canManageProjects)

                Button(model.isRecording ? "停止录制" : "开始录制") {
                    Task {
                        if model.isRecording {
                            await model.stopRecording()
                        } else {
                            await model.startRecording()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(
                    model.isPreparing
                        || (model.isRecording && model.isRecordingTransitioning)
                )

                Button(
                    model.isRecordingPaused
                        ? "继续录制"
                        : "暂停录制"
                ) {
                    Task {
                        if model.isRecordingPaused {
                            await model.resumeRecording()
                        } else {
                            await model.pauseRecording()
                        }
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(
                    !model.isRecording
                        || model.isPreparing
                        || model.isRecordingTransitioning
                )
            }

            CommandMenu("导出") {
                Button("导出 MP4…") {
                    model.exportProject()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(model.draft == nil || model.exportProgress != nil)

                Button("在访达中显示素材") {
                    model.revealProjectFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.draft == nil)
            }

            // 提词器（提词器）：快捷键统一用 ⌘⌥ 前缀，避开应用既有快捷键
            // 与文本输入（Option 单修饰键会输入特殊字符）。面板未打开时
            // 面板内动作禁用。
            CommandMenu("提词器") {
                Button(model.isTeleprompterVisible ? "关闭提词面板" : "打开提词面板") {
                    model.toggleTeleprompterPanel()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button(model.isTeleprompterPaused ? "继续滚动" : "暂停滚动") {
                    model.toggleTeleprompterPause()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.isTeleprompterVisible)

                Button("加速") {
                    model.stepTeleprompterSpeed(1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!model.isTeleprompterVisible)

                Button("减速") {
                    model.stepTeleprompterSpeed(-1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!model.isTeleprompterVisible)

                Button("回退一行") {
                    model.stepTeleprompterLine(-1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.isTeleprompterVisible)

                Button("前进一行") {
                    model.stepTeleprompterLine(1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.isTeleprompterVisible)
            }

            // 帮助：应用内快捷键一览，⌘/ 随时可查；纯文档入口，
            // 不改变任何现有快捷键行为。（SDK 未见 init(appending:)，
            // 用 after: .help 追加到默认帮助项之后。）
            CommandGroup(after: .help) {
                Button("键盘快捷键…") {
                    ShortcutHelpWindowController.shared.show()
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    /// 无窗口时点 Dock 图标/重新打开应用：恢复主窗口。
    /// （窗口状态恢复可能记下「零窗口」，不加这段会像启动失败。）
    /// 1118 Loop：录制中主窗口被 orderOut、屏幕上只剩 HUD 等面板——
    /// 判定改为「没有可见的主窗口（忽略 NSPanel）」，否则录制期间
    /// 点 Dock 无法弹回主窗口，用户没有地方点停止。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            let hasVisibleMain = sender.windows.contains { window in
                !(window is NSPanel) && window.canBecomeMain
                    && window.isVisible
            }
            if !hasVisibleMain {
                for window in sender.windows
                where !(window is NSPanel) && window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
        return true
    }
}
