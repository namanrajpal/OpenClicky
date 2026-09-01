//
//  CloudSentenceTTSClient.swift
//  leanring-buddy
//
//  High-quality cloud text-to-speech behind the same per-sentence surface
//  as LocalSpeechSynthesizerTTSClient. Two providers, verified live:
//    - Cartesia Sonic  (POST api.cartesia.ai/tts/bytes, ~0.7s per sentence)
//    - Deepgram Aura   (POST api.deepgram.com/v1/speak,  ~1.8s per sentence)
//
//  Design:
//  - Sentences are numbered as they arrive. Each starts an audio fetch
//    immediately (fetches run concurrently), and clips play strictly in
//    order, so per-sentence pipelining is preserved: sentence one plays
//    while later sentences are still being fetched or generated.
//  - Any sentence whose fetch fails falls back to the on-device
//    AVSpeechSynthesizer for that sentence only, keeping order. No network,
//    no keys, or a dead provider all degrade to the local voice.
//  - API keys come from EnvFileLoader (.env at the repo root). They are
//    never logged.
//
//  Configuration (.env or process environment):
//    DEEPGRAM_KEY / DEEPGRAM_API_KEY        Deepgram key
//    CARTERSIA_KEY / CARTESIA_KEY /
//    CARTESIA_API_KEY                       Cartesia key
//    OPENCLICKY_TTS_PROVIDER                "cartesia" | "deepgram" | "local"
//                                           (default: cartesia if its key
//                                           exists, else deepgram, else local)
//    CARTESIA_VOICE_ID                      voice UUID (default barbershop man)
//    DEEPGRAM_TTS_MODEL                     model id (default aura-2-thalia-en)
//

import AVFoundation
import Foundation

// MARK: - Common TTS surface

/// The per-sentence TTS surface CompanionManager's pipeline drives.
@MainActor
protocol SentenceTTSClient: AnyObject {
    /// Enqueues one sentence; playback is pipelined and strictly ordered.
    func enqueueSentence(_ sentenceText: String)
    /// True while anything is playing or queued. Polled to schedule the
    /// transient cursor fade-out after a response finishes.
    var isPlaying: Bool { get }
    /// Stops playback and drops the queue (user interrupted).
    func stopPlayback()
}

extension LocalSpeechSynthesizerTTSClient: SentenceTTSClient {}

// MARK: - Cloud client

@MainActor
final class CloudSentenceTTSClient: NSObject, SentenceTTSClient {

    enum Provider {
        case cartesia(apiKey: String, voiceID: String)
        case deepgram(apiKey: String, model: String)

        var displayName: String {
            switch self {
            case .cartesia: return "cartesia"
            case .deepgram: return "deepgram"
            }
        }
    }

    /// Picks the best available TTS client: cloud when a key is configured,
    /// the on-device synthesizer otherwise. OPENCLICKY_TTS_PROVIDER forces
    /// a specific choice.
    static func makeDefaultTTSClient() -> any SentenceTTSClient {
        let forcedProvider = EnvFileLoader.value(forAnyOf: ["OPENCLICKY_TTS_PROVIDER"])?.lowercased()
        if forcedProvider == "local" {
            print("🔊 TTS: local voice (forced by OPENCLICKY_TTS_PROVIDER)")
            return LocalSpeechSynthesizerTTSClient()
        }

        let cartesiaKey = EnvFileLoader.value(forAnyOf: ["CARTERSIA_KEY", "CARTESIA_KEY", "CARTESIA_API_KEY"])
        let deepgramKey = EnvFileLoader.value(forAnyOf: ["DEEPGRAM_KEY", "DEEPGRAM_API_KEY"])

        if forcedProvider != "deepgram", let cartesiaKey {
            let voiceID = EnvFileLoader.value(forAnyOf: ["CARTESIA_VOICE_ID"])
                ?? "a0e99841-438c-4a64-b679-ae501e7d6091"
            print("🔊 TTS: cartesia (voice \(voiceID))")
            return CloudSentenceTTSClient(provider: .cartesia(apiKey: cartesiaKey, voiceID: voiceID))
        }
        if let deepgramKey {
            let model = EnvFileLoader.value(forAnyOf: ["DEEPGRAM_TTS_MODEL"]) ?? "aura-2-thalia-en"
            print("🔊 TTS: deepgram (model \(model))")
            return CloudSentenceTTSClient(provider: .deepgram(apiKey: deepgramKey, model: model))
        }

        print("🔊 TTS: local voice (no cloud TTS keys found)")
        return LocalSpeechSynthesizerTTSClient()
    }

    // MARK: State

    private let provider: Provider

    /// On-device synthesizer used per sentence when a cloud fetch fails.
    private let fallbackSynthesizer = LocalSpeechSynthesizerTTSClient()

