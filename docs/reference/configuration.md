# OpenClicky Configuration Reference

OpenClicky uses four configuration sources: Xcode build settings, `Info.plist`, environment or `.env` values, and `UserDefaults`.

## Environment lookup

`Infrastructure/Configuration/EnvFileLoader.swift` searches in this order:

1. The process environment.
2. The file named by `OPENCLICKY_ENV_PATH`.
3. The repository-root `.env` derived from the compile-time source path for development builds.
4. `~/.config/openclicky/.env` for installed builds.

The first non-empty value for a requested key wins. `.env` parsing supports blank lines, `#` comments, and matching single or double quotes around values. Key values are never intentionally logged.

The repository-root `.env` is gitignored.

## Text-to-speech

| Variable | Values | Default or behavior |
|---|---|---|
| `OPENCLICKY_TTS_PROVIDER` | `cartesia`, `deepgram`, `local` | Cartesia when its key exists, then Deepgram, then local |
| `CARTESIA_API_KEY` | secret | Enables Cartesia |
| `CARTESIA_KEY` | secret | Supported Cartesia alias |
| `CARTERSIA_KEY` | secret | Supported legacy misspelling |
| `CARTESIA_VOICE_ID` | Cartesia voice UUID | Built-in default voice UUID |
| `DEEPGRAM_API_KEY` | secret | Enables Deepgram |
| `DEEPGRAM_KEY` | secret | Supported Deepgram alias |
| `DEEPGRAM_TTS_MODEL` | Deepgram model ID | `aura-2-thalia-en` |

Provider selection rules:

- `local` always selects `LocalSpeechSynthesizerTTSClient`.
- `deepgram` skips Cartesia and selects Deepgram when a Deepgram key exists.
- `cartesia` selects Cartesia when a Cartesia key exists. With no Cartesia key, the implementation can still fall through to Deepgram when a Deepgram key exists.
- An unset value chooses the first configured provider in Cartesia, Deepgram, local order.
- Every failed cloud sentence falls back to local speech independently.

Example development file:

```dotenv
CARTESIA_API_KEY=your_key
OPENCLICKY_TTS_PROVIDER=cartesia
CARTESIA_VOICE_ID=your_voice_uuid
```

## Generated Kiro agent

`ACPAgentClient.ensureAgentConfigInstalled()` manages:

```text
~/.kiro/agents/openclicky.json
```

The generated fields are:

| Field | Current value |
|---|---|
| `name` | `openclicky` |
| `model` | `claude-haiku-4.5` |
| `tools` | `[]` |
| `mcpServers` | `{}` |
| `includeMcpJson` | `false` |
| `prompt` | Embedded OpenClicky voice, vision, and POINT instructions |

The file is rewritten only when the embedded prompt or model differs. The app then starts `kiro-cli acp --agent openclicky` with a temporary working directory.

Changing agents through the panel uses ACP `session/set_mode`. Changing the generated agent file manually is temporary because a future OpenClicky start can restore the embedded prompt and model.

## App metadata and permissions

`OpenClicky/Info.plist` defines:

| Key | Purpose |
|---|---|
| `LSUIElement` | Runs as a menu-bar app with no Dock icon |
| `VoiceTranscriptionProvider` | Currently `apple`; the factory always resolves Apple Speech |
| `NSMicrophoneUsageDescription` | Microphone permission copy |
| `NSSpeechRecognitionUsageDescription` | Speech recognition permission copy |
| `NSScreenCaptureUsageDescription` | Screen recording permission copy |

Runtime permission state includes:

- Accessibility, required for the global event tap and AX tree access.
- Screen recording, required for ScreenCaptureKit.
- Microphone, required for audio capture.
- Speech recognition, required for Apple Speech.
- Screen-content capture, tested through ScreenCaptureKit and cached in `UserDefaults`.

## Persisted user preferences

| `UserDefaults` key | Type | Meaning |
|---|---|---|
| `responseModality` | string | `voiceAndText`, `textOnly`, or `voiceOnly` raw preference |
| `isClickyCursorEnabled` | bool | Persistent buddy visibility; false enables transient interaction-only display |
| `hasCompletedOnboarding` | bool | Hides the first-run Start flow after completion |
| `hasScreenContentPermission` | bool | Cached result of the ScreenCaptureKit content permission probe |
| `com.namanrajpal.openclicky.hasPreviouslyConfirmedScreenRecordingPermission` | bool | Last confirmed Screen Recording permission state |
| `NSInitialToolTipDelay` | number | Registered as zero at app launch |

The `responseModality` implementation falls back to Voice + Text when no recognized value exists.

## Build configuration

The Xcode project defines one app target and two test targets:

```text
OpenClicky
└── OpenClickyTests
```

Current platform settings include macOS 14.2, Swift 5, main-actor default isolation, hardened runtime enabled, and app sandbox disabled.

The app and test target use development team `6D7X9GGZAW`, generated bundle strings use OpenClicky, and the project reference resolves to `OpenClicky/OpenClicky.entitlements`. Changing signing identity can require fresh macOS permission grants.

Use Xcode Cmd+R for development builds. Avoid terminal `xcodebuild` because a differently signed app instance can lose existing TCC permission grants.

## Logging

OpenClicky uses structured emoji-prefixed `print` statements for local development. ACP subprocess stderr is discarded by the app. For direct CLI diagnosis, see the logging paths and environment values in [kiro-cli reference](kiro-cli.md).
