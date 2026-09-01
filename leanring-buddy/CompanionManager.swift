//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// On-device text-to-speech for spoken responses. Replaced the ElevenLabs
    /// cloud TTS client in M0 so responses are spoken with zero network
    /// dependency. May be upgraded to a higher-quality local engine in M3.
    private let localTTSClient = LocalSpeechSynthesizerTTSClient()

    /// The local agent (kiro-cli in ACP mode) that generates responses.
    /// Replaced the M0 placeholder and the upstream ClaudeAPI + worker seam.
    let acpAgentClient = ACPAgentClient()

    /// Accessibility-tree extraction for the frontmost app (M2): exact
    /// element coordinates for local pointing plus compact agent context.
    private let axTreeProvider = AXTreeProvider()

    /// Cursor-following streaming text bubble for responses (UX baseline D1:
    /// text is the primary record; audio is a preference).
    private let responseTextOverlayManager = CompanionResponseOverlayManager()

    // MARK: - Response Modality (UX baseline D2, layer 1)

    enum ResponseModalityPreference: String, CaseIterable {
        case voiceAndText
        case textOnly
        case voiceOnly

        var displayLabel: String {
            switch self {
            case .voiceAndText: return "Voice + Text"
            case .textOnly: return "Text only"
            case .voiceOnly: return "Voice only"
            }
        }
    }

    /// How responses are delivered. Persisted to UserDefaults.
    @Published var responseModality: ResponseModalityPreference =
        ResponseModalityPreference(rawValue: UserDefaults.standard.string(forKey: "responseModality") ?? "") ?? .voiceAndText

    func setResponseModality(_ modality: ResponseModalityPreference) {
        responseModality = modality
        UserDefaults.standard.set(modality.rawValue, forKey: "responseModality")
    }

    var isTextResponseEnabled: Bool { responseModality != .voiceOnly }
    var isVoiceResponseEnabled: Bool { responseModality != .textOnly }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Warm up the agent subprocess in the background so the first
        // push-to-talk doesn't pay the spawn + handshake cost.
        acpAgentClient.instructionBlock = Self.acpInstructionBlock
        Task { await acpAgentClient.start() }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true


        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        responseTextOverlayManager.hideOverlay()
        acpAgentClient.stop()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            acpAgentClient.cancelActivePrompt()
            localTTSClient.stopPlayback()
            responseTextOverlayManager.hideOverlay()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    


            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.respondToTranscriptWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Instructions prepended to the FIRST prompt of each agent session (ACP
    /// has no system-prompt parameter). The persistent session remembers them
    /// for every later turn. Adapted from the upstream voice system prompt.
    private static let acpInstructionBlock = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar on their mac. the user speaks to you via push-to-talk and you can see their screen. your reply may be spoken aloud via text-to-speech and shown as text next to their cursor. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - IMPORTANT: never use tools. answer directly from the message, the images, and the context you're given. tool permission requests will be rejected.
    - default to one or two sentences. be direct and dense. if the user asks you to explain more or go deeper, give a thorough explanation.
    - all lowercase, casual, warm. no emojis. no markdown, no lists, no formatting — just natural speech, short sentences.
    - don't use abbreviations that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see. if the screenshot isn't relevant, just answer the question.
    - never say "simply" or "just". don't read code verbatim — describe it conversationally.
    - a [context] section may follow the user's words with image labels and a list of accessibility elements from the frontmost app. use the element names to be precise about what's on screen.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. point whenever it would genuinely help — finding a menu, a button, navigating an app. don't point for general knowledge questions.

    when you point, append a coordinate tag at the very end of your response, after your spoken text. the screenshot images are labeled with their pixel dimensions — your coordinates MUST be integer pixel coordinates in that image's coordinate space, origin top-left. the accessibility element coordinates in [context] are a different coordinate space; use them only to identify elements by name, never copy them into the tag.

    format: [POINT:x,y:label] where label is a short 1-3 word description. if the element is on a different screen than the cursor, append :screenN using the screen number from the image label. if pointing wouldn't help, append [POINT:none].

    examples:
    - "you'll want the color inspector — top right of the toolbar. [POINT:1100,42:color inspector]"
    - "html is the skeleton of every web page. [POINT:none]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, generates a response for the transcript, and
    /// plays the response aloud via on-device TTS. The cursor stays in the
    /// spinner/processing state until speech begins. The response may include
    /// a [POINT:x,y:label] tag which triggers the buddy to fly to that
    /// element on screen.
    ///
    /// M0: the response comes from PlaceholderResponseGenerator (local,
    /// deterministic). M1 replaces that seam with ACPAgentClient so a local
    /// agent produces real answers from the transcript + screenshots.
    private func respondToTranscriptWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        localTTSClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing

            // M2 router: element-location questions ("where is the save
            // button") are answered from the accessibility tree in ~100ms
            // with exact coordinates, never touching the agent.
            let axSnapshot = axTreeProvider.snapshotFrontmostApplication()
            if let axSnapshot,
               case .answerLocally(let spokenText, let element) = QuestionRouter.route(
                   transcript: transcript,
                   screenElements: axSnapshot.elements
               ) {
                deliverLocalPointingAnswer(spokenText: spokenText, element: element, transcript: transcript)
                return
            }

            do {
                // M2 capture discipline: active display only, downscaled.
                // Less of the screen leaves the machine, smaller agent payload.
                let screenCaptures = try await CompanionScreenCaptureUtility.captureScreensAsJPEG(activeDisplayOnly: true)

                guard !Task.isCancelled else { return }

                // Pre-digest context for the agent: image labels with pixel
                // dimensions (the POINT coordinate space) plus the compact
                // accessibility summary so it can name elements precisely.
                let imageLabelLines = screenCaptures.map { capture in
                    "image: \(capture.label) (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                }
                var promptText = transcript + "\n\n[context]\n" + imageLabelLines.joined(separator: "\n")
                if let axSnapshot {
                    promptText += "\n\naccessibility elements on the frontmost app (names are reliable; coordinates are for reference only, never for POINT tags):\n"
                        + String(axSnapshot.compactSummary.prefix(3000))
                }

                let promptImages = screenCaptures.map { capture in
                    ACPPromptImage(base64Data: capture.imageData.base64EncodedString(), mimeType: "image/jpeg")
                }

                // Stream the response: text renders progressively in the
                // cursor bubble, and completed sentences are spoken while the
                // rest is still arriving (per-sentence TTS pipelining).
                var sentenceSplitter = StreamingSentenceSplitter()
                var accumulatedResponseText = ""
                var hasStartedDelivering = false

                let fullResponseText = try await acpAgentClient.sendPrompt(
                    text: promptText,
                    images: promptImages
                ) { [weak self] chunkText in
                    guard let self, !Task.isCancelled else { return }
                    accumulatedResponseText += chunkText

                    if !hasStartedDelivering {
                        hasStartedDelivering = true
                        self.voiceState = .responding
                        if self.isTextResponseEnabled {
                            self.responseTextOverlayManager.showOverlayAndBeginStreaming()
                        }
                    }
                    if self.isTextResponseEnabled {
                        self.responseTextOverlayManager.updateStreamingText(
                            StreamingSentenceSplitter.textWithoutTrailingPartialTag(accumulatedResponseText)
                        )
                    }
                    if self.isVoiceResponseEnabled {
                        for completedSentence in sentenceSplitter.ingestChunk(chunkText) {
                            self.localTTSClient.enqueueSentence(completedSentence)
                        }
                    }
                }

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from the full response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Speak whatever the sentence splitter is still holding.
                if isVoiceResponseEnabled, let remainderText = sentenceSplitter.flushRemainder() {
                    localTTSClient.enqueueSentence(remainderText)
                }
                // Settle the bubble on the final tag-free text, then let it
                // auto-hide a few seconds later.
                if isTextResponseEnabled && hasStartedDelivering {
                    responseTextOverlayManager.updateStreamingText(spokenText)
                    responseTextOverlayManager.finishStreaming()
                }

                // Handle element pointing if the agent returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching the agent's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // The agent's coordinates are in the screenshot's pixel
                    // space (top-left origin, e.g. 1280x831). Scale to the
                    // display's point space, then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                appendToConversationHistory(userTranscript: transcript, assistantResponse: spokenText)
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                deliverErrorResponse(error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Delivers a router-answered element-location response: exact-coordinate
    /// pointing plus text/speech per the modality preference. No agent, no
    /// capture, no network — this is the ~100ms path.
    private func deliverLocalPointingAnswer(
        spokenText: String,
        element: RoutableScreenElement,
        transcript: String
    ) {
        print("🎯 Router: local answer, pointing at \"\(element.title)\" at \(element.centerPoint)")

        // Idle first so the triangle is visible for the flight animation.
        voiceState = .idle

        // The pointer bubble carries the answer (UX baseline D3).
        detectedElementBubbleText = spokenText
        detectedElementScreenLocation = element.centerPoint
        detectedElementDisplayFrame = element.displayFrame

        if isVoiceResponseEnabled {
            localTTSClient.enqueueSentence(spokenText)
        }

        appendToConversationHistory(userTranscript: transcript, assistantResponse: spokenText)
        scheduleTransientHideIfNeeded()
    }

    /// Shows and/or speaks a pipeline error per the modality preference. The
    /// bubble gets the specific reason (readable, actionable); speech gets a
    /// short generic line.
    private func deliverErrorResponse(_ error: Error) {
        if isTextResponseEnabled {
            responseTextOverlayManager.showOverlayAndBeginStreaming()
            responseTextOverlayManager.updateStreamingText("hmm, that didn't work: \(error.localizedDescription)")
            responseTextOverlayManager.finishStreaming()
        }
        if isVoiceResponseEnabled {
            localTTSClient.enqueueSentence("something went wrong while answering. try asking again.")
        }
        voiceState = .responding
    }

    private func appendToConversationHistory(userTranscript: String, assistantResponse: String) {
        conversationHistory.append((userTranscript: userTranscript, assistantResponse: assistantResponse))
        // Keep only the last 10 exchanges to avoid unbounded growth. (The
        // agent session holds its own history; this copy exists for a future
        // transcript view.)
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while localTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Onboarding demo where the buddy finds something interesting on screen
    /// and flies to it while the intro video plays.
    ///
    /// M0: DISABLED. Upstream this asked Claude (via the removed worker proxy)
    /// to pick an element and comment on it. It needs a vision-capable brain,
    /// which arrives with ACPAgentClient in M1 — re-enable it then by routing
    /// onboardingDemoSystemPrompt through the agent and reusing the
    /// coordinate-mapping path in respondToTranscriptWithScreenshot.
    func performOnboardingDemoInteraction() {
        print("🎯 Onboarding demo: skipped — requires the ACP agent (M1)")
    }
}
