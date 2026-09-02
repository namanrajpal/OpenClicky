# OpenClicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app, rebuilt around local-first execution. Lives entirely in the macOS status bar (no dock
icon, no main window). Push-to-talk (ctrl+option) captures voice, transcribed
on-device by Apple Speech. A deterministic router (M2) answers element-location
questions locally from the accessibility tree in ~100ms with exact coordinates;
everything else goes to a local agent — kiro-cli spawned as a stdio JSON-RPC
subprocess speaking the Agent Client Protocol (ACP), with the active display
captured (downscaled JPEG) and a compact AX-tree summary attached as context.
Responses stream: text renders progressively in a cursor-following bubble while
completed sentences are spoken via on-device AVSpeechSynthesizer (per-sentence
TTS pipelining). Response modality (Voice + Text / Text only / Voice only) is a
user preference in the panel. A blue cursor overlay flies to and points at UI
elements referenced by `[POINT:x,y:label:screenN]` tags.

The app has no model-provider API keys, proxy server, analytics, or
auto-updater. The upstream Cloudflare Worker, PostHog, AssemblyAI,
ElevenLabs, OpenAI clients, Sparkle, and FormSpark email gate were removed in
M0. Optional Cartesia or Deepgram TTS uses keys supplied through local
configuration; each failed cloud sentence falls back to on-device speech.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: `Infrastructure/Agent/ACPAgentClient.swift` spawns `kiro-cli acp --agent openclicky` (stdio JSON-RPC, protocolVersion 1), streams `agent_message_chunk` updates, and sends screenshots as image content blocks. OpenClicky's instructions live in `~/.kiro/agents/openclicky.json`, self-installed by the app with `tools: []`, no MCP servers, and the pinned `claude-haiku-4.5` model. Wire protocol reference: `docs/reference/kiro-cli.md`.
- **Routing**: `Core/Routing/QuestionRouter.swift` — deterministic rules decide on-device vs agent. Element-location questions resolve locally against the AX tree (`Platform/Accessibility/AXTreeProvider.swift`); ambiguity or reasoning delegates to the agent.
- **Speech-to-Text**: Apple Speech (on-device) via the pluggable transcription-provider layer. Cloud providers (AssemblyAI, OpenAI) were removed in M0; a whisper.cpp-backed provider may be added in M3.
- **Text-to-Speech**: `SentenceTTSClient` receives completed sentences from `Core/Streaming/StreamingSentenceSplitter.swift`. `Platform/Speech/CloudSentenceTTSClient.swift` selects optional Cartesia or Deepgram output when configured and falls back per sentence to `Platform/Speech/LocalSpeechSynthesizerTTSClient.swift` / AVSpeechSynthesizer.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The response embeds `[POINT:x,y:label:screenN]` tags. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none (PostHog removed in M0)

### Key Architecture Decisions

**UX baseline**: `docs/UX-BASELINE.md` records the current interaction model, the response-modality rules, and the proposed baseline decisions (text-first output, three-layer modality control). Consult it before changing any user-facing behavior; update it when a Section 6 decision ships.

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Ordered cloud TTS with local fallback**: Cloud sentence fetches can run concurrently, but playback remains in enqueue order. `stopPlayback()` increments a generation counter so late fetches from an interrupted turn cannot enter the next response. A failed sentence uses AVSpeechSynthesizer without failing the remaining response.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `App/OpenClickyApp.swift` | ~69 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate`, which creates `MenuBarPanelManager` and starts `CompanionManager`. The app has no main window. |
| `App/CompanionManager.swift` | ~944 | Central state machine for dictation, shortcut monitoring, AX routing, screen capture, ACP streaming, response modality, TTS, overlays, lasso selection, interruption, and pointing. |
| `Features/MenuBar/MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `Features/MenuBar/CompanionPanelView.swift` | ~773 | SwiftUI menu-bar panel with status, permission setup, ACP agent-mode picker, response-modality control, cursor visibility, onboarding, and quit actions. Uses the `DS` design system. |
| `Features/CursorOverlay/OverlayWindow.swift` | ~978 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `Features/CursorOverlay/CompanionResponseOverlay.swift` | ~217 | Cursor-following streaming-text bubble for responses (revived in M1; was dead code upstream). Fed progressively from the ACP chunk stream. |
| `Platform/ScreenCapture/CompanionScreenCaptureUtility.swift` | ~233 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `Features/VoiceInteraction/BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `Features/VoiceInteraction/BuddyTranscriptionProvider.swift` | ~58 | Transcription provider protocol and factory. Apple Speech is the current implementation; the boundary supports future on-device providers. |
| `Platform/Speech/AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `Platform/Speech/LocalSpeechSynthesizerTTSClient.swift` | ~42 | On-device AVSpeechSynthesizer implementation of `SentenceTTSClient` and cloud fallback. |
| `Platform/Speech/CloudSentenceTTSClient.swift` | ~262 | Optional Cartesia/Deepgram per-sentence TTS with concurrent fetch, ordered playback, interruption generation, and local fallback. |
| `Infrastructure/Agent/ACPAgentClient.swift` | ~472 | External-process adapter: spawn kiro-cli, initialize/session-new handshake, streaming prompts with image blocks, cancellation, agent-mode switching, and permission-request rejection. |
| `Infrastructure/Configuration/EnvFileLoader.swift` | ~99 | Process-environment and source-relative `.env` lookup for optional TTS configuration. |
| `Core/Routing/QuestionRouter.swift` | ~138 | Deterministic routing rules. Platform-lean today; CoreGraphics geometry must be removed before cross-platform package extraction. |
| `Core/Streaming/StreamingSentenceSplitter.swift` | ~93 | Foundation-only streaming text segmentation and partial annotation holdback. |
| `Platform/Accessibility/AXTreeProvider.swift` | ~175 | Walks the frontmost app's accessibility tree: routable elements with exact AppKit-global coordinates plus a names-only summary for agent context. |
| `Features/CursorOverlay/LassoRegionSelectionController.swift` | ~109 | Consumes drag events while push-to-talk is held, publishes the drawn path, and returns a rectangular capture region. |
| `Platform/Speech/BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `Platform/Shortcuts/GlobalPushToTalkShortcutMonitor.swift` | ~152 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `DesignSystem/DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `Platform/Permissions/WindowPositionManager.swift` | ~184 | Accessibility and Screen Recording permission flows, legacy-key migration, and display ID helpers. |
| `Infrastructure/Configuration/AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |

## Build & Run

```bash
# Open in Xcode
open OpenClicky.xcodeproj

# Select the OpenClicky scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in Features/CursorOverlay/OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
