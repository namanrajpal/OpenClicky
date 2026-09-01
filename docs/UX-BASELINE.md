# OpenClicky UX Baseline

Status: draft for review. Section 6 recommendations are proposed, pending sign-off.
Snapshot: post-M0 (`feature/m0-strip`), 2026-08-30.

This document records how a user interacts with OpenClicky today, exactly as
implemented, and defines the baseline decisions for response modality and user
control. It is the reference for UX changes in M1 and beyond. The fourth vision
principle governs everything here: keep the UX lean, beautiful, and meaningful,
with the agent able to draw useful guided instructions on screen.

## 1. Interaction surfaces (current)

The app has exactly three user-facing surfaces:

```
UX surfaces
├── Blue cursor overlay          full-screen, click-through (ignoresMouseEvents = true)
│   ├── idle        → blue triangle trailing the mouse
│   ├── listening   → triangle replaced by a live waveform (mic power animates it)
│   ├── processing  → spinner
│   ├── responding  → triangle returns while audio plays (no text is shown)
│   └── pointing    → triangle flies along a bezier arc to the target element,
│                     with a small bubble whose text is a random phrase
│                     ("right here!"), not the answer
├── Menu bar panel               the only clickable UI in the app
│   ├── status copy ("Hold Control+Option to talk")
│   ├── model picker (Sonnet/Opus), inert since M0, becomes agent picker in M1
│   ├── permissions rows with grant buttons (1.5s live polling)
│   ├── Start button (first run only)
│   ├── feedback button, Watch Onboarding Again, Quit
│   └── "Show Clicky" cursor toggle: implemented but commented out upstream
└── Onboarding (first launch)    panel auto-opens → permissions → Start
    → intro video (mux.com) with music → typed-out prompt:
      "press control + option and introduce yourself"
```

## 2. The interaction loop (current)

One loop exists. Hold ctrl+option, speak (partial transcripts are deliberately
hidden; the waveform is the only feedback), release. All connected monitors are
captured silently. A spinner shows while the response is generated. The answer
is spoken aloud, and the cursor optionally flies to one element. The response
text is never displayed anywhere.

Voice state machine (owned by `CompanionManager`):

```
idle ──hotkey press──▶ listening ──release──▶ processing ──speech starts──▶ responding ──▶ idle
                                                    │
                                                    └── pointing runs in parallel on the overlay
```

Interruption: pressing the hotkey again cancels the in-flight response and
stops speech. This is the only interrupt affordance.

## 3. Scenario catalog (current)

| Scenario | Invoke | Input | Output | Modality control |
|---|---|---|---|---|
| Ask about the screen | hold ctrl+option | voice only | audio, plus optional pointer flight | none |
| Ask a general question | hold ctrl+option | voice only | audio (`[POINT:none]`) | none |
| Follow-up (last 10 exchanges kept) | hold ctrl+option | voice only | audio | none; history is invisible and cannot be reset |
| Interrupt a response | press hotkey again | none | speech stops, task cancels | destructive only |
| Empty press (no speech) | press and release | none | returns to idle | n/a |
| Check status / permissions | click menu bar icon | mouse | panel | n/a |
| First-run onboarding | auto-opened panel, Start | mouse | video, music, typed prompt | n/a |
| Pipeline error | n/a | n/a | spoken fallback message | none |

Interactions that do not exist today: typed input, screen-region or
single-display selection, silent or text-only mode, replaying the last answer,
pausing speech, viewing or resetting conversation history.

## 4. Response modality (current)

Every modality is hardcoded. The user controls none of them.

| Channel | Rule today | Who decides |
|---|---|---|
| Audio | Always spoken, every response | Nobody: unconditional code path |
| Text | Never displayed | Nobody: the render path is dead code |
| Pointing | `[POINT]` tag present or absent | The model, guided by the system prompt ("err on the side of pointing") |

Consequences of audio-only output: the app is unusable in meetings, open
offices, and screen-shares, inaccessible to deaf and hard-of-hearing users,
and the answer evaporates as it is spoken with no way to re-read it.

