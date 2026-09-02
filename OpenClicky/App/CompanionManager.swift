//
//  CompanionManager.swift
//  OpenClicky
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
    /// buddy should fly to and point at. Parsed from the active agent response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character next to the cursor during the
    /// onboarding instruction sequence (and its final call-to-action).
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Full-screen buddy overlays and the smaller cursor-following response
    // panel are managed separately because they have different lifecycles.

    /// Per-sentence TTS. Cloud (Cartesia/Deepgram, keys from .env) when
    /// configured, on-device AVSpeechSynthesizer otherwise. Failed cloud
    /// fetches fall back to the local voice per sentence.
    private let ttsClient: any SentenceTTSClient = CloudSentenceTTSClient.makeDefaultTTSClient()

    /// The local kiro-cli ACP process that generates streamed responses.
    let acpAgentClient = ACPAgentClient()

    /// Accessibility-tree extraction for the frontmost app (M2): exact
    /// element coordinates for local pointing plus compact agent context.
    private let axTreeProvider = AXTreeProvider()

    /// Cursor-following streaming text bubble for responses (UX baseline D1:
    /// text is the primary record; audio is a preference).
    private let responseTextOverlayManager = CompanionResponseOverlayManager()

    // MARK: - Lasso Region Selection (input-side drawing)

    /// Drag-to-select while holding push-to-talk: the lasso's bounding
    /// rectangle replaces the whole-display capture for that question.
    private let lassoSelectionController = LassoRegionSelectionController()

    /// Live lasso stroke in global AppKit coordinates, rendered by
    /// BlueCursorView while the user drags. Empty when no drag is happening.
    @Published var lassoStrokePoints: [CGPoint] = []

    /// The finished selection's bounding rect (global AppKit), consumed by
    /// the next response pipeline run and then cleared.
    private var pendingSelectedRegionRect: CGRect?

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

    /// Local copy of recent exchanges for clipboard and future transcript UI.
    /// The persistent ACP session owns the agent's actual conversation context.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var copyShortcutCancellable: AnyCancellable?
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
        WindowPositionManager.migrateScreenRecordingConfirmationKeyIfNeeded()
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Live lasso stroke updates flow into the published state the
        // overlay renders.
        lassoSelectionController.onLassoPathChanged = { [weak self] strokePoints in
            self?.lassoStrokePoints = strokePoints
        }

        // ctrl+option+C copies the last response text.
        copyShortcutCancellable = globalPushToTalkShortcutMonitor
            .copyResponseShortcutPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.copyLastResponseToClipboard()
            }

        // Warm up the agent subprocess in the background so the first
        // push-to-talk doesn't pay the spawn + handshake cost.
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
    /// the overlay so the welcome animation and instruction sequence play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button will not appear
        // on future launches; the cursor will auto-show instead.
        hasCompletedOnboarding = true

        // Recreate the overlay so isFirstAppearance triggers the welcome
        // animation and local instruction sequence.
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link by restarting the welcome animation and instruction sequence.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    // MARK: - Onboarding Instruction Sequence

    /// Lines streamed next to the cursor during first-run onboarding. The
    /// sequence is fully offline on the transparent overlay, and pressing the
    /// hotkey skips directly to a real interaction.
    /// The welcome bubble ("hey! i'm clicky") has already played when this
    /// sequence starts, so the lines pick up from there.
    private static let onboardingInstructionLines: [String] = [
        "i live in your menu bar and hang out by your cursor",
        "i can see your screen and answer questions about it",
        "i'll fly over and point at things to guide you",
        "hold control + option and introduce yourself",
    ]

    private var onboardingSequenceTask: Task<Void, Never>?

    /// Streams the instruction lines one after another in the prompt bubble:
    /// type in character-by-character, hold long enough to read, fade, next.
    /// The final call-to-action holds longer, then fades on its own.
    func startOnboardingInstructionSequence() {
        onboardingSequenceTask?.cancel()
        onboardingSequenceTask = Task { [weak self] in
            guard let self else { return }
            let lineCount = Self.onboardingInstructionLines.count
            for (lineIndex, instructionLine) in Self.onboardingInstructionLines.enumerated() {
                guard !Task.isCancelled else { return }
                await self.streamOnboardingLine(instructionLine)
                guard !Task.isCancelled else { return }

                let isFinalLine = lineIndex == lineCount - 1
                if isFinalLine {
                    // Leave the call-to-action up long enough to act on it.
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    guard !Task.isCancelled, self.showOnboardingPrompt else { return }
                    self.dismissOnboardingPrompt()
                } else {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    /// Cancels the sequence (user pressed push-to-talk or the app is
    /// stopping) and fades the bubble out.
    func cancelOnboardingInstructionSequence() {
        onboardingSequenceTask?.cancel()
        onboardingSequenceTask = nil
        if showOnboardingPrompt {
            dismissOnboardingPrompt()
        }
    }

    /// Types one line into the prompt bubble character-by-character.
    private func streamOnboardingLine(_ instructionLine: String) async {
        onboardingPromptText = ""
        showOnboardingPrompt = true
        withAnimation(.easeIn(duration: 0.3)) {
            onboardingPromptOpacity = 1.0
        }
        for character in instructionLine {
            guard !Task.isCancelled else { return }
            onboardingPromptText.append(character)
            try? await Task.sleep(nanoseconds: 28_000_000)
        }
    }

    private func dismissOnboardingPrompt() {
        withAnimation(.easeOut(duration: 0.3)) {
            onboardingPromptOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    // MARK: - Copy Last Response (ctrl+option+C)

    /// Copies the most recent assistant response text to the clipboard and
    /// flashes a confirmation next to the cursor.
    func copyLastResponseToClipboard() {
        guard let lastResponse = conversationHistory.last?.assistantResponse,
              !lastResponse.isEmpty else {
            showTransientCursorMessage("nothing to copy yet")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResponse, forType: .string)
        showTransientCursorMessage("copied to clipboard")
        print("📋 Copied last response (\(lastResponse.count) chars)")
    }

    /// Flashes a short message in the cursor prompt bubble. Skipped while
    /// the onboarding instruction sequence owns the bubble.
    private func showTransientCursorMessage(_ messageText: String) {
        guard onboardingSequenceTask == nil else { return }
        onboardingPromptText = messageText
        showOnboardingPrompt = true
        withAnimation(.easeIn(duration: 0.2)) {
            onboardingPromptOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard self.onboardingSequenceTask == nil else { return }
            self.dismissOnboardingPrompt()
        }
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        responseTextOverlayManager.hideOverlay()
        acpAgentClient.stop()
        cancelOnboardingInstructionSequence()
        _ = lassoSelectionController.end()
        copyShortcutCancellable?.cancel()
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
            ttsClient.stopPlayback()
            responseTextOverlayManager.hideOverlay()
            clearDetectedElementLocation()

            // Cancel the onboarding instruction sequence — the user is doing
            // the real thing now, which teaches better than reading about it.
            cancelOnboardingInstructionSequence()

            // Arm lasso region selection for the duration of the hold: the
            // overlay accepts mouse events so a click-drag draws a selection
            // instead of clicking through. Any previous selection is stale.
            pendingSelectedRegionRect = nil
            overlayWindowManager.setLassoInteractionEnabled(true)
            lassoSelectionController.begin()
    


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
            // Finish the lasso session: restore click-through and keep the
            // selection (if any) for the response that's about to run.
            pendingSelectedRegionRect = lassoSelectionController.end()
            overlayWindowManager.setLassoInteractionEnabled(false)
            if pendingSelectedRegionRect != nil {
                print("🫡 Lasso: selected region \(pendingSelectedRegionRect!)")
            }

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

    // clicky's instructions live in the openclicky kiro-cli agent config,
    // installed by ACPAgentClient.ensureAgentConfigInstalled(). See
    // docs/reference/kiro-cli.md.

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, generates a response for the transcript, and
    /// plays the response aloud via on-device TTS. The cursor stays in the
    /// spinner/processing state until speech begins. The response may include
    /// a [POINT:x,y:label] tag that triggers the buddy to fly to that
    /// element on screen.
    private func respondToTranscriptWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing

            // Consume any lasso selection made during the hold. A region
            // question is inherently visual, so the router is skipped and
            // the crop goes straight to the agent.
            let selectedRegionRect = pendingSelectedRegionRect
            pendingSelectedRegionRect = nil

            // M2 router: element-location questions ("where is the save
            // button") are answered from the accessibility tree in ~100ms
            // with exact coordinates, never touching the agent.
            let axSnapshot = axTreeProvider.snapshotFrontmostApplication()
            if selectedRegionRect == nil,
               let axSnapshot,
               case .answerLocally(let spokenText, let element) = QuestionRouter.route(
                   transcript: transcript,
                   screenElements: axSnapshot.elements
               ) {
                deliverLocalPointingAnswer(spokenText: spokenText, element: element, transcript: transcript)
                return
            }

            do {
                // M2 capture discipline: the lasso's bounding rect when the
                // user drew one, otherwise the active display, downscaled.
                let screenCaptures: [CompanionScreenCapture]
                if let selectedRegionRect {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureRegionAsJPEG(
                        globalRegionRect: selectedRegionRect
                    )
                } else {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureScreensAsJPEG(activeDisplayOnly: true)
                }

                guard !Task.isCancelled else { return }

                // Pre-digest context for the agent: image labels with pixel
                // dimensions (the POINT coordinate space) plus the compact
                // accessibility summary so it can name elements precisely.
                let imageLabelLines = screenCaptures.map { capture in
                    "image: \(capture.label) (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                }
                var promptText = transcript + "\n\n[context]\n" + imageLabelLines.joined(separator: "\n")
                if let axSnapshot {
                    promptText += "\n\naccessibility elements on the frontmost app (names of what's on screen):\n"
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
                            self.ttsClient.enqueueSentence(completedSentence)
                        }
                    }
                }

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from the full response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Speak whatever the sentence splitter is still holding.
                if isVoiceResponseEnabled, let remainderText = sentenceSplitter.flushRemainder() {
                    ttsClient.enqueueSentence(remainderText)
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
            ttsClient.enqueueSentence(spokenText)
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
            ttsClient.enqueueSentence("something went wrong while answering. try asking again.")
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
            while ttsClient.isPlaying {
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

    /// Result of parsing a [POINT:...] tag from the active agent response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the agent said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of an agent response.
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
}
