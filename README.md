# HoTty — Hold to Talk

System-wide dictation for macOS 26+. Hold the trackpad over any text field and speak;
release to finish. Hold on selected text to replace it. Transcription runs on-device
with Apple's SpeechAnalyzer.

## Build & run

    scripts/build.sh --run

This builds `build/HoTty.app` and signs it with your Apple Development identity, so
the Accessibility grant survives rebuilds. On first launch, grant **Accessibility**
and **Microphone** permission.

## Settings (menu bar ▸ waveform ▸ Settings…)

| Setting | Options |
|---|---|
| Hold gesture | **Press & hold** (click and keep pressed; public APIs) or **Rest finger** (no click; private MultitouchSupport) |
| Hold for | 0.15–1.5 s slider |
| While speaking | **Preview overlay** (in-progress words float near the pointer, final phrases are typed) or **Type live** (in-progress words typed and corrected with backspaces) |
| Without a selection | Move caret to where you hold, or keep the current caret |

Trigger and live-text mode can also be switched straight from the menu bar.

## Release gestures

Once a hold is active, drag sideways before letting go (drag with the button held in
press & hold mode, slide your finger in rest-finger mode):

| Release after… | Result |
|---|---|
| little or no movement | Types what you said |
| dragging **right** ~60 pt | Types it, then presses **Return** (sends in chat apps; only if something was transcribed) |
| dragging **left** ~60 pt | **Cancels**: deletes everything typed and restores the replaced selection |
| dragging **up** ~60 pt | **Locks** into hands-free mode (below) |

The action is decided on release, so sliding back changes your mind; the overlay shows
"↵ Send", "✕ Cancel" or "🔒 Lock" while a gesture is armed, and a direction hint once
you start dragging. Diagonal movement counts for its dominant direction.

## Hands-free mode

Hold, drag up, release: HoTty keeps listening with your hands free. From then on it
ignores every gesture, click and key, so you can use the Mac normally (look things up,
switch apps). The overlay stays put with a timer and three buttons, the only way to end:

- **Cancel**: discard and restore the field
- **Finish**: type the rest
- **Send**: finish, then Return

Text only ever goes into the field you started in. While it doesn't have focus, finished
phrases wait ("Paused · N words waiting") and are typed when you come back; Finish or
Send brings the field back to the front first (or copies the text to the clipboard if the
field is gone). While locked, in-progress words show in the overlay even in "type live"
mode, so no live corrections can land in another app.

## How it works

- `ClickHoldTrigger` — a session event tap holds back mouse-downs over text fields.
  Release or movement before the hold duration replays the press as a normal click or
  drag; otherwise the app never sees it, so a selection under the pointer survives.
  Once a hold is recognized, drags steer the release gesture instead of reaching the app.
- `TouchHoldTrigger` — a fresh single touch that stays still for the hold duration.
  Moving restarts the clock; a second finger or (optionally) the bottom thumb zone aborts,
  and a click before any speech cancels silently.
- `DictationEngine` — mic → SpeechAnalyzer (`SpeechTranscriber`, falling back to
  `DictationTranscriber`); audio is buffered while the analyzer spins up.
- `TextInjector` — synthesized Unicode keystrokes; diffs volatile text for minimal
  backspacing; adds joining spaces and mid-sentence lowercasing from the text before the caret.

## Debugging

Launch through `open` so macOS attributes privacy prompts to HoTty (running the
binary directly from a shell aborts on a TCC check):

    open --env HOTTY_DEBUG_TOUCH=1 --stdout /tmp/hotty.log --stderr /tmp/hotty.log build/HoTty.app

| Variable | What it does |
|---|---|
| `HOTTY_DEBUG_TOUCH` | Logs raw trackpad contacts and rest-finger state changes (the MTTouch layout is private and read by offset) |
| `HOTTY_DEBUG_AX` | Logs the Accessibility role chain under the pointer every second, to see why a text field isn't detected |
| `HOTTY_OVERLAY_DEMO` | Runs six fake sessions through the overlay and menu bar icon at dictation speed |
| `HOTTY_GESTURE_TEST` | In a focused **TextEdit** document (refuses any other app): replaces a selection then cancels, then dictates and sends |
| `HOTTY_LOCK_TEST` | In a focused **TextEdit** document: locks a session, simulates phrases while focused and while Finder is in front, then clicks the overlay's Finish button |
| `HOTTY_AUDIO_TEST` | Runs three start/finish recording cycles on the current input device |
