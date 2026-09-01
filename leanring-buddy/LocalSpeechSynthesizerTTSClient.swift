//
//  LocalSpeechSynthesizerTTSClient.swift
//  leanring-buddy
//
//  On-device text-to-speech using AVSpeechSynthesizer. This is the M0
//  stopgap replacement for the ElevenLabs cloud TTS client — same call
//  surface (speakText / isPlaying / stopPlayback) so CompanionManager's
//  pipeline sequencing is unchanged. A higher-quality local TTS engine
//  may replace this in M3 if the system voice quality disappoints.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpeechSynthesizerTTSClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// Speaks `text` through the system speech synthesizer. Returns once
    /// speech has been enqueued and started — mirroring the ElevenLabs
    /// client, which returned once audio playback began. Callers poll
    /// `isPlaying` to know when speech has finished.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        enqueueSentence(text)
        print("🔊 Local TTS: speaking \(text.count) characters")
    }

    /// Enqueues one sentence for speech. AVSpeechSynthesizer queues
    /// utterances natively, so calling this per completed sentence while a
    /// response is still streaming gives pipelined speech: sentence one plays
    /// while the rest of the response is still being generated.
    func enqueueSentence(_ sentenceText: String) {
        let utterance = AVSpeechUtterance(string: sentenceText)
        // Use the enhanced system voice for the user's locale when available.
        // AVSpeechSynthesisVoice(language: nil) picks the user's default.
        utterance.voice = AVSpeechSynthesisVoice(language: nil)
        // Slightly slower than the default rate reads more naturally for
        // conversational responses.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        speechSynthesizer.speak(utterance)
    }

    /// Whether speech is currently being spoken. CompanionManager polls this
    /// to schedule the transient cursor fade-out after a response finishes.
    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately (user pressed push-to-talk
    /// again, interrupting the previous response).
    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
}
