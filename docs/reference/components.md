# OpenClicky Components and Internal APIs

All Swift symbols currently use the app module's default `internal` access unless noted otherwise. The folder layout records ownership and dependency direction inside the single Xcode target.

## Source map

```text
OpenClicky/
├── App/
│   ├── OpenClickyApp.swift
│   └── CompanionManager.swift
├── Core/
│   ├── Routing/QuestionRouter.swift
│   └── Streaming/StreamingSentenceSplitter.swift
├── Features/
│   ├── VoiceInteraction/
│   │   ├── BuddyDictationManager.swift
│   │   └── BuddyTranscriptionProvider.swift
│   ├── CursorOverlay/
│   │   ├── OverlayWindow.swift
│   │   ├── CompanionResponseOverlay.swift
│   │   └── LassoRegionSelectionController.swift
│   └── MenuBar/
│       ├── MenuBarPanelManager.swift
│       └── CompanionPanelView.swift
├── Platform/
│   ├── Accessibility/AXTreeProvider.swift
│   ├── ScreenCapture/CompanionScreenCaptureUtility.swift
│   ├── Speech/
│   │   ├── AppleSpeechTranscriptionProvider.swift
│   │   ├── LocalSpeechSynthesizerTTSClient.swift
│   │   ├── CloudSentenceTTSClient.swift
│   │   └── BuddyAudioConversionSupport.swift
│   ├── Shortcuts/GlobalPushToTalkShortcutMonitor.swift
│   └── Permissions/WindowPositionManager.swift
├── Infrastructure/
│   ├── Agent/ACPAgentClient.swift
│   └── Configuration/
│       ├── EnvFileLoader.swift
│       └── AppBundleConfiguration.swift
├── DesignSystem/DesignSystem.swift
├── Resources/Assets.xcassets
├── Info.plist
└── OpenClicky.entitlements
```

## App composition

| Component | Primary surface | Responsibility |
|---|---|---|
| `App/OpenClickyApp.swift` | SwiftUI app lifecycle | Creates `CompanionManager` and `MenuBarPanelManager`; registers tooltip defaults |
| `App/CompanionManager.swift` | `start()`, onboarding and permission actions, published UI state | Central voice state machine, routing, capture, ACP streaming, modality, pointing, cancellation, and history copy |

`CompanionManager` remains the central coordinator. Its future split should move deterministic orchestration into Core while App retains observable macOS presentation state and adapter composition.

## Core algorithms

### `Core/Routing/QuestionRouter.swift`

| Member | Purpose |
|---|---|
| `route(transcript:screenElements:) -> RoutedResponse` | Choose an exact local locate answer or agent delegation |
| `extractLocateTargetPhrase(from:)` | Parse a short locate request |
| `matchScore(targetPhrase:elementTitle:)` | Score exact, containment, and word-overlap matches |

`RoutableScreenElement` currently carries CoreGraphics geometry in AppKit-global coordinates. Replace that geometry with platform-neutral values before extracting a cross-platform package.

### `Core/Streaming/StreamingSentenceSplitter.swift`

| Member | Purpose |
|---|---|
| `ingestChunk(_:) -> [String]` | Add streamed text and return newly completed sentences |
| `flushRemainder() -> String?` | Return final buffered text at turn completion |
| `reset()` | Clear buffered state |
| `textWithoutTrailingPartialTag(_:)` | Hide incomplete response tags from the text overlay |

## Features

| Feature | Components | Responsibility |
|---|---|---|
| Voice interaction | `BuddyDictationManager`, `BuddyTranscriptionProvider` | Push-to-talk session state, microphone levels, transcript finalization, provider contract |
| Cursor overlay | `OverlayWindow`, `CompanionResponseOverlay`, `LassoRegionSelectionController` | Buddy rendering, waveform, spinner, text bubbles, lasso, cursor flight, and pen circle |
| Menu bar | `MenuBarPanelManager`, `CompanionPanelView` | Status item, panel lifecycle, permissions UI, agent mode, response modality, and onboarding controls |

## Platform adapters

| Adapter | Responsibility |
|---|---|
| `Platform/Accessibility/AXTreeProvider.swift` | Bounded macOS Accessibility walk returning routable elements and names-only context |
| `Platform/ScreenCapture/CompanionScreenCaptureUtility.swift` | ScreenCaptureKit display and region JPEG capture with coordinate metadata |
| `Platform/Speech/AppleSpeechTranscriptionProvider.swift` | On-device `SFSpeechRecognizer` transcription |
| `Platform/Speech/LocalSpeechSynthesizerTTSClient.swift` | On-device AVSpeechSynthesizer output and cloud fallback |
| `Platform/Speech/CloudSentenceTTSClient.swift` | Optional Cartesia or Deepgram fetch, ordered playback, and local fallback |
| `Platform/Speech/BuddyAudioConversionSupport.swift` | PCM16 and WAV conversion support for upload-oriented providers |
| `Platform/Shortcuts/GlobalPushToTalkShortcutMonitor.swift` | Listen-only CGEvent tap for push-to-talk and copy shortcuts |
| `Platform/Permissions/WindowPositionManager.swift` | Accessibility and Screen Recording permission flows, settings migration, and display IDs |

## Infrastructure adapters

### `Infrastructure/Agent/ACPAgentClient.swift`

`@MainActor final class ACPAgentClient: ObservableObject`

| Member | Purpose |
|---|---|
| `start() async` | Locate and spawn `kiro-cli`, initialize ACP, and create a session |
| `stop()` | Tear down the process and reset connection state |
| `sendPrompt(text:images:onTextChunk:) async throws -> String` | Send text and image blocks, stream chunks, and return accumulated text |
| `cancelActivePrompt()` | Send ACP `session/cancel` |
| `setAgentMode(_:) async` | Switch persona through `session/set_mode` |
| `ensureAgentConfigInstalled()` | Create or refresh the managed agent JSON |

### Configuration

- `Infrastructure/Configuration/EnvFileLoader.swift` resolves process-environment and `.env` values.
- `Infrastructure/Configuration/AppBundleConfiguration.swift` reads app-bundle plist values.

## Design and resources

- `DesignSystem/DesignSystem.swift` owns color, typography, spacing, radius, animation, button, hover, cursor, and tooltip primitives.
- `Resources/` contains the asset catalog. `Info.plist` and `OpenClicky.entitlements` stay at the target root because Xcode build settings address them directly.

## Tests

| Test file | Coverage |
|---|---|
| `OpenClickyTests/CoreLogicTests.swift` | Question routing and streaming sentence splitting |
| `OpenClickyTests/OpenClickyTests.swift` | Permission presentation and legacy-key migration |
