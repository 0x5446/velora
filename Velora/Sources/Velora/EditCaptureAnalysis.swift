import Foundation

/// Pinyin-domain comparison for Chinese ASR-error detection. Latinization via
/// CFStringTransform is deterministic and offline; Latin input passes through
/// unchanged, so the same distance works for English near-homophones.
public enum VeloraPinyin {
    public static func latinized(_ text: String) -> String {
        let transformed = text
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        return transformed.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    public static func distance(_ a: String, _ b: String) -> Int {
        let left = Array(latinized(a))
        let right = Array(latinized(b))
        if left.isEmpty && right.isEmpty {
            return 0
        }
        guard !left.isEmpty, !right.isEmpty else {
            return max(left.count, right.count)
        }
        return VeloraTextSimilarity.levenshtein(left, right)
    }

    /// True when two spans sound the same or nearly the same. The budget
    /// scales with pinyin length so 超市→超时 (chaoshi→chaoshi, 0) and
    /// 文当→文档 (wendang→wendang, 0) pass while 方案→版本 fails.
    public static func isNearHomophone(_ a: String, _ b: String) -> Bool {
        let left = latinized(a)
        let right = latinized(b)
        guard !left.isEmpty, !right.isEmpty else {
            return false
        }
        let budget = max(1, (min(left.count, right.count) + 2) / 3)
        return distance(a, b) <= budget
    }
}

/// One contiguous edit the user made inside the inserted span.
public struct VeloraEditBlock: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Sound-alike substitution — the ASR misheard; hotword candidate.
        case asrFix = "asr_fix"
        /// Same meaning, different wording/punctuation — polish feedback only.
        case style
        /// The user changed what is being said — no supervision signal.
        case content
        /// The user reverted a replacement our hotword pass applied.
        case revertedHotword = "reverted_hotword"
    }

    public var kind: Kind
    public var before: String
    public var after: String
    public var pinyinDistance: Int

    public init(kind: Kind, before: String, after: String, pinyinDistance: Int) {
        self.kind = kind
        self.before = before
        self.after = after
        self.pinyinDistance = pinyinDistance
    }
}

public struct VeloraEditAnalysis: Sendable, Equatable {
    public var blocks: [VeloraEditBlock]
    /// 1.0 = untouched. Below ~0.75 the user effectively rewrote the span and
    /// per-block signals are unreliable (D2 cleaning rule).
    public var similarity: Double
    public var isRewrite: Bool
}

/// Character-level diff + classification of "what the user changed after we
/// inserted". Deterministic and local: false positives poison the hotword
/// table, so every ambiguous case degrades to .style or .content, never .asrFix.
public enum VeloraEditAnalyzer {
    public static let rewriteSimilarityFloor = 0.75

    public static func analyze(
        inserted: String,
        userFinal: String,
        appliedEdits: [TextEdit] = []
    ) -> VeloraEditAnalysis {
        let similarity = VeloraTextSimilarity.normalizedSimilarity(inserted, userFinal)
        let rawBlocks = editSpans(before: inserted, after: userFinal)
        let isRewrite = similarity < rewriteSimilarityFloor

        let blocks = rawBlocks.compactMap { span -> VeloraEditBlock? in
            classify(
                before: span.before,
                after: span.after,
                appliedEdits: appliedEdits,
                inRewrite: isRewrite
            )
        }
        return VeloraEditAnalysis(blocks: blocks, similarity: similarity, isRewrite: isRewrite)
    }

    // MARK: - Diff

