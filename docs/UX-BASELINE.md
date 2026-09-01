# OpenClicky UX Baseline

Status: current baseline. D1, D2 layer 1, D3 local answers, D5, and D6 items 1-2 are shipped; remaining decisions are marked proposed.
Snapshot: post-M1/M2 plus lasso, cloud TTS, and pen-circle updates, 2026-09-01.

This document records how a user interacts with OpenClicky today, exactly as
implemented, and defines the baseline decisions for response modality and user
control. It is the reference for UX changes in M1 and beyond. The fourth vision
principle governs everything here: keep the UX lean, beautiful, and meaningful,
with the agent able to draw useful guided instructions on screen.

## 1. Interaction surfaces (current)

The app has exactly three user-facing surfaces:

```text
UX surfaces
├── Blue cursor overlay          one transparent window per display
│   ├── idle        -> blue triangle trailing the mouse
│   ├── listening   -> live waveform driven by microphone power
│   ├── processing  -> spinner
│   ├── responding  -> triangle plus streaming response text near the cursor
│   ├── lasso       -> hand-drawn selection stroke while the hotkey is held
│   └── pointing    -> Bezier flight, answer bubble, and pen-circle highlight
├── Menu bar panel               the only persistent clickable UI
│   ├── status and permission setup
│   ├── ACP agent-mode picker
│   ├── Voice + Text / Text only / Voice only preference
│   ├── persistent or transient cursor-buddy toggle
│   ├── Start button on first run
│   └── Watch Onboarding Again and Quit
└── Onboarding                    panel -> permissions -> Start
    -> welcome bubble -> four local instruction lines
```

The overlay is normally click-through. It temporarily accepts and consumes mouse events while the push-to-talk lasso gesture is armed.

## 2. The interaction loop (current)

Hold Control+Option and speak. Partial transcripts stay hidden while the waveform provides feedback. Optionally drag a lasso around a region before releasing. Release finalizes the transcript and starts one of two paths:

1. A confident element-location request uses the frontmost app's accessibility tree and points at the exact coordinate locally.
2. Every other request captures the active display or lasso crop and sends the transcript, image, image dimensions, and AX element names to the persistent ACP agent session.

Text streams near the cursor. Completed sentences enter ordered TTS when voice output is enabled. A trailing POINT tag can start the cursor flight and pen-circle highlight.

Voice state machine, owned by `CompanionManager`:

```text
idle -> listening -> processing -> responding -> idle
```

Pointing runs through overlay navigation state after the response sets the voice state back to idle. Pressing the hotkey again cancels the Swift response task, sends ACP `session/cancel`, and stops the TTS queue.

## 3. Scenario catalog (current)

| Scenario | Invoke | Input | Output | Modality control |
|---|---|---|---|---|
| Ask about the screen | hold Control+Option | voice + active-display capture | streaming text, optional voice, optional point | persistent three-state preference |
| Ask about a selected region | hold Control+Option and drag | voice + lasso crop | streaming text, optional voice, optional point | persistent three-state preference |
| Locate an accessible element | ask a short “where is” or “find” question | voice + AX tree | immediate local text/voice and exact point | persistent three-state preference |
| Ask a general question | hold Control+Option | voice + capture context | streaming text and optional voice, no point when `[POINT:none]` | persistent three-state preference |
| Follow up | hold Control+Option | voice | same persistent ACP session | persistent three-state preference |
| Interrupt a response | press hotkey again | none | task, ACP turn, and speech stop | destructive only |
| Copy last answer | Control+Option+C | none | clipboard copy + confirmation bubble | n/a |
| Empty press | press and release | none | returns to idle | n/a |
| Check setup | click menu bar icon | mouse | panel | n/a |
| First-run onboarding | panel Start button | mouse | local streamed instruction sequence | n/a |
| Pipeline error | automatic | n/a | specific text error and short optional voice fallback | persistent three-state preference |

Interactions that do not exist today: typed input, replaying the last answer, pausing speech, viewing or resetting conversation history, per-interaction silent commands, and a silent hotkey variant.

## 4. Response modality (current)

The menu-bar panel persists one of three response modes: Voice + Text, Text only, or Voice only.

| Channel | Rule today | Who decides |
|---|---|---|
| Audio | Enabled in Voice + Text and Voice only | User preference; cloud provider selection can fall back per sentence |
| Text | Enabled in Voice + Text and Text only | User preference; streams near the cursor and hides POINT metadata |
| Pointing | Runs when the local router resolves an element or the agent emits a valid POINT tag | Deterministic router or agent response contract |

Per-interaction voice commands and the Control+Option+Shift silent-ask variant remain proposed.

## 5. Dead and disconnected UX code (inventory)

| Code | What it does | State |
|---|---|---|
| Button-triggered dictation (`BuddyDictationManager`) | Starts or stops dictation from a UI control | No UI calls it |

Previously disconnected features now active: `CompanionResponseOverlayManager`, transient cursor mode, the cursor visibility toggle, and local instruction-based onboarding.

## 6. Baseline decisions (proposed)

### D1. Text becomes the primary record; audio becomes a preference — SHIPPED (M1)

Every response renders as streaming text in a bubble anchored to the cursor
(revive `CompanionResponseOverlayManager`, feed it from the M1 ACP stream).
Audio stays on by default but becomes a user preference. Text is the record,
audio is the convenience. This single change fixes the largest gap (Section 4)
and gives M1 streaming a visible surface.

### D2. Modality control lives in three layers — layer 1 SHIPPED (M1); layers 2-3 pending

1. Persistent preference: a panel control with three states: Voice + Text,
   Text only, Voice only. Replaces the dead "Show Clicky" toggle row.
2. Per-interaction voice command: "answer silently", "quietly" are honored for
   that response. This is the most Clicky-native control and costs one router
   rule (M2) or one prompt-contract line (M1).
3. Hotkey variant: ctrl+option+shift asks silently. Power-user path, cheap to
   add since the CGEvent tap already reads modifier flags.

### D3. The pointer bubble carries real content — SHIPPED for router answers; agent POINT labels pending the annotation grammar

The random pointer phrases ("right here!") are replaced by the element label or
a short model-provided caption. When the annotation grammar lands (CIRCLE,
ARROW, STEP), each mark may carry its own caption. One vocabulary, one renderer.

### D4. Auto-mute is deferred until detection is reliable

Detecting screen-sharing or Do Not Disturb and falling back to text is
meaningful-UX territory, but a false positive (silently swallowing audio the
user expected) is worse than the gap. Revisit after D1 ships, when text output
makes the fallback safe.

### D5. Capture scoping is a UX feature — SHIPPED, extended with lasso region selection

Active-display-only, downscaled capture shipped with M2. Region selection
shipped after: while holding push-to-talk, click-drag draws a lasso on the
overlay; on release the lasso's bounding rectangle (always a rectangular crop)
is captured instead of the display. No drag means unchanged behavior. During
the hold, the overlay accepts mouse events, so clicks are consumed rather than
passed through; this is the cost of the gesture and only applies while the
hotkey is held. Region questions skip the router (inherently visual).

Also shipped: ctrl+option+C copies the last response text to the clipboard,
with a confirmation flash in the cursor bubble.

### D6. Small reachable wins

1. Cursor visibility toggle and transient mode: SHIPPED.
2. Specific error text in the response bubble with a short optional voice fallback: SHIPPED.
3. Conversation reset action in the panel: proposed. The app keeps a local copy of the last 10 exchanges for a future transcript view, while the persistent ACP session owns actual agent context.

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
