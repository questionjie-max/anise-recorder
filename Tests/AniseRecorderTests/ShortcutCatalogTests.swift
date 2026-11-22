import XCTest
@testable import AniseRecorder

/// 应用内快捷键目录（⌘/ 帮助面板的数据源）。目录是快捷键文档的
/// 唯一事实源，这里守住三件事——结构完整（标题/按键/分组）、菜单与
/// 编辑器实际存在的按键都收录、同组按键不重复。
final class ShortcutCatalogTests: XCTestCase {
    private var allShortcuts: [AppShortcut] {
        AppShortcutCatalog.groups.flatMap(\.shortcuts)
    }

    private var allKeys: Set<String> {
        Set(allShortcuts.map(\.keys))
    }

    private var allIds: Set<String> {
        Set(allShortcuts.map(\.id))
    }

    func testCatalogHasAtLeastThreeGroups() {
        // 全局录制 / 编辑器（播放标记、精剪、摄像头）/ 提词器。
        XCTAssertGreaterThanOrEqual(AppShortcutCatalog.groups.count, 3)
    }

    func testEveryShortcutHasTitleKeysAndUniqueId() {
        var seen = Set<String>()
        for shortcut in allShortcuts {
            XCTAssertFalse(shortcut.title.isEmpty, shortcut.id)
            XCTAssertFalse(shortcut.keys.isEmpty, shortcut.id)
            XCTAssertTrue(
                seen.insert(shortcut.id).inserted,
                "重复的快捷键 id：\(shortcut.id)"
            )
        }
        for group in AppShortcutCatalog.groups {
            XCTAssertFalse(group.name.isEmpty, group.id)
            XCTAssertFalse(group.shortcuts.isEmpty, group.id)
        }
    }

    func testGroupIdsAndNamesAreUnique() {
        var ids = Set<String>()
        var names = Set<String>()
        for group in AppShortcutCatalog.groups {
            XCTAssertTrue(ids.insert(group.id).inserted, group.id)
            XCTAssertTrue(names.insert(group.name).inserted, group.name)
        }
    }

    /// 时间线折叠快捷键必须收录且与编辑器里的注册一致；
    /// 折叠偏好键为全局偏好（默认展开）。
    /// 隐私引导：面板名称必须与系统设置中文标题一致（用户照着找得到），
    /// 深链必须指向对应 privacy_<服务>。
    func testPrivacySettingsPanesUseSystemNamesAndDeepLinks() {
        XCTAssertEqual(PrivacySettingsPane.camera.title, "摄像头")
        XCTAssertEqual(PrivacySettingsPane.microphone.title, "麦克风")
        XCTAssertEqual(
            PrivacySettingsPane.screenRecording.title,
            "录屏与系统录音"
        )
        XCTAssertEqual(PrivacySettingsPane.speechRecognition.title, "语音识别")
        XCTAssertEqual(
            PrivacySettingsPane.camera.pathDescription,
            "系统设置 › 隐私与安全性 › 摄像头"
        )
        XCTAssertEqual(
            PrivacySettingsPane.camera.urlString,
            "x-apple.systempreferences:com.apple.preference.security.privacy_Camera"
        )
        XCTAssertEqual(
            PrivacySettingsPane.microphone.urlString,
            "x-apple.systempreferences:com.apple.preference.security.privacy_Microphone"
        )
        XCTAssertEqual(
            PrivacySettingsPane.screenRecording.urlString,
            "x-apple.systempreferences:com.apple.preference.security.privacy_ScreenCapture"
        )
        for pane in PrivacySettingsPane.allCases {
            XCTAssertNotNil(pane.url, pane.rawValue)
            XCTAssertTrue(pane.urlString.contains("privacy_"), pane.rawValue)
        }
        // 一键重新授权走 tccutil，服务名大小写敏感，不能与深链名脱节。
        XCTAssertEqual(PrivacySettingsPane.camera.tccServiceName, "Camera")
        XCTAssertEqual(
            PrivacySettingsPane.microphone.tccServiceName,
            "Microphone"
        )
        for pane in PrivacySettingsPane.allCases {
            XCTAssertTrue(
                pane.urlString.hasSuffix("privacy_\(pane.tccServiceName)"),
                pane.rawValue
            )
        }
    }