    /// Contiguous non-equal spans from a character-level LCS alignment.
    /// Adjacent spans separated by a single unchanged character are merged so
    /// 「反回结果」→「返回结果」 and 「反回接果」→「返回结果」 both yield one
    /// block instead of confetti.
    static func editSpans(before: String, after: String) -> [(before: String, after: String)] {
        let a = Array(before)
        let b = Array(after)
        guard a != b else {
            return []
        }
        // Guard against pathological inputs — dictation spans are short.
        guard a.count <= 2_000, b.count <= 2_000 else {
            return [(before, after)]
        }

        // LCS table (a.count+1) x (b.count+1).
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    lcs[i][j] = a[i - 1] == b[j - 1]
                        ? lcs[i - 1][j - 1] + 1
                        : max(lcs[i - 1][j], lcs[i][j - 1])
                }
            }
        }

        // Backtrack into per-position ops, then group.
        enum Op { case equal(Character), delete(Character), insert(Character) }
        var ops: [Op] = []
        var i = a.count
        var j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                ops.append(.equal(a[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || lcs[i][j - 1] >= lcs[i - 1][j] {
                ops.append(.insert(b[j - 1]))
                j -= 1
            } else {
                ops.append(.delete(a[i - 1]))
                i -= 1
            }
        }
        ops.reverse()

        var spans: [(before: String, after: String)] = []
        var currentBefore = ""
        var currentAfter = ""
        var equalRun = ""
        var inSpan = false

        func flush() {
            if inSpan {
                spans.append((currentBefore, currentAfter))
                currentBefore = ""
                currentAfter = ""
                inSpan = false
            }
            equalRun = ""
        }

        for op in ops {
            switch op {
            case .equal(let character):
                guard inSpan else {
                    continue
                }
                equalRun.append(character)
                // A short unchanged bridge keeps one logical edit together;
                // two or more unchanged characters end the span.
                if equalRun.count >= 2 {
                    currentBefore.removeLast(equalRun.count - 1)
                    currentAfter.removeLast(equalRun.count - 1)
                    // The bridge characters minus the final run belong to the
                    // span only while the run was still short; drop the whole
                    // trailing run and close.
                    flush()
                } else {
                    currentBefore.append(character)
                    currentAfter.append(character)
                }
            case .delete(let character):
                inSpan = true
                equalRun = ""
                currentBefore.append(character)
            case .insert(let character):
                inSpan = true
                equalRun = ""
                currentAfter.append(character)
            }
        }
        flush()

        // Trim bridge remnants: spans may end with the single equal character
        // appended while the run was short.
        return spans.map { span in
            var before = span.before
            var after = span.after
            while let lastB = before.last, let lastA = after.last, lastB == lastA {
                before.removeLast()
                after.removeLast()
            }
            while let firstB = before.first, let firstA = after.first, firstB == firstA {
                before.removeFirst()
                after.removeFirst()
            }
            return (before, after)
        }
        .filter { !($0.before.isEmpty && $0.after.isEmpty) }
    }

    // MARK: - Classification

    static func classify(
        before: String,
        after: String,
        appliedEdits: [TextEdit],
        inRewrite: Bool
    ) -> VeloraEditBlock? {
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        let trimmedAfter = after.trimmingCharacters(in: .whitespaces)

        // Pure punctuation/whitespace churn carries no signal at all.
        if isPunctuationOnly(trimmedBefore) && isPunctuationOnly(trimmedAfter) {
            return nil
        }

        // Reverting our own hotword replacement is the strongest negative
        // signal and outranks every other classification.
        for edit in appliedEdits
        where !edit.from.isEmpty && trimmedBefore == edit.to && trimmedAfter == edit.from {
            return VeloraEditBlock(
                kind: .revertedHotword,
                before: trimmedBefore,
                after: trimmedAfter,
                pinyinDistance: VeloraPinyin.distance(trimmedBefore, trimmedAfter)
            )
        }

        // Pure insert/delete: the user changed what is being said.
        guard !trimmedBefore.isEmpty, !trimmedAfter.isEmpty else {
            return VeloraEditBlock(kind: .content, before: trimmedBefore, after: trimmedAfter, pinyinDistance: 0)
        }

        // ITN/formatting equivalence (三点 ↔ 3点, 百分之五 ↔ 5%): style, and
        // must never enter the hotword table.
        if isNumericFormattingPair(trimmedBefore, trimmedAfter) {
            return VeloraEditBlock(kind: .style, before: trimmedBefore, after: trimmedAfter, pinyinDistance: 0)
        }

        let pinyinDistance = VeloraPinyin.distance(trimmedBefore, trimmedAfter)
        let isShort = (1...6).contains(trimmedBefore.count) && (1...6).contains(trimmedAfter.count)
        if isShort,
           !inRewrite,
           VeloraPinyin.isNearHomophone(trimmedBefore, trimmedAfter),
           VeloraLearnGate.isLearnablePair(term: trimmedBefore, replacement: trimmedAfter) {
            return VeloraEditBlock(
                kind: .asrFix,
                before: trimmedBefore,
                after: trimmedAfter,
                pinyinDistance: pinyinDistance
            )
        }

        return VeloraEditBlock(
            kind: .style,
            before: trimmedBefore,
            after: trimmedAfter,
            pinyinDistance: pinyinDistance
        )
    }

    static func isPunctuationOnly(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isPunctuation || $0.isSymbol || $0.isWhitespace }
    }

    /// Both sides express a number/date/unit in different notations.
    static func isNumericFormattingPair(_ a: String, _ b: String) -> Bool {
        let numericish = CharacterSet(charactersIn: "0123456789〇零一二两三四五六七八九十百千万亿点比第%.:：年月日号时点分秒个")
        func isNumericish(_ text: String) -> Bool {
            let hasDigitOrNumeral = text.contains { character in
                character.isNumber || "〇零一二两三四五六七八九十百千万亿".contains(character)
            }
            return hasDigitOrNumeral && text.unicodeScalars.allSatisfy { numericish.contains($0) }
        }
        return isNumericish(a) && isNumericish(b)
    }
}