    /// A queued sentence's playable form once its fetch resolves.
    private enum QueueItem {
        case audioClip(Data)
        case fallbackSentence(String)
    }

    private var nextEnqueueIndex = 0
    private var nextPlayIndex = 0
    private var readyItems: [Int: QueueItem] = [:]
    private var fetchTasks: [Int: Task<Void, Never>] = [:]
    private var audioPlayer: AVAudioPlayer?
    private var isOutputting = false

    /// Bumped by stopPlayback so late-resolving fetches from a cancelled
    /// response can't inject audio into the next one.
    private var playbackGeneration = 0

    init(provider: Provider) {
        self.provider = provider
        super.init()
    }

    // MARK: SentenceTTSClient

    func enqueueSentence(_ sentenceText: String) {
        let trimmedSentence = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentence.isEmpty else { return }

        let itemIndex = nextEnqueueIndex
        nextEnqueueIndex += 1
        let generation = playbackGeneration
        let provider = self.provider

        fetchTasks[itemIndex] = Task { [weak self] in
            var queueItem: QueueItem
            do {
                let audioData = try await Self.fetchAudio(for: trimmedSentence, provider: provider)
                queueItem = .audioClip(audioData)
            } catch {
                print("⚠️ TTS: \(provider.displayName) fetch failed (\(error.localizedDescription)), falling back to local voice for this sentence")
                queueItem = .fallbackSentence(trimmedSentence)
            }
            guard let self, self.playbackGeneration == generation, !Task.isCancelled else { return }
            self.fetchTasks.removeValue(forKey: itemIndex)
            self.readyItems[itemIndex] = queueItem
            self.playNextIfReady()
        }
    }

    var isPlaying: Bool {
        isOutputting || nextPlayIndex < nextEnqueueIndex
    }

    func stopPlayback() {
        playbackGeneration += 1
        for (_, task) in fetchTasks { task.cancel() }
        fetchTasks.removeAll()
        readyItems.removeAll()
        nextEnqueueIndex = 0
        nextPlayIndex = 0
        isOutputting = false
        audioPlayer?.stop()
        audioPlayer = nil
        fallbackSynthesizer.stopPlayback()
    }

    // MARK: Ordered playback

    private func playNextIfReady() {
        guard !isOutputting, let queueItem = readyItems.removeValue(forKey: nextPlayIndex) else { return }
        let generation = playbackGeneration
        isOutputting = true
        nextPlayIndex += 1

        switch queueItem {
        case .audioClip(let audioData):
            do {
                let player = try AVAudioPlayer(data: audioData)
                player.delegate = self
                audioPlayer = player
                player.play()
            } catch {
                print("⚠️ TTS: could not play fetched audio (\(error.localizedDescription))")
                finishCurrentItem(inGeneration: generation)
            }

        case .fallbackSentence(let sentenceText):
            fallbackSynthesizer.enqueueSentence(sentenceText)
            // AVSpeechSynthesizer has no per-utterance completion surface
            // here, so poll until it goes quiet, then advance the queue.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                while let self, self.playbackGeneration == generation, self.fallbackSynthesizer.isPlaying {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let self else { return }
                self.finishCurrentItem(inGeneration: generation)
            }
        }
    }

    private func finishCurrentItem(inGeneration generation: Int) {
        guard playbackGeneration == generation else { return }
        isOutputting = false
        audioPlayer = nil
        playNextIfReady()
    }

    // MARK: Provider requests

    /// Fetches one sentence's audio (MP3 bytes) from the configured provider.
    private nonisolated static func fetchAudio(for sentenceText: String, provider: Provider) async throws -> Data {
        var request: URLRequest
        switch provider {
        case .cartesia(let apiKey, let voiceID):
            request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("2025-04-16", forHTTPHeaderField: "Cartesia-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model_id": "sonic-2",
                "transcript": sentenceText,
                "voice": ["mode": "id", "id": voiceID],
                "output_format": ["container": "mp3", "bit_rate": 128_000, "sample_rate": 44_100],
            ])

        case .deepgram(let apiKey, let model):
            var urlComponents = URLComponents(string: "https://api.deepgram.com/v1/speak")!
            urlComponents.queryItems = [URLQueryItem(name: "model", value: model)]
            request = URLRequest(url: urlComponents.url!)
            request.httpMethod = "POST"
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": sentenceText])
        }
        request.timeoutInterval = 10

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "CloudSentenceTTSClient", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(provider.displayName) returned HTTP \(statusCode)",
            ])
        }
        return responseData
    }
}

// MARK: - AVAudioPlayerDelegate

extension CloudSentenceTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishCurrentItem(inGeneration: self.playbackGeneration)
        }
    }
}