    /// 版本显示：必须始终是「v…」形式（读不到也显示占位，不留空）。
    func testAppVersionDisplayIsAlwaysPrefixedAndNonEmpty() {
        XCTAssertTrue(AppVersion.display().hasPrefix("v"))
        XCTAssertGreaterThan(AppVersion.display().count, 1)
        XCTAssertTrue(
            AppVersion.detailedDescription().hasPrefix("八角录屏 ")
        )
    }

    func testTimelineCollapseShortcutIsListedAndPreferenceDefaultsExpanded()
        throws
    {
        let shortcut = try XCTUnwrap(
            allShortcuts.first { $0.id == "editor.timeline-collapse" },
            "目录缺少时间线折叠快捷键"
        )
        XCTAssertEqual(shortcut.keys, "⌘\\")
        XCTAssertEqual(
            StudioPreferences.editorTimelineCollapsedKey,
            "editorTimelineCollapsed",
            "折叠偏好键名变化需同步迁移说明"
        )
        UserDefaults.standard.removeObject(
            forKey: StudioPreferences.editorTimelineCollapsedKey
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(
                forKey: StudioPreferences.editorTimelineCollapsedKey
            ),
            "未设置过偏好时应为展开（false）"
        )
    }

    func testMenuShortcutsAreListed() {
        // AniseRecorderApp.swift 菜单实际注册的按键，一项都不能漏；
        // 成对动作（⌘⌥↑/↓、⌘⌥←/→）按面板一行显示串校验。
        let expected = [
            "⌘N", "⌘⇧I", "⌘⇧R", "⌘⇧P", "⌘E", "⌘⇧O", "⌘Z", "⇧⌘Z",
            "⌘,", "⌘/", "⌘⌥T", "⌘⌥P", "⌘⌥↑ ⌘⌥↓", "⌘⌥← ⌘⌥→",
        ]
        for key in expected {
            XCTAssertTrue(allKeys.contains(key), "目录缺少菜单快捷键 \(key)")
        }
    }

    func testEditorShortcutsAreListed() {
        // EditorView 本地监听：空格 / I / O / M / 摄像头方向键微调；
        // HUD 的 Esc 停止也要收录。
        for key in ["空格", "I", "O", "M", "←→", "⌥←→↑↓", "Esc"] {
            XCTAssertTrue(allKeys.contains(key), "目录缺少编辑器快捷键 \(key)")
        }
    }

    func testDocumentedAnchorsExist() {
        // README 与面板共用口径的锚点条目。
        for id in [
            "global.new-recording",
            "global.shortcut-help",
            "editor.space",
            "editor.trim-start",
            "editor.trim-end",
            "editor.marker",
            "editor.camera-nudge",
            "teleprompter.toggle",
        ] {
            XCTAssertTrue(allIds.contains(id), "目录缺少锚点 \(id)")
        }
    }

    func testKeysAreUniqueWithinEachGroup() {
        for group in AppShortcutCatalog.groups {
            var seen = Set<String>()
            for shortcut in group.shortcuts {
                XCTAssertTrue(
                    seen.insert(shortcut.keys).inserted,
                    "\(group.id) 内按键重复：\(shortcut.keys)"
                )
            }
        }
    }

    func testConditionalShortcutsCarryNotes() {
        // 生效条件依赖上下文的条目必须写明，避免面板给出无条件承诺。
        let shortcutsById = Dictionary(
            uniqueKeysWithValues: allShortcuts.map { ($0.id, $0) }
        )
        for id in [
            "global.pause", "global.stop-esc", "teleprompter.pause",
            "teleprompter.space", "editor.camera-nudge",
        ] {
            let shortcut = shortcutsById[id]
            XCTAssertNotNil(shortcut, id)
            XCTAssertNotEqual(shortcut?.note, nil, "\(id) 缺少生效条件说明")
        }
    }

    func testCameraNudgeDocumentsShiftStep() {
        let shortcut = allShortcuts.first { $0.id == "editor.camera-nudge" }
        XCTAssertEqual(shortcut?.keys, "⌥←→↑↓")
        let note = shortcut?.note ?? ""
        XCTAssertTrue(note.contains("⇧"), "摄像头微调需注明 ⇧ 大步进")
    }
}