/// Gate deciding whether a mined pair may enter the hotword table. High-
/// frequency function words are hard-banned: one bad entry silently rewrites
/// every future dictation (HomophoneReplacer replaces unconditionally).
public enum VeloraLearnGate {
    public static func isLearnablePair(term: String, replacement: String) -> Bool {
        guard SQLiteMemoryStore.isReasonableTermPair(term: term, replacement: replacement) else {
            return false
        }
        guard term.count <= 6, replacement.count <= 6 else {
            return false
        }
        let forbidden = CharacterSet(charactersIn: "0123456789/\\@#$&*<>{}[]()=+~`|\"'")
        guard term.rangeOfCharacter(from: forbidden) == nil,
              replacement.rangeOfCharacter(from: forbidden) == nil else {
            return false
        }
        let lowerTerm = term.lowercased()
        let lowerReplacement = replacement.lowercased()
        guard !stopwords.contains(lowerTerm), !stopwords.contains(lowerReplacement) else {
            return false
        }
        return true
    }

    /// Common zh/en function and everyday words. Deliberately small: it only
    /// has to stop the catastrophic cases (的/了/we/you rewriting everywhere),
    /// the promotion gate (≥2 hits across ≥2 sessions) handles the long tail.
    public static let stopwords: Set<String> = [
        // zh single-character function words
        "的", "了", "是", "我", "你", "他", "她", "它", "这", "那", "都", "也", "很", "就",
        "再", "又", "会", "要", "想", "说", "看", "听", "做", "去", "来", "到", "在", "有",
        "和", "跟", "给", "把", "被", "让", "从", "对", "为", "上", "下", "前", "后", "里",
        "外", "中", "大", "小", "多", "少", "好", "新", "老", "高", "低", "长", "短", "不",
        "没", "别", "更", "最", "还", "才", "只", "先", "点", "些", "个", "位", "件", "种",
        // zh common words
        "我们", "你们", "他们", "她们", "这个", "那个", "这些", "那些", "什么", "怎么",
        "为什么", "因为", "所以", "但是", "可是", "如果", "就是", "还是", "或者", "而且",
        "然后", "现在", "今天", "明天", "昨天", "时间", "问题", "事情", "东西", "地方",
        "大家", "自己", "没有", "不是", "可以", "不能", "应该", "需要", "觉得", "知道",
        "认为", "希望", "一下", "一个", "一些", "很多", "非常", "真的", "其实", "已经",
        "开始", "结束", "工作", "生活", "朋友", "感觉", "意思", "方面", "情况", "结果",
        "确定", "肯定", "直接", "刚才", "以后", "之前", "之后", "上面", "下面", "里面",
        // en function words
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "for", "with",
        "is", "are", "was", "were", "be", "been", "it", "this", "that", "these", "those",
        "i", "we", "you", "he", "she", "they", "my", "our", "your", "at", "by", "from",
        "as", "if", "so", "no", "not", "do", "did", "does", "have", "has", "had", "will",
        "would", "can", "could", "should", "there", "here", "what", "when", "where",
        "who", "how", "then", "than", "them", "his", "her", "its", "about", "into",
    ]
}

/// Locates "the span we inserted" inside a later snapshot of the same text
/// field, using the unchanged text around the span as anchors. Anchor-based
/// on purpose: offsets drift the moment the user edits anything ABOVE the
/// span, while the surrounding context usually survives.
public enum VeloraSpanAnchor {
    public struct Extraction: Sendable, Equatable {
        public var span: String
        public var method: String

        public init(span: String, method: String) {
            self.span = span
            self.method = method
        }
    }

