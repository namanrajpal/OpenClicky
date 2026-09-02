//
//  CoreLogicTests.swift
//  OpenClickyTests
//
//  Tests for the portable core: the deterministic question router and the
//  streaming sentence splitter. These are pure logic (no AppKit, no agent),
//  so they run fast and need no permissions.
//

import CoreGraphics
import Testing
@testable import OpenClicky

struct QuestionRouterTests {

    private let saveButton = RoutableScreenElement(
        role: "button", title: "Save", centerPoint: CGPoint(x: 100, y: 200), displayFrame: .zero)
    private let openRecentButton = RoutableScreenElement(
        role: "button", title: "Open Recent", centerPoint: CGPoint(x: 50, y: 60), displayFrame: .zero)

    @Test func locateQuestionWithKnownElementAnswersLocally() {
        let routedResponse = QuestionRouter.route(
            transcript: "where is the save button?",
            screenElements: [saveButton, openRecentButton]
        )
        guard case .answerLocally(_, let matchedElement) = routedResponse else {
            Issue.record("expected a local answer")
            return
        }
        #expect(matchedElement.title == "Save")
    }

    @Test func reasoningQuestionDelegatesToAgent() {
        let routedResponse = QuestionRouter.route(
            transcript: "why is my build failing?",
            screenElements: [saveButton, openRecentButton]
        )
        guard case .delegateToAgent = routedResponse else {
            Issue.record("expected delegation to the agent")
            return
        }
    }

    @Test func unknownElementDelegatesToAgent() {
        let routedResponse = QuestionRouter.route(
            transcript: "where is the flux capacitor",
            screenElements: [saveButton, openRecentButton]
        )
        guard case .delegateToAgent = routedResponse else {
            Issue.record("expected delegation: no matching element")
            return
        }
    }

    @Test func tiedMatchesDelegateInsteadOfGuessing() {
        let ambiguousElements = [
            RoutableScreenElement(role: "button", title: "Save", centerPoint: .zero, displayFrame: .zero),
            RoutableScreenElement(role: "menuitem", title: "Save", centerPoint: .zero, displayFrame: .zero),
        ]
        let routedResponse = QuestionRouter.route(
            transcript: "where is save",
            screenElements: ambiguousElements
        )
        guard case .delegateToAgent = routedResponse else {
            Issue.record("expected delegation on ambiguous match")
            return
        }
    }

    @Test func targetPhraseExtractionStripsMarkerAndPunctuation() {
        #expect(QuestionRouter.extractLocateTargetPhrase(from: "where's the color inspector?") == "color inspector")
    }

    @Test func longTranscriptsAreNeverRoutedLocally() {
        let longTranscript = "so i was wondering where is the thing that my coworker mentioned in the meeting yesterday about the report"
        #expect(QuestionRouter.extractLocateTargetPhrase(from: longTranscript) == nil)
    }
}

struct StreamingSentenceSplitterTests {

    @Test func sentencesSplitAcrossChunksAndTagIsHeldBack() {
        var sentenceSplitter = StreamingSentenceSplitter()
        var completedSentences: [String] = []
        for chunkText in ["hel", "lo there. this is ", "sentence two! and", " a tail [POI", "NT:none]"] {
            completedSentences += sentenceSplitter.ingestChunk(chunkText)
        }
        let remainderText = sentenceSplitter.flushRemainder()

        #expect(completedSentences == ["hello there.", "this is sentence two!"])
        #expect(remainderText == "and a tail")
    }

    @Test func decimalNumbersDoNotSplitSentences() {
        var sentenceSplitter = StreamingSentenceSplitter()
        let completedSentences = sentenceSplitter.ingestChunk("version 4.5 is out. nice. ")
        #expect(completedSentences.contains("version 4.5 is out."))
    }

    @Test func completedPointTagIsStrippedFromDisplayText() {
        let displayText = StreamingSentenceSplitter.textWithoutTrailingPartialTag(
            "look here [POINT:10,20:save button]")
        #expect(displayText == "look here ")
    }

    @Test func partialTagIsHeldBackFromDisplayText() {
        let displayText = StreamingSentenceSplitter.textWithoutTrailingPartialTag("look here [POIN")
        #expect(displayText == "look here ")
    }
}
