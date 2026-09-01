# OpenClicky Components and Internal APIs

All Swift symbols use the app module's default `internal` access unless noted otherwise. `Core/` is Foundation-only by design; the remaining files form the macOS shell.

## Source map

```text
OpenClicky/
├── Core/
│   ├── ACPAgentClient.swift
│   ├── EnvFileLoader.swift
│   ├── QuestionRouter.swift
│   └── StreamingSentenceSplitter.swift
├── OpenClickyApp.swift
├── CompanionManager.swift
├── BuddyDictationManager.swift
├── BuddyTranscriptionProvider.swift
├── AppleSpeechTranscriptionProvider.swift
├── BuddyAudioConversionSupport.swift
├── GlobalPushToTalkShortcutMonitor.swift
├── CompanionScreenCaptureUtility.swift
├── AXTreeProvider.swift
├── LassoRegionSelectionController.swift
├── LocalSpeechSynthesizerTTSClient.swift
├── CloudSentenceTTSClient.swift
├── OverlayWindow.swift
├── CompanionResponseOverlay.swift
├── MenuBarPanelManager.swift
├── CompanionPanelView.swift
├── WindowPositionManager.swift
├── DesignSystem.swift
└── AppBundleConfiguration.swift
```

## Application and orchestration

| Component | Primary surface | Responsibility |
|---|---|---|
| `OpenClickyApp` / `CompanionAppDelegate` | SwiftUI app lifecycle | Creates `CompanionManager` and `MenuBarPanelManager`; registers tooltip defaults |
| `CompanionManager` | `start()`, onboarding and permission actions, published UI state | Central voice state machine, routing, capture, ACP streaming, modality, pointing, cancellation, and history copy |
| `MenuBarPanelManager` | `showPanelOnLaunch()`, `togglePanel()` | `NSStatusItem`, custom panel lifecycle, placement, and outside-click dismissal |
| `CompanionPanelView` | SwiftUI `View` | Permission setup, agent mode picker, response modality, buddy visibility, onboarding, and quit controls |

`CompanionManager` owns the active request task. Its main pipeline method is private: `respondToTranscriptWithScreenshot(transcript:)`. The app exposes behavior through user actions and published state instead of a separate public service API.

## Portable core

### `ACPAgentClient`

`@MainActor final class ACPAgentClient: ObservableObject`

| Member | Purpose |
|---|---|
| `start() async` | Locate and spawn `kiro-cli`, initialize ACP, create a session |
| `stop()` | Tear down the process and reset connection state |
| `sendPrompt(text:images:onTextChunk:) async throws -> String` | Send text and image blocks, stream chunks, and return accumulated text |
| `cancelActivePrompt()` | Send ACP `session/cancel` |
| `setAgentMode(_:) async` | Switch persona through `session/set_mode` |
| `findAgentBinaryPath()` | Search supported CLI install paths |
| `ensureAgentConfigInstalled()` | Create or refresh the managed agent JSON |
| `connectionState` | `notStarted`, `launching`, `ready`, or `failed(reason:)` |
| `availableAgentModes`, `currentAgentModeID` | Panel picker state from `session/new` |

Supporting values: `ACPPromptImage`, `ACPAgentMode`, `ACPAgentConnectionState`, `ACPAgentClientError`.

### `QuestionRouter`

| Member | Purpose |
|---|---|
| `route(transcript:screenElements:) -> RoutedResponse` | Choose an exact local locate answer or agent delegation |
| `extractLocateTargetPhrase(from:)` | Parse a short locate request |
| `matchScore(targetPhrase:elementTitle:)` | Score exact, containment, and word-overlap matches |

`RoutableScreenElement` carries role, title, AppKit-global center point, and display frame. `RoutedResponse` is `.answerLocally(spokenText:element:)` or `.delegateToAgent`.

### `StreamingSentenceSplitter`