    /// Terminal-grid hosts (iTerm2, Terminal.app) expose the screen as wrapped
    /// rows: hard \n (and \r) land INSIDE any span longer than one row, which
    /// breaks exact span matches and poisons diffs with phantom newlines.
    /// Observations on such hosts run entirely in wrap-stripped space — the
    /// observer strips every value it reads with this before matching/diffing.
    public static func strippingHardWraps(_ text: String) -> String {
        // Drop newlines AND the padding spaces just before them: a CJK
        // double-width char that does not fit the last column leaves a
        // one-column gap, which the grid renders as trailing space(s).
        // Interior spaces are real content and are preserved.
        // Character.isNewline also matches the CRLF grapheme cluster, which
        // a plain == "\n" / == "\r" comparison would miss entirely.
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpaces = 0
        for ch in text {
            if ch.isNewline {
                pendingSpaces = 0
            } else if ch == " " {
                pendingSpaces += 1
            } else {
                if pendingSpaces > 0 {
                    result += String(repeating: " ", count: pendingSpaces)
                    pendingSpaces = 0
                }
                result.append(ch)
            }
        }
        if pendingSpaces > 0 {
            result += String(repeating: " ", count: pendingSpaces)
        }
        return result
    }

    /// - Parameters:
    ///   - baseline: full field value right after insertion.
    ///   - spanStart/spanLength: character offsets of the inserted text in `baseline`.
    ///   - updated: full field value at settle time.
    public static func extractSpan(
        baseline: String,
        spanStart: Int,
        spanLength: Int,
        updated: String
    ) -> Extraction? {
        let baseChars = Array(baseline)
        guard spanStart >= 0, spanLength > 0, spanStart + spanLength <= baseChars.count else {
            return nil
        }
        let updatedChars = Array(updated)
        // Very large documents make fuzzy fallbacks quadratic; anchors still
        // work because they are exact-match. Only the fallback is capped.
        let prefixAnchor = anchor(from: baseChars, end: spanStart, length: 16)
        let suffixAnchor = anchor(from: baseChars, start: spanStart + spanLength, length: 16)

        let originalSpan = Array(baseChars[spanStart..<(spanStart + spanLength)])
        // Solve the two anchors as a PAIR: pick the (prefix-end, suffix-start)
        // combination whose gap is closest to the original span length. Solving
        // them independently (last prefix, then first suffix after it) mis-locates
        // when the prefix context repeats AFTER the span.
        let (lowerBound, upperBound) = locateAnchorPair(
            prefix: prefixAnchor,
            suffix: suffixAnchor,
            in: updatedChars,
            expectedGap: spanLength
        )

        switch (lowerBound, upperBound) {
        case let (.some(low), .some(high)) where high >= low:
            return Extraction(span: String(updatedChars[low..<high]), method: "anchors")
        case let (.some(low), nil) where suffixAnchor.isEmpty:
            // Inserted at end of document: everything after the prefix anchor.
            return Extraction(span: String(updatedChars[low...]), method: "prefix_anchor_to_end")
        case let (nil, .some(high)) where prefixAnchor.isEmpty:
            return Extraction(span: String(updatedChars[..<high]), method: "start_to_suffix_anchor")
        case let (.some(low), _):
            // Prefix anchor survived, suffix did not: fuzzy-match the span
            // itself in a bounded region after the anchor.
            let end = min(updatedChars.count, low + spanLength * 2 + 32)
            guard low < end,
                  let range = fuzzyLocate(originalSpan, in: Array(updatedChars[low..<end])) else {
                return nil
            }
            return Extraction(
                span: String(updatedChars[(low + range.lowerBound)..<(low + range.upperBound)]),
                method: "prefix_anchor_fuzzy"
            )
        case let (nil, .some(high)):
            let start = max(0, high - spanLength * 2 - 32)
            guard start < high,
                  let range = fuzzyLocate(originalSpan, in: Array(updatedChars[start..<high])) else {
                return nil
            }
            return Extraction(
                span: String(updatedChars[(start + range.lowerBound)..<(start + range.upperBound)]),
                method: "suffix_anchor_fuzzy"
            )
        default:
            // Both anchors empty means the span WAS the whole field.
            if prefixAnchor.isEmpty && suffixAnchor.isEmpty {
                return Extraction(span: updated, method: "whole_field")
            }
            // No anchor survived at all: last-resort fuzzy over small fields
            // only — big documents would make this quadratic.
            guard updatedChars.count <= 2_000,
                  let range = fuzzyLocate(originalSpan, in: updatedChars) else {
                return nil
            }
            return Extraction(
                span: String(updatedChars[range.lowerBound..<range.upperBound]),
                method: "fuzzy"
            )
        }
    }

