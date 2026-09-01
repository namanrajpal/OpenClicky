//
//  StreamingSentenceSplitter.swift
//  leanring-buddy
//
//  Incrementally splits streaming response text into complete sentences so
//  TTS can start speaking sentence one while the rest is still arriving.
//  Holds back any text that might be the start of an annotation tag
//  ("[POINT:..." arriving across chunks) so tags are never spoken or shown.
//
//  PORTABLE CORE: Foundation only.
//

import Foundation

struct StreamingSentenceSplitter {
    private var pendingText = ""

    /// Appends a chunk and returns any sentences completed by it.
    mutating func ingestChunk(_ chunkText: String) -> [String] {
        pendingText += chunkText

        let safeText = Self.textWithoutTrailingPartialTag(pendingText)

        var completedSentences: [String] = []
        var consumedUpTo = safeText.startIndex
        var searchIndex = safeText.startIndex

        while searchIndex < safeText.endIndex {
            let character = safeText[searchIndex]
            let nextIndex = safeText.index(after: searchIndex)

            let isTerminator = character == "." || character == "!" || character == "?" || character == "\n"
            // Require whitespace after ./!/? so "4.5" and "e.g." mid-number
            // splits are avoided. Newlines always terminate.
            let isFollowedByWhitespace = nextIndex < safeText.endIndex
                && safeText[nextIndex].isWhitespace

            if isTerminator && (character == "\n" || isFollowedByWhitespace) {
                let sentence = String(safeText[consumedUpTo..<nextIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.count > 1 {
                    completedSentences.append(sentence)
                }
                consumedUpTo = nextIndex
            }
            searchIndex = nextIndex
        }

        // safeText is a prefix of pendingText, so this offset maps directly.
        let consumedCount = safeText.distance(from: safeText.startIndex, to: consumedUpTo)
        pendingText.removeFirst(consumedCount)

        return completedSentences
    }

    /// Returns the unconsumed remainder with any annotation tag stripped.
    /// Call once when the stream ends; resets the splitter.
    mutating func flushRemainder() -> String? {
        var remainder = pendingText
        pendingText = ""

        // Strip a complete or partial [ ... tag at the end.
        if let bracketIndex = remainder.lastIndex(of: "[") {
            let afterBracket = remainder[remainder.index(after: bracketIndex)...]
            if afterBracket.uppercased().hasPrefix("POINT") || !afterBracket.contains("]") {
                remainder = String(remainder[..<bracketIndex])
            }
        }

        let trimmedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedRemainder.count > 1 ? trimmedRemainder : nil
    }

    mutating func reset() {
        pendingText = ""
    }

    /// The prefix of `text` that is safe to display or speak: everything up
    /// to a trailing '[' that has not been closed yet (a tag may be arriving).
    static func textWithoutTrailingPartialTag(_ text: String) -> String {
        guard let lastOpenBracket = text.lastIndex(of: "[") else { return text }
        let afterBracket = text[text.index(after: lastOpenBracket)...]
        if afterBracket.contains("]") {
            // The bracket closed; strip a completed POINT tag from display.
            return text.replacingOccurrences(
                of: #"\[POINT:[^\]]*\]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return String(text[..<lastOpenBracket])
    }
}
