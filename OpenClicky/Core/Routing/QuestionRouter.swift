//
//  QuestionRouter.swift
//  OpenClicky
//
//  Deterministic on-device router (M2). Decides whether a transcript can be
//  answered locally from the accessibility tree (about 100ms class: "where is
//  the save button") or must be delegated to the ACP agent. Rules only, per
//  the routing criteria: a small ML model is added later only if these rules
//  prove insufficient. When in doubt, delegate — a slow right answer beats a
//  fast wrong one.
//
//  PORTABLE CORE: no AppKit imports. CoreGraphics geometry types only.
//

import CoreGraphics
import Foundation

/// One interactable element extracted from the accessibility tree, in the
/// shape the router and pointing pipeline need. Coordinates are AppKit
/// global (bottom-left origin) so pointing can use them directly.
struct RoutableScreenElement {
    let role: String
    let title: String
    let centerPoint: CGPoint
    let displayFrame: CGRect
}

enum RoutedResponse {
    /// The router found the element locally: speak/show spokenText and fly
    /// the cursor to the element, with no agent round trip.
    case answerLocally(spokenText: String, element: RoutableScreenElement)
    /// The question needs the agent (reasoning, vision, or low confidence).
    case delegateToAgent
}

enum QuestionRouter {

    /// Phrases that mark a "locate an element" question. The target phrase is
    /// whatever follows the marker.
    private static let locateMarkers = [
        "where is the", "where is my", "where is",
        "where's the", "where's my", "where's",
        "where are the", "where are",
        "find the", "find my",
        "show me the", "show me where",
        "point at the", "point at", "point to the", "point to",
    ]

    /// Words stripped from the edges of an extracted target phrase.
    private static let strippableEdgeWords: Set<String> = [
        "the", "a", "an", "my", "button", "icon", "option", "menu", "tab", "field",
    ]

    static func route(
        transcript: String,
        screenElements: [RoutableScreenElement]
    ) -> RoutedResponse {
        guard !screenElements.isEmpty else { return .delegateToAgent }
        guard let targetPhrase = extractLocateTargetPhrase(from: transcript) else {
            return .delegateToAgent
        }

        // Score every element against the target phrase.
        var bestElement: RoutableScreenElement?
        var bestScore = 0
        var bestScoreIsTied = false

        for element in screenElements {
            let score = matchScore(targetPhrase: targetPhrase, elementTitle: element.title)
            if score > bestScore {
                bestScore = score
                bestElement = element
                bestScoreIsTied = false
            } else if score == bestScore && score > 0 {
                bestScoreIsTied = true
            }
        }

        // Only answer locally on a confident, unambiguous match.
        guard let matchedElement = bestElement, bestScore >= 2, !bestScoreIsTied else {
            return .delegateToAgent
        }

        let spokenText = "found it. \(matchedElement.title.lowercased()) is right here."
        return .answerLocally(spokenText: spokenText, element: matchedElement)
    }

    /// Extracts the element the user is asking about, or nil when the
    /// transcript is a general question the router should not handle.
    /// Locate questions are short by nature; long transcripts mean the user
    /// is explaining something and the agent should hear all of it.
    static func extractLocateTargetPhrase(from transcript: String) -> String? {
        let normalizedTranscript = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedTranscript.count <= 60 else { return nil }

        for marker in locateMarkers {
            guard let markerRange = normalizedTranscript.range(of: marker) else { continue }
            var targetPhrase = String(normalizedTranscript[markerRange.upperBound...])
            targetPhrase = targetPhrase.trimmingCharacters(in: .whitespaces)
            targetPhrase = targetPhrase.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,"))

            var targetWords = targetPhrase.split(separator: " ").map(String.init)
            while let firstWord = targetWords.first, strippableEdgeWords.contains(firstWord) {
                targetWords.removeFirst()
            }
            // Trailing "button"/"icon"/etc. is descriptive, keep one content word minimum.
            while targetWords.count > 1, let lastWord = targetWords.last, strippableEdgeWords.contains(lastWord) {
                targetWords.removeLast()
            }

            guard !targetWords.isEmpty, targetWords.count <= 6 else { return nil }
            return targetWords.joined(separator: " ")
        }

        return nil
    }

    /// 3 = exact title match, 2 = containment either way, 1 = majority word
    /// overlap, 0 = no match. Local answers require at least 2.
    static func matchScore(targetPhrase: String, elementTitle: String) -> Int {
        let normalizedTitle = elementTitle.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalizedTitle.count >= 2 else { return 0 }

        if normalizedTitle == targetPhrase { return 3 }
        if normalizedTitle.contains(targetPhrase) || targetPhrase.contains(normalizedTitle) {
            return 2
        }

        let targetWords = Set(targetPhrase.split(separator: " "))
        let titleWords = Set(normalizedTitle.split(separator: " "))
        guard !targetWords.isEmpty else { return 0 }
        let overlapCount = targetWords.intersection(titleWords).count
        return overlapCount * 2 >= targetWords.count && overlapCount > 0 ? 1 : 0
    }
}