| Member | Purpose |
|---|---|
| `ingestChunk(_:) -> [String]` | Add streamed text and return newly completed sentences |
| `flushRemainder() -> String?` | Return final buffered text at turn completion |
| `reset()` | Clear buffered state |
| `textWithoutTrailingPartialTag(_:)` | Hide incomplete response tags from the text overlay |

### `EnvFileLoader`

`value(forAnyOf:)` returns the first configured non-empty value across process environment and candidate `.env` files. See [Configuration](configuration.md).

## Input and transcription

| Component | Primary surface | Responsibility |
|---|---|---|
| `GlobalPushToTalkShortcutMonitor` | `start()`, `stop()`, transition publishers | Listen-only `CGEvent` tap for Control+Option and copy shortcut |
| `BuddyDictationManager` | keyboard push-to-talk start/stop, published audio state | `AVAudioEngine`, session supersession, transcript finalization, microphone levels |
| `BuddyTranscriptionProvider` | provider and session protocols | Backend-neutral streaming transcription surface |
| `AppleSpeechTranscriptionProvider` | `makeStreamingSession(...)` | `SFSpeechRecognizer` implementation with on-device preference and final-result fallback |
| `BuddyAudioConversionSupport` | PCM16 and WAV helpers | Conversion support retained for upload-style transcription providers; inactive in the Apple Speech path |

Apple Speech is the only active transcription provider. `BuddyTranscriptionProviderFactory.resolveProvider()` currently resolves Apple Speech for every plist value.

## Capture, accessibility, and routing inputs

| Component | Primary surface | Responsibility |
|---|---|---|
| `CompanionScreenCaptureUtility` | full-screen, active-screen, and region JPEG capture | ScreenCaptureKit filters, downscaling, crop conversion, and capture metadata |
| `AXTreeProvider` | `snapshotFrontmostApplication()` | Bounded AX walk returning routable elements and names-only agent context |
| `LassoRegionSelectionController` | `begin()`, `end()`, `cancel()` | Consume drag events, publish stroke points, return a bounding rectangle |
| `WindowPositionManager` | permission checks and request destinations | Accessibility and screen-recording permission flow plus display helpers |

`CompanionScreenCapture` carries JPEG data, image label, cursor-screen flag, display size in points, actual screenshot size in pixels, and the AppKit-global frame represented by the image.

## Response output

| Component | Primary surface | Responsibility |
|---|---|---|
| `SentenceTTSClient` | `enqueueSentence`, `isPlaying`, `stopPlayback` | Common ordered sentence playback contract |
| `LocalSpeechSynthesizerTTSClient` | `AVSpeechSynthesizer` implementation | On-device speech and cloud failure fallback |
| `CloudSentenceTTSClient` | `makeDefaultTTSClient()` | Cartesia or Deepgram fetch, concurrent preparation, ordered playback, local fallback |
| `CompanionResponseOverlayManager` | show, update, finish, hide | Cursor-following streaming text panel and auto-hide timing |
| `OverlayWindowManager` | show/hide overlays and lasso interaction | One transparent overlay per display |
| `BlueCursorView` | SwiftUI view in `OverlayWindow.swift` | Cursor following, waveform, spinner, text bubbles, lasso path, Bezier flight, and pen circle |
| `PenCircleShape` | SwiftUI `Shape` | Seeded hand-drawn open-ring highlight |

## Design and configuration helpers

| Component | Responsibility |
|---|---|
| `DesignSystem` (`DS`) | Color, typography, spacing, radius, animation, button, hover, cursor, and tooltip primitives |
| `AppBundleConfiguration` | Read string values from the app bundle's `Info.plist` |

## Tests

| Test file | Coverage |
|---|---|
| `OpenClickyTests/CoreLogicTests.swift` | Question routing and streaming sentence splitting |
| `OpenClickyTests/OpenClickyTests.swift` | Permission presentation and legacy-key migration |

The empty UI-test target and its generated template tests were removed.