    /// Best sliding-window match of `span` inside `text` by normalized
    /// similarity. Three window sizes cover shrink/grow edits; the region is
    /// expected to be pre-bounded by the caller. Public because the capture
    /// path also uses it to arm an observation when the user already started
    /// editing before capture landed.
    public static func fuzzyLocate(
        _ span: [Character],
        in text: [Character],
        minSimilarity: Double = 0.6
    ) -> Range<Int>? {
        guard !span.isEmpty, !text.isEmpty, text.count <= 4_000 else {
            return nil
        }
        let spanText = String(span)
        let sizes = Set([
            max(1, span.count * 2 / 3),
            span.count,
            span.count * 4 / 3 + 1,
        ]).filter { $0 <= text.count }
        var best: (range: Range<Int>, similarity: Double)?
        for size in sizes {
            for start in 0...(text.count - size) {
                let window = String(text[start..<(start + size)])
                let similarity = VeloraTextSimilarity.normalizedSimilarity(spanText, window)
                if similarity >= minSimilarity, similarity > (best?.similarity ?? 0) {
                    best = (start..<(start + size), similarity)
                }
            }
        }
        return best?.range
    }

    /// All indices just past each occurrence of `anchor` in `text`.
    private static func anchorEnds(_ anchor: [Character], in text: [Character]) -> [Int] {
        guard !anchor.isEmpty, text.count >= anchor.count else {
            return []
        }
        var ends: [Int] = []
        for start in 0...(text.count - anchor.count)
        where Array(text[start..<(start + anchor.count)]) == anchor {
            ends.append(start + anchor.count)
        }
        return ends
    }

    /// All start indices of each occurrence of `anchor` in `text`.
    private static func anchorStarts(_ anchor: [Character], in text: [Character]) -> [Int] {
        guard !anchor.isEmpty, text.count >= anchor.count else {
            return []
        }
        var starts: [Int] = []
        for start in 0...(text.count - anchor.count)
        where Array(text[start..<(start + anchor.count)]) == anchor {
            starts.append(start)
        }
        return starts
    }

    /// Chooses the prefix-end / suffix-start pair whose gap is closest to the
    /// expected span length, degrading each anchor to its inner 6 chars if the
    /// full context was grazed by an edit. Empty anchors mean the span sat at a
    /// document edge and are returned as nil so the caller's edge cases handle them.
    private static func locateAnchorPair(
        prefix: [Character],
        suffix: [Character],
        in text: [Character],
        expectedGap: Int
    ) -> (Int?, Int?) {
        var ends = anchorEnds(prefix, in: text)
        if ends.isEmpty, prefix.count > 6 {
            ends = anchorEnds(Array(prefix.suffix(6)), in: text)
        }
        var starts = anchorStarts(suffix, in: text)
        if starts.isEmpty, suffix.count > 6 {
            starts = anchorStarts(Array(suffix.prefix(6)), in: text)
        }

        let low: Int? = prefix.isEmpty ? nil : ends.min(by: { abs($0 - 0) < abs($1 - 0) })
        // For empty prefix, edge case returns nil low; keep suffix best guess.
        if prefix.isEmpty {
            return (nil, suffix.isEmpty ? nil : starts.first)
        }
        if suffix.isEmpty {
            return (low, nil)
        }
        guard !ends.isEmpty, !starts.isEmpty else {
            return (ends.isEmpty ? nil : low, nil)
        }

        var best: (low: Int, high: Int, cost: Int)?
        for end in ends {
            for start in starts where start >= end {
                let cost = abs((start - end) - expectedGap)
                if cost < (best?.cost ?? Int.max) {
                    best = (end, start, cost)
                }
            }
        }
        if let best {
            return (best.low, best.high)
        }
        // No suffix occurs after any prefix end: fall back to nearest prefix end.
        return (low, nil)
    }

    private static func anchor(from characters: [Character], end: Int, length: Int) -> [Character] {
        let start = max(0, end - length)
        guard start < end else {
            return []
        }
        return Array(characters[start..<end])
    }

    private static func anchor(from characters: [Character], start: Int, length: Int) -> [Character] {
        let end = min(characters.count, start + length)
        guard start < end else {
            return []
        }
        return Array(characters[start..<end])
    }
}