## 5. Dead and disconnected UX code (inventory)

These exist in the tree, work in isolation, and are wired to nothing. They are
assets for the baseline, cheaper to revive than to rebuild.

| Code | What it does | State |
|---|---|---|
| `CompanionResponseOverlayManager` (`CompanionResponseOverlay.swift`) | Cursor-following streaming-text bubble: 60fps tracking, screen-edge clamping, grow-upward resize, 6s auto-hide with fade | Never instantiated |
| Transient cursor mode (`CompanionManager`) | Cursor hidden until hotkey, fades out 1s after response and pointing finish | Fully wired, unreachable: its toggle is commented out in `CompanionPanelView.swift` |
| Button-triggered dictation (`BuddyDictationManager`) | Start/stop dictation from a UI control instead of the hotkey | No UI calls it |
| `onboardingDemoSystemPrompt` (`CompanionManager`) | The onboarding "look around and point at something" demo | Disabled in M0, returns in M1 via the agent |

## 6. Baseline decisions (proposed)

### D1. Text becomes the primary record; audio becomes a preference

Every response renders as streaming text in a bubble anchored to the cursor
(revive `CompanionResponseOverlayManager`, feed it from the M1 ACP stream).
Audio stays on by default but becomes a user preference. Text is the record,
audio is the convenience. This single change fixes the largest gap (Section 4)
and gives M1 streaming a visible surface.

### D2. Modality control lives in three layers

1. Persistent preference: a panel control with three states: Voice + Text,
   Text only, Voice only. Replaces the dead "Show Clicky" toggle row.
2. Per-interaction voice command: "answer silently", "quietly" are honored for
   that response. This is the most Clicky-native control and costs one router
   rule (M2) or one prompt-contract line (M1).
3. Hotkey variant: ctrl+option+shift asks silently. Power-user path, cheap to
   add since the CGEvent tap already reads modifier flags.

### D3. The pointer bubble carries real content

The random pointer phrases ("right here!") are replaced by the element label or
a short model-provided caption. When the annotation grammar lands (CIRCLE,
ARROW, STEP), each mark may carry its own caption. One vocabulary, one renderer.

### D4. Auto-mute is deferred until detection is reliable

Detecting screen-sharing or Do Not Disturb and falling back to text is
meaningful-UX territory, but a false positive (silently swallowing audio the
user expected) is worse than the gap. Revisit after D1 ships, when text output
makes the fallback safe.

### D5. Capture scoping is a UX feature, tracked in M2

Active-display-only, downscaled capture (M2 capture discipline) is presented in
UX terms: less of your screen leaves the machine, faster answers. Drag-to-select
a region is deferred; it adds a mode and a shortcut for a need active-display
cropping mostly covers. Revisit if real usage shows cross-app questions where
cropping picks the wrong display.

### D6. Small reachable wins, order of cheapness

1. Un-comment the cursor visibility toggle and verify transient mode works.
2. Replace the spoken error fallback with error text in the response bubble
   once D1 lands (spoken errors have the same problems as spoken answers).
3. A "conversation reset" action in the panel (history exists, is invisible,
   and currently persists for 10 exchanges with no user awareness).

## 7. Open questions (not yet decided)

| # | Question | Notes |
|---|---|---|
| O1 | Does a long text response outgrow the cursor bubble? | Bubble max width is 340pt. Options: cap with "expand" affordance, or a pinned reading panel. Decide after D1 is usable. |
| O2 | Typed input: panel text field, or a summonable spotlight-style bar? | Accessibility and quiet-environment gap. Candidate for M2. |
| O3 | Should conversation history be visible (transcript view)? | Pairs with D6.3. A transcript also gives replay-last-answer for free. |
| O4 | Voice, rate, and volume settings for TTS? | Defer until the M3 TTS decision; AVSpeech settings may not survive an engine swap. |

## 8. Maintenance

Update this document when a decision in Section 6 ships (move it to Section 1
through 4 as current behavior), when an open question in Section 7 is decided
(promote it to Section 6), or when a new user-facing surface is added.
