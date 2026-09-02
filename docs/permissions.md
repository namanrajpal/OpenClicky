# Why OpenClicky asks for these permissions

OpenClicky answers questions about what is on your screen. To do that it
needs a few macOS permissions that sound scarier than they are. This page
explains each one in plain language, including the warning about the
"system private window picker" that surprises most people.

## The short version

OpenClicky looks at your screen only in the instant you ask it a question,
listens only while you hold the hotkey, and sends nothing anywhere except
to the agent process running on your own machine. There is no background
recording, no analytics, and no hidden uploading.

## The four permissions

### Microphone

You talk to OpenClicky. The microphone is live only while you hold
`ctrl + option`. Release the keys and the microphone turns off.

### Speech Recognition

Your voice is turned into text on your Mac using Apple's built-in speech
recognition. Audio is not sent to any server by OpenClicky.

### Accessibility

This is how OpenClicky reads the names of buttons and menus in the app you
are looking at, so that "where is the save button" can be answered
instantly by pointing at the real button. It reads labels and positions.
It does not control your apps, click for you, or type for you.

### Screen Recording

Despite the name, OpenClicky does not record video. When you release the
hotkey it takes a single screenshot of your screen (or just the region you
lassoed) so the assistant can see what you are asking about. macOS puts
one-time screenshots and continuous recording under the same permission,
so the label says "recording" even though only snapshots happen.

## "OpenClicky is requesting to bypass the system private window picker..."

On newer versions of macOS (Sequoia and later) you will occasionally see
this warning:

> "OpenClicky" is requesting to bypass the system private window picker
> and directly access your screen and audio.

This sounds alarming, so here is what it actually means.

When an app wants to capture the screen, Apple prefers that a system
window appear so you can hand-pick which window or screen to share. That
is what you see in Zoom or a screen recorder: you click share, a picker
pops up, you choose a window.

OpenClicky works differently on purpose. When you release the hotkey, the
screenshot has to happen instantly and silently, because you are in the
middle of asking a question. Popping up a picker every single time would
make the app unusable. So OpenClicky takes the screenshot directly, and
macOS flags that as "bypassing the picker."

A few things worth knowing:

- **The warning is a checkpoint, not an accusation.** macOS shows it so
  you stay aware that the app can capture the screen without a picker.
  Clicking "Allow" is the expected answer for an app like this.
- **It will come back.** macOS re-asks periodically (roughly monthly) for
  any app on this path. That is Apple's policy, not a bug in OpenClicky.
- **Zoom does not get this warning** because established apps can apply to
  Apple for a special approval that silences the recurring prompt, and
  simple screen recorders avoid it by showing you the picker each time.
  OpenClicky is a personal, open-source app without that approval, and a
  per-question picker would defeat its purpose.
- **Nothing is captured outside your question.** The capture code runs
  only when a hotkey interaction is submitted. You can read it yourself:
  it lives in `Platform/ScreenCapture/CompanionScreenCaptureUtility.swift`.

## What OpenClicky never does

- No background or scheduled screen capture
- No video recording
- No audio capture outside the hotkey hold
- No analytics or telemetry
- No auto-updater
- No sending screenshots to any service of its own (the screenshot goes
  to the local agent process on your machine, which uses whatever model
  provider you configured it with)

If you are technically inclined and want the details of the capture path,
see [Architecture](architecture.md) and the trust-boundary notes there.
