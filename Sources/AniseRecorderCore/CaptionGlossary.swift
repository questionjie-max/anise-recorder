import Foundation

/// 1.2 字幕术语表条目：错词 → 正词。存应用偏好（不进单个工程）。
package struct GlossaryEntry: Hashable, Sendable, Codable {
    package var wrong: String
    package var right: String

    package init(wrong: String, right: String) {
        self.wrong = wrong
        self.right = right
    }
}

/// 字幕术语表替换（1.2 块3）：对 cue 文本做「错词 → 正词」替换。
///
/// 匹配规则（写清、配测试，路线图要求不误伤子串）：
/// - 纯拉丁字母 / 数字词条：**整词 + 忽略大小写**匹配（\b 边界），
///   "like" 不会命中 "likewise"、"NewYork" 不会命中 "MyNewYorkX"。
/// - 含 CJK 的词条：CJK 无词边界，采用**最长优先精确替换**；表由用户
///   维护，套用结果在字幕列表可见可改，误伤由用户调整词条解决。
/// - 替换不跨 cue 边界：每条 cue 文本独立处理，函数只对单条文本负责。
/// - 长词条优先：多个词条命中同一处时按词条长度降序依次应用，
///   "本地工作室" 这类长产品名不会被其子串词条抢先破坏。
package enum CaptionGlossary {
    package static func apply(
        _ entries: [GlossaryEntry],
        to text: String
    ) -> String {
        let cleaned = entries
            .map {
                GlossaryEntry(
                    wrong: $0.wrong.trimmingCharacters(in: .whitespaces),
                    right: $0.right
                )
            }
            .filter { !$0.wrong.isEmpty }
        guard !cleaned.isEmpty else { return text }
        // 最长优先，稳定排序：同长度保持用户输入顺序。
        let ordered = cleaned.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.wrong.count != rhs.element.wrong.count {
                    return lhs.element.wrong.count > rhs.element.wrong.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var result = text
        for entry in ordered {
            if isLatinTerm(entry.wrong) {
                result = replaceLatinWord(
                    entry.wrong,
                    with: entry.right,
                    in: result
                )
            } else {
                result = result.replacingOccurrences(
                    of: entry.wrong,
                    with: entry.right
                )
            }
        }
        return result
    }

    // MARK: - 私有辅助

    /// 词条是否纯拉丁字母 / 数字（含连字符、空格、点号等词内符号）。
    /// 只认 ASCII：CJK 在 Unicode 里也属于字母类（Lo），不能用
    /// CharacterSet.alphanumerics 判断，否则整词边界永远不会命中。
    private static func isLatinTerm(_ term: String) -> Bool {
        !term.isEmpty
            && term.unicodeScalars.allSatisfy { scalar in
                guard scalar.value < 128 else { return false }
                return CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-"
                    || scalar == "'"
                    || scalar == "."
                    || scalar == " "
            }
    }

    /// 拉丁词条整词替换：逐字符扫描 + 边界判定（前后不是字母 / 数字）。
    /// 不用 NSRegularExpression 是为了保持 Core 的确定性与可测性。
    private static func replaceLatinWord(
        _ term: String,
        with replacement: String,
        in text: String
    ) -> String {
        let loweredTerm = term.lowercased()
        let loweredText = text.lowercased()
        let termScalars = Array(loweredTerm.unicodeScalars)
        let textScalars = Array(loweredText.unicodeScalars)
        let originalScalars = Array(text.unicodeScalars)
        guard !termScalars.isEmpty else { return text }

        var output = String.UnicodeScalarView()
        var index = 0
        while index < textScalars.count {
            if matchesAt(
                textScalars,
                index,
                termScalars
            ) {
                let endIndex = index + termScalars.count
                let beforeOk = index == 0
                    || !isWordScalar(textScalars[index - 1])
                let afterOk = endIndex == textScalars.count
                    || !isWordScalar(textScalars[endIndex])
                if beforeOk, afterOk {
                    output.append(
                        contentsOf: replacement.unicodeScalars
                    )
                    index = endIndex
                    continue
                }
            }
            output.append(originalScalars[index])
            index += 1
        }
        return String(output)
    }

    private static func matchesAt(
        _ text: [Unicode.Scalar],
        _ index: Int,
        _ term: [Unicode.Scalar]
    ) -> Bool {
        guard index + term.count <= text.count else { return false }
        for offset in term.indices {
            if text[index + offset] != term[offset] {
                return false
            }
        }
        return true
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }
}
