# OpenClicky Roadmap

Status: living document. Update when a milestone ships or a plan is
promoted/dropped. Companion docs: `docs/UX-BASELINE.md` (interaction
baseline), `docs/reference/kiro-cli.md` (ACP wire contract).

## Where we are

```
Milestones
├── M0  Strip cloud deps                          DONE (9877f4e)
├── M1  ACP transport (kiro-cli, streaming)       DONE (a60b408)
├── M2  Latency layer (AX router, capture         DONE (a60b408)
│       discipline, per-sentence TTS)
└── M3  Local model upgrades (whisper.cpp STT,    NOT STARTED
        modern local TTS) only where measurement
        justifies the swap
```

Shipped UX beyond the milestones (see UX-BASELINE Section 6):

- D1 text-primary streaming bubble, D2 layer 1 modality control,
  D3 pointer bubble carries real content, D5 capture scoping + lasso
  region select, D6.1 cursor buddy toggle, copy-response shortcut.
- Pen circle highlight: the buddy sketches a hand-drawn open circle
  around the element it points at (`PenCircleShape` in
  `OverlayWindow.swift`).

## Near-term (committed direction, unscheduled)

1. **Annotation grammar (Q2).** Generalize `[POINT]` into a vocabulary
   the agent can emit and the overlay can draw: POINT, CIRCLE, ARROW,
   STEP, each with an optional caption. Core parses, shell renders.
   The pen circle renderer is the first shell primitive for this.
2. **CompanionManager core/shell split (Q1).** Extract the pipeline
   (routing, prompt assembly, tag parsing) into `Core/` for
   portability; leave AppKit surfaces in the shell.
3. **D2 layers 2 and 3.** Per-interaction voice modality commands
   ("answer silently") and the ctrl+option+shift silent-ask hotkey.
4. **Cleanup backlog.** Stale README, dead `ElementLocationDetector.swift`
   and `ClaudeAPI.swift`, upstream tutorial assets, scheme rename
   (deferred while pbxproj churn outweighs the benefit).

## Potential plans (not committed)

- **Guided tasks**: multi-step walkthroughs ("how do I record a macro
  in Sheets") where the buddy points at each step in sequence instead
  of answering single-shot. See `docs/plans/guided-tasks.md`.

## Open questions carried from UX-BASELINE

O1 long-response bubble overflow, O2 typed input, O3 visible
transcript, O4 TTS voice settings (deferred to M3).
