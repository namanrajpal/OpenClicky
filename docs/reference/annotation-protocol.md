# OpenClicky Annotation Protocol

Status: current as-built contract for agent-driven pointing. Future annotation types described in the roadmap are proposals and are outside this protocol.

## Purpose

An ACP agent response can end with one machine-readable POINT tag. OpenClicky strips the tag from text and speech, maps its screenshot-pixel coordinate to the captured screen region, and starts the cursor-buddy animation.

## Grammar

```text
[POINT:none]
[POINT:<x>,<y>]
[POINT:<x>,<y>:<label>]
[POINT:<x>,<y>:<label>:screen<N>]
```

The generated OpenClicky agent is instructed to use a short label and usually emits:

```text
[POINT:<x>,<y>:<label>]
```

Examples:

```text
you'll want the color inspector, top right of the toolbar. [POINT:1100,42:color inspector]
html is the skeleton of every web page. [POINT:none]
```

## Field rules

| Field | Contract |
|---|---|
| `x` | Non-negative integer pixel coordinate in the referenced JPEG |
| `y` | Non-negative integer pixel coordinate in the referenced JPEG |
| `label` | Optional trimmed text that cannot begin with whitespace, `]`, or `:` and cannot contain `]` or `:` |
| `screen<N>` | Optional 1-based index into the captures attached to the prompt |

The tag must appear at the end of the response. Trailing whitespace is accepted. A tag elsewhere in the response is treated as ordinary response text.

`[POINT:none]` explicitly requests no cursor flight. A missing or malformed tag also produces no cursor flight, but its text remains visible because the parser cannot safely identify it as metadata.

## Coordinate contract

Coordinates use the actual JPEG pixel dimensions included in the prompt label:

```text
image: <label> (image dimensions: <width>x<height> pixels)
```

The origin is the image's top-left corner. X increases rightward and Y increases downward. The model estimates the point from the image. AX context contains element names and no coordinates.

OpenClicky maps a valid coordinate by:

1. Clamping X and Y to the image bounds.
2. Scaling pixels to the represented frame's width and height in AppKit points.
3. Flipping Y into AppKit's bottom-left coordinate system.
4. Adding the represented frame's global origin.

For a lasso capture, the represented frame is the lasso's rectangular crop. The same formula therefore applies to display and region captures.

## Screen selection

The normal request attaches one image: the active display or one lasso crop. In that path, `screen<N>` is unnecessary.

When multiple captures are attached, `screen<N>` selects the 1-based capture. Without it, OpenClicky uses the capture marked as the cursor screen. An out-of-range screen number cannot produce a point.

## Streaming behavior

Agent text arrives in small chunks. `StreamingSentenceSplitter.textWithoutTrailingPartialTag(_:)` hides a trailing incomplete `[` sequence so the text overlay does not flash partial protocol metadata. Sentence TTS receives completed tag-free sentences. The final parser removes a complete POINT tag before final display and speech.

## Parser ownership

- Agent emission instructions: `Core/ACPAgentClient.swift`, `agentPrompt`.
- Streaming holdback: `Core/StreamingSentenceSplitter.swift`.
- Final parse and coordinate mapping: `CompanionManager.swift`, `parsePointingCoordinates(from:)` and `respondToTranscriptWithScreenshot(transcript:)`.
- Rendering: `OverlayWindow.swift`, `BlueCursorView` and `PenCircleShape`.

## Planned extensions

The roadmap proposes CIRCLE, ARROW, and STEP annotations. Their grammar and rendering semantics are not defined yet. Add them here only after parser and renderer behavior ship.
