import XCTest
@testable import AniseRecorderCore

/// 1.2 字幕术语表替换规则测试：整词边界、CJK 最长优先、不误伤子串、
/// 不跨 cue 边界（每条独立）。
final class CaptionGlossaryTests: XCTestCase {
    func testLatinTermReplacesWholeWordCaseInsensitively() {
        let entries = [GlossaryEntry(wrong: "new york", right: "New York")]
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "this is NEW YORK app"),
            "this is New York app"
        )
        // 不误伤子串（含空格的词条本来就不会命中连写形式）。
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "MyNewYorkX and newyork"),
            "MyNewYorkX and newyork"
        )
        // 整词边界：连字符属于边界。
        let compact = [GlossaryEntry(wrong: "studio", right: "Studio")]
        XCTAssertEqual(
            CaptionGlossary.apply(compact, to: "un-studio-ish"),
            "un-Studio-ish"
        )
        XCTAssertEqual(
            CaptionGlossary.apply(compact, to: "studiob"),
            "studiob"
        )
    }

    func testLatinTermWithPunctuationBoundaries() {
        let entries = [GlossaryEntry(wrong: "like", right: "例如")]
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "I like it, likewise do not."),
            "I 例如 it, likewise do not."
        )
    }

    func testCJKTermReplacesExactly() {
        let entries = [GlossaryEntry(wrong: "本地工作室", right: "New York")]
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "欢迎使用本地工作室录屏"),
            "欢迎使用New York录屏"
        )
    }

    func testLongestEntryWins() {
        let entries = [
            GlossaryEntry(wrong: "本地", right: "new"),
            GlossaryEntry(wrong: "本地工作室", right: "New York")
        ]
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "本地工作室很棒"),
            "New York很棒"
        )
    }

    func testEachCueIsIndependent() {
        let entries = [GlossaryEntry(wrong: "嗯", right: "")]
        // 同样的文本在两条 cue 中各自替换，不互相影响。
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "嗯好的"),
            "好的"
        )
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "第二个嗯"),
            "第二个"
        )
    }

    func testEmptyAndInvalidEntriesIgnored() {
        let entries = [
            GlossaryEntry(wrong: "", right: "x"),
            GlossaryEntry(wrong: "  ", right: "y"),
            GlossaryEntry(wrong: "abc", right: "")
        ]
        XCTAssertEqual(
            CaptionGlossary.apply(entries, to: "abc def"),
            " def"
        )
        XCTAssertEqual(CaptionGlossary.apply([], to: "原样"), "原样")
    }
}
