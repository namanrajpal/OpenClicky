# Guided Tasks

Status: **potential plan, not committed, not scheduled.** Captured from a
brainstorm on 2026-08-31. Revisit after the annotation grammar (Q2) lands.

## Problem

Today the pipeline is single-shot: one push-to-talk turn produces one
response with at most one `[POINT]` tag. Asking "how do I record a macro
in Google Sheets" gets a spoken summary and a pointer at the first step
only. A guided task should walk the user through every step, pointing at
each one as they go.

## The core constraint: coordinate staleness

The agent points by estimating pixel coordinates on a screenshot. The
moment the user performs step 1 (say, clicking the Extensions menu), the
screen changes and every coordinate derived from the original screenshot
is wrong. Any design that plans all coordinates upfront can only ever be
right about step 1. Grounding has to happen per step, against the screen
as it exists at that moment.

## Options considered

### Option A: agent-in-the-loop stepping

Each step is its own agent turn on the existing persistent ACP session.
After the user performs a step (hotkey tap, saying "next", or
auto-detect), the client captures a fresh screenshot + AX tree and
prompts: "user completed step N, here is the new screen, point at step
N+1."

- Correct by construction: every step grounded in current reality.
- Cheapest to build: a state machine in `CompanionManager` plus a
  prompt-contract addition. The multi-turn session already exists.
- Cost: roughly 3 to 5 seconds of agent latency per step.

### Option B: plan once, ground locally (preferred architecture)

Turn 1 asks the agent for the whole plan with steps that name targets
instead of coordinates:

```
[GUIDE]
[STEP:1:target="Extensions menu":say="open the extensions menu"]
[STEP:2:target="Macros":say="hover over macros"]
[STEP:3:target="Record macro":say="click record macro"]
```

At each step the client resolves the named target against a fresh AX
tree snapshot, using the same machinery `QuestionRouter` already uses.
Zero agent round-trips between steps; pointer flights are instant.
Fall back to a single agent turn (Option A's move) only when the AX
tree cannot resolve the named target.

- Fast: agent reasoning happens once, grounding is local per step.
- Forces the annotation grammar design (Q2), which is planned anyway.
- Risk: AX coverage varies by app (see caveats).

### Option C: auto-advance (polish layer on A or B)

After "click Extensions," watch the AX tree for the expected element
("Macros" menu item) to appear and advance automatically, so the user
never has to say "next." Pair with a manual override because false
advancement is worse than a manual tap.

## Recommendation

Option B as the architecture, Option A's fresh-capture re-ask as the
fallback path when AX resolution fails, Option C as a later polish
layer. This reuses the router, `AXTreeProvider`, and the persistent
session, and it converges with the annotation grammar work.

## Caveats and open questions

- **Google Sheets is a hard AX target.** The grid is canvas-rendered.
  Menus and toolbars are DOM and usually expose AX names via Chrome
  (may require `AXEnhancedUserInterface`); expect the agent-vision
  fallback to carry canvas content. Validate AX coverage in Chrome
  before betting on Option B for web apps.
- **Interruption semantics.** A guide should survive a side question
  ("wait, what is a macro?") without losing its place. The shared
  session history helps: the agent knows a guide is in flight.
- **Step-completion detection.** Manual (hotkey tap or "next") ships
  first; AX-observed auto-advance is Option C territory.
- **Cancel affordance.** The existing interrupt (hotkey press) should
  offer "stop the guide" as distinct from "cancel this response."

## Prerequisites

1. Annotation grammar (Q2) with a STEP primitive.
2. AX target resolution by name (extend `QuestionRouter` matching).
3. A guided-mode state machine in `CompanionManager` (or its future
   Core extraction).
