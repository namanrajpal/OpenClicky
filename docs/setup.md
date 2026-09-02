# OpenClicky Setup

This guide covers a from-source development setup on macOS.

## Requirements

- macOS 14.2 or later
- Xcode 15 or later
- [Kiro CLI](https://kiro.dev/cli/) installed and authenticated
- An Apple development team selected for local signing

Verify Kiro CLI before opening the app:

```bash
kiro-cli chat
```

A successful interactive chat confirms that the CLI can authenticate and reach its configured model provider.

## Clone and open

```bash
git clone https://github.com/namanrajpal/OpenClicky.git
cd OpenClicky
open OpenClicky.xcodeproj
```

In Xcode:

1. Select the `OpenClicky` scheme.
2. Open Signing & Capabilities and select your development team.
3. Build and run with Cmd+R.

Do not run `xcodebuild` from Terminal for routine development. Terminal builds create a differently signed app instance and can invalidate the macOS TCC grants used for microphone, speech recognition, accessibility, and screen recording.

## First run

OpenClicky is a menu-bar-only app. It has no Dock icon or main window.

1. Click the blue triangle in the menu bar.
2. Grant microphone access.
3. Grant speech recognition access.
4. Grant accessibility access.
5. Grant screen recording access.
6. Relaunch the app after granting screen recording if macOS requests it.
7. Select **Start** to finish onboarding.

The panel polls permission state while it is open. Accessibility permission enables the global push-to-talk event tap. Screen recording permission enables ScreenCaptureKit capture.

## Agent initialization

On startup, `ACPAgentClient` searches these locations for `kiro-cli`, in order:

1. `~/.toolbox/bin/kiro-cli`
2. `~/.local/bin/kiro-cli`
3. `/usr/local/bin/kiro-cli`
4. `/opt/homebrew/bin/kiro-cli`

The app creates or updates `~/.kiro/agents/openclicky.json`, then starts:

```bash
kiro-cli acp --agent openclicky
```

The generated agent has no tools or MCP servers. It carries the OpenClicky response prompt and currently pins `claude-haiku-4.5`. See [kiro-cli reference](reference/kiro-cli.md) for the wire protocol.

## Optional cloud text-to-speech

The default fallback is the on-device `AVSpeechSynthesizer`. Cartesia and Deepgram are optional. Put development keys in the repository-root `.env` file or use the installed-build location `~/.config/openclicky/.env`.

```dotenv
CARTESIA_API_KEY=your_key
DEEPGRAM_API_KEY=your_key
OPENCLICKY_TTS_PROVIDER=cartesia
```

The `.env` file is gitignored. Never commit or log key values. See [Configuration](reference/configuration.md) for provider precedence and all supported names.

## Smoke test

After the app is running:

1. Hold Control+Option, say “what is on my screen?”, then release.
2. Confirm the waveform changes to a spinner and streaming text appears near the cursor.
3. Confirm voice output follows the response-modality preference.
4. Ask “where is the save button?” in an app exposing an accessible Save button. Confirm the cursor points without waiting for an agent response.
5. Hold Control+Option and drag a lasso before releasing. Confirm the answer is scoped to the selected region.
6. Press Control+Option+C. Confirm the last response is copied.

## Troubleshooting

### `kiro-cli not found`

Run `command -v kiro-cli`. If the binary is outside the four supported locations, install it in a supported location or update `ACPAgentClient.findAgentBinaryPath()`.

### Agent remains disconnected

Validate the generated agent and test it directly:

```bash
kiro-cli agent validate --path ~/.kiro/agents/openclicky.json
kiro-cli chat --agent openclicky
```

### Hotkey does nothing

Confirm Accessibility permission for the exact OpenClicky build currently running. Changing the bundle identifier, signing team, or build location can require a fresh grant.

### Capture fails or shows old permission state

Confirm Screen Recording permission, quit OpenClicky, and run it again from Xcode. macOS can require a relaunch before ScreenCaptureKit sees the grant.

### Speech recognition fails

Confirm both Microphone and Speech Recognition permissions. Apple Speech is the only active transcription provider.

### Cloud TTS falls back to the system voice

Confirm the selected provider has a configured key. A failed cloud sentence intentionally falls back to the local voice while preserving sentence order.
