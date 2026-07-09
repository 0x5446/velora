import Foundation

/// Hotword replacement pass. Conceptually part of the ASR capability boundary:
/// text leaving "ASR" is already hotword-corrected. Kept as its own unit so the
/// structured edits stay visible to diagnostics and feedback learning.
///
/// Unconditional replacement is only safe when the LEFT side is not itself a
/// legitimate word ("拥护→用户" would corrupt real 拥护 sentences), and no
/// automatic signal can prove that — so this pass applies ONLY terms the user
/// explicitly marked hard-replace in the dictionary. Everything else reaches
/// the polish LLM as glossary/history context, which decides IN CONTEXT.
public enum HotwordCorrector {
    /// Reason marker set by the memory store for apply_mode='hard' terms.
    public static let hardReplaceReason = "hard_replace"

    public static func correct(text: String, hotwords: [HotwordCandidate]) -> CorrectionResult {
        var corrected = text
        var edits: [TextEdit] = []

        for hotword in hotwords {
            guard hotword.reasons.contains(Self.hardReplaceReason) else {
                continue
            }
            guard hotword.term != hotword.replacement else {
                continue
            }

            let (replaced, count) = replaceRespectingBoundaries(
                in: corrected,
                term: hotword.term,
                replacement: hotword.replacement
            )
            guard count > 0 else {
                continue
            }

            corrected = replaced
            edits.append(
                TextEdit(
                    from: hotword.term,
                    to: hotword.replacement,
                    reason: "selected_hotword",
                    confidence: min(0.96, max(0.72, hotword.score / 10.0))
                )
            )
        }

        return CorrectionResult(
            correctedText: corrected,
            edits: edits,
            selectedHotwords: hotwords,
            confidence: edits.isEmpty ? 0.86 : 0.91,
            reviewRequired: false
        )
    }

    /// Case-insensitive replacement. For terms that start/end with Latin
    /// letters or digits, matches inside larger words are skipped so "velora"
    /// never rewrites "veloraish". CJK terms have no word boundaries and are
    /// replaced as-is.
    static func replaceRespectingBoundaries(
        in text: String,
        term: String,
        replacement: String
    ) -> (result: String, count: Int) {
        guard !term.isEmpty else {
            return (text, 0)
        }

        var result = ""
        result.reserveCapacity(text.count)
        var searchStart = text.startIndex
        var count = 0

        while searchStart < text.endIndex,
              let range = text.range(of: term, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            result += text[searchStart..<range.lowerBound]

            let boundedBefore = !needsBoundary(term.first)
                || range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let boundedAfter = !needsBoundary(term.last)
                || range.upperBound == text.endIndex
                || !isWordCharacter(text[range.upperBound])

            if boundedBefore && boundedAfter {
                result += replacement
                count += 1
            } else {
                result += text[range]
            }

            searchStart = range.upperBound
        }

        result += text[searchStart...]
        return (result, count)
    }

