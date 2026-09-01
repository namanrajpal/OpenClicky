//
//  BuddyTranscriptionProvider.swift
//  OpenClicky
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    /// Known provider identifiers for the VoiceTranscriptionProvider
    /// Info.plist key. M0 removed the cloud providers (AssemblyAI streaming,
    /// OpenAI upload) along with their proxy/key requirements — Apple Speech
    /// is fully on-device and needs no configuration. The plist-driven
    /// selection mechanism is kept so a future local provider (for example a
    /// whisper.cpp-backed one in M3) can slot in without touching call sites.
    private enum PreferredProvider: String {
        case appleSpeech = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        if preferredProvider == nil, let preferredProviderRawValue {
            print("⚠️ Transcription: unknown provider \"\(preferredProviderRawValue)\", using Apple Speech")
        }

        return AppleSpeechTranscriptionProvider()
    }
}
