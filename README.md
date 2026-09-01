# OpenClicky

A voice companion for macOS that lives next to your cursor. Hold a hotkey,
ask about anything on your screen, and it answers out loud, in streaming text,
and by flying a little blue cursor over to point at things.

OpenClicky is local-first. Speech recognition runs on-device, speech output
runs on-device by default, and the AI brain is a local agent CLI you already
have; the app itself holds zero API keys and opens zero network connections
of its own.

## What it does

- **Push-to-talk**: hold `ctrl + option` anywhere, speak, release. A waveform
  replaces the cursor buddy while you talk.
- **Sees your screen**: on release it captures the active display (downscaled,
  only while the key is held) and sends it to the agent with your question.
- **Answers three ways**: streaming text in a bubble that follows your cursor,
  spoken sentences that start playing while the rest is still generating, and
  a pointer flight: the blue triangle flies to the relevant UI element and
  sketches a hand-drawn circle around it.
- **Lasso a region**: while holding the hotkey, click-drag a loop around part
  of your screen. Only that region's bounding box is captured and your
  question is answered about exactly that area.
- **Instant local answers**: "where is the save button" never touches the
  agent. A deterministic router reads the frontmost app's accessibility tree
  and points at the exact coordinates in about 100 ms.
- **Copy the answer**: `ctrl + option + C` copies the last response.

## How it works

```
hold ctrl+option ──▶ mic ──▶ Apple Speech (on-device STT)
                                   │
                        ┌──────────▼──────────┐
                        │  deterministic router │── element question? ──▶ AX tree lookup,
                        └──────────┬──────────┘                          exact-coordinate pointing
                                   │ everything else
                                   ▼
                  active display (or lasso region) captured
                                   │
                                   ▼
                 local agent: kiro-cli spawned as a subprocess
                 speaking the Agent Client Protocol (JSON-RPC
                 over stdio, image content blocks, streaming)
                                   │
                                   ▼
              text streams into the cursor bubble, sentences are
              spoken as they complete, and a trailing [POINT:x,y]
              tag flies the cursor to the referenced element
```

The agent brings its own auth and model access. A persistent session holds
conversation memory, so follow-ups just work. The app installs a dedicated
agent persona (`~/.kiro/agents/openclicky.json`) automatically: no tools, no
MCP servers, which keeps session startup fast and makes a spoken question
incapable of side effects.

## Requirements

- macOS 14.2 or later (ScreenCaptureKit)
- Xcode 15 or later
- [Kiro CLI](https://kiro.dev/cli/) installed and authenticated
  (`kiro-cli chat` should work in your terminal)

## Setup

```bash
git clone https://github.com/namanrajpal/OpenClicky.git
cd OpenClicky
open OpenClicky.xcodeproj
```

In Xcode: select the `OpenClicky` scheme, set your signing team under
Signing & Capabilities, and hit Cmd+R.

On first run the app lives in your menu bar. Open the panel from the blue
triangle icon and grant the four permissions it asks for: microphone,
speech recognition, accessibility, and screen recording. Screen recording
takes effect after relaunching the app once. Capture happens only while you
hold the hotkey.

### Optional: cloud text-to-speech

The default voice is the on-device system synthesizer. For a nicer voice,
create a `.env` file next to the project (it is gitignored):

```
CARTESIA_API_KEY=...        # Cartesia Sonic, default when present
DEEPGRAM_API_KEY=...        # Deepgram Aura, alternative
OPENCLICKY_TTS_PROVIDER=cartesia
```

Sentences fall back to the local voice automatically if a fetch fails.

## Controls

| Where | Action | Result |
|---|---|---|
| anywhere | hold `ctrl + option`, speak, release | ask about your screen |
| anywhere | click-drag while holding the hotkey | lasso a region for the question |
| anywhere | press the hotkey again mid-response | interrupt and ask something new |
| anywhere | `ctrl + option + C` | copy the last response |
| menu bar panel | agent picker | switch which agent answers |
| menu bar panel | respond with Voice + Text / Text only / Voice only | output preference |
| menu bar panel | show cursor buddy toggle | off = buddy appears only during interactions |

## Project layout

```
OpenClicky/
├── Core/                          portable core (no AppKit)
│   ├── ACPAgentClient.swift          agent subprocess, ACP JSON-RPC, streaming
│   ├── QuestionRouter.swift          on-device vs agent routing rules
│   └── StreamingSentenceSplitter.swift  per-sentence TTS + tag holdback
├── CompanionManager.swift         central state machine and pipeline
├── OverlayWindow.swift            cursor buddy, pointing flight, pen circle, lasso stroke
├── CompanionResponseOverlay.swift streaming text bubble
├── AXTreeProvider.swift           accessibility tree extraction
├── LassoRegionSelectionController.swift  region-select drag capture
├── CompanionScreenCaptureUtility.swift   ScreenCaptureKit capture and crops
├── CloudSentenceTTSClient.swift   optional Cartesia / Deepgram voices
├── BuddyDictationManager.swift    mic pipeline and push-to-talk sessions
└── CompanionPanelView.swift       menu bar panel UI
```

More depth:

- `AGENTS.md`: architecture doc for AI coding agents (and humans)
- `docs/UX-BASELINE.md`: the interaction model and every UX decision
- `docs/reference/kiro-cli.md`: the ACP wire protocol as verified live
- `docs/plans/`: roadmap and design sketches (guided multi-step tasks)

## Privacy

Nothing runs in the background. A screenshot is taken only while the hotkey
is held, covers only the active display (or your lasso region), and goes only
to the local agent process. The app has no analytics, no auto-updater, and no
network code of its own; optional cloud TTS is the single exception and only
when you provide keys.

## License

MIT. See [LICENSE](LICENSE).

OpenClicky grew out of [clicky](https://github.com/farzaa/clicky), an
MIT-licensed weekend experiment by Farza. It has since been completely
reworked around a different vision: local-first execution, a local agent
subprocess in place of cloud APIs, on-device routing, and region-scoped
capture. The license file carries the original copyright line alongside
the current one.