    private static func needsBoundary(_ character: Character?) -> Bool {
        guard let character else {
            return false
        }
        return isWordCharacter(character) && !isCJK(character)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

/// Rule tier of the mandatory polish stage. Always available, always fast.
/// This is the floor every compose result can fall back to.
public enum VeloraTextComposer {
    /// Deterministic filler cleanup. Lives in the rule tier because qwen3:8b
    /// refuses to delete fillers no matter how the prompt is phrased
    /// (verified across 7 prompt candidates, 2026-07-05).
    ///
    /// Every rule here survived an adversarial false-positive review:
    /// - 嗯/呃 are removed only when glued between Han characters (or at line
    ///   start glued to Han) — standalone "嗯，好的" is an intentional reply
    ///   and stays. 呃 keeps a lookahead for the medical term 呃逆.
    /// - 唔 is never touched (Cantonese negation: 我唔知道).
    /// - Stutter collapse is a filler-word whitelist, not a generic Han-block
    ///   fold — generic folding destroys ABAB verbs (商量商量, 考虑考虑).
    /// - English um/uh are removed only in the comma-delimited filler form
    ///   ("Um, I think") and only for English source text, so uh-huh / uh oh
    ///   and German/Portuguese "um" survive.
    public static func strippedFillers(_ input: String, sourceLanguage: String = "zh") -> String {
        var text = input

        func replace(_ pattern: String, with template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return
            }
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }

        // The look-around Han classes exclude 嗯/呃 themselves, otherwise a
        // run like 嗯嗯，收到 backtracks until one 嗯 satisfies the lookahead.
        replace(#"(?<=[\p{Han}&&[^嗯呃]])(?:嗯|呃(?!逆))+(?=[\p{Han}&&[^嗯呃]])"#, with: "")
        replace(#"(?m)^(?:嗯|呃(?!逆))+(?=[\p{Han}&&[^嗯呃]])"#, with: "")
        replace(#"(这个|那个|就是|然后|其实|所以|什么)\1+"#, with: "$1")
        if TranslationLanguageResolver.normalizedLanguage(sourceLanguage) == "en" {
            replace(#"(?:^|(?<=\s))[Uu](?:m+|h+),\s*"#, with: "")
        }
        // Deletions can strand punctuation: leading commas, doubled commas.
        replace(#"(?m)^[，、,]\s*"#, with: "")
        replace(#"，{2,}"#, with: "，")
        replace(#",{2,}"#, with: ",")

        return text
    }

    /// Collapses spaces/tabs per line, keeps paragraph structure, and ensures
    /// terminal punctuation matched to the dominant script of the text.
    public static func cleaned(_ input: String) -> String {
        let lines = input
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }

        var collapsed = lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let last = collapsed.last else {
            return collapsed
        }

        let terminal: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "；", ";", ":", "："]
        if terminal.contains(last) {
            return collapsed
        }
        guard last.isLetter || last.isNumber else {
            return collapsed
        }

        let dominant = TranslationLanguageResolver.dominantLanguage(
            in: collapsed,
            candidates: ["zh", "en", "ja", "ko"]
        )
        collapsed += (dominant == "zh" || dominant == "ja") ? "。" : "."
        return collapsed
    }

    public static func bulleted(_ input: String) -> String {
        cleaned(input)
            .split(whereSeparator: { $0 == "，" || $0 == "\n" })
            .map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

    public static func glossaryHits(in texts: [String], glossary: [HotwordCandidate]) -> [String] {
        let hits = glossary
            .map(\.replacement)
            .filter { term in
                texts.contains { $0.localizedCaseInsensitiveContains(term) }
            }
        return Array(Set(hits)).sorted()
    }
}

/// Deterministic text similarity for retry-redictation detection. No model:
/// this feeds NEGATIVE feedback (hotword demotion), where a false positive is
/// worse than a miss — same philosophy as the filler rules.
public enum VeloraTextSimilarity {
    /// 1.0 = identical after normalization (lowercased, whitespace/punctuation
    /// stripped), 0.0 = nothing in common. Character-level Levenshtein.
    public static func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        let left = canonical(a)
        let right = canonical(b)
        if left.isEmpty && right.isEmpty {
            return 1
        }
        guard !left.isEmpty, !right.isEmpty else {
            return 0
        }
        let distance = levenshtein(left, right)
        return 1 - Double(distance) / Double(max(left.count, right.count))
    }

    static func canonical(_ text: String) -> [Character] {
        text.lowercased().filter { character in
            !character.isWhitespace && !character.isPunctuation && !character.isSymbol
        }
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Races an operation against a wall-clock deadline. Returns nil when the
/// deadline wins; the operation task is cancelled. Errors thrown by the
/// operation before the deadline propagate to the caller.
public enum DeadlineRunner {
    public static func run<T: Sendable>(
        deadlineMS: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        guard deadlineMS > 0 else {
            return try await operation()
        }

        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadlineMS) * 1_000_000)
                return nil
            }

            defer {
                group.cancelAll()
            }
            return try await group.next() ?? nil
        }
    }
}
