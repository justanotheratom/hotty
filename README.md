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

## How it works

- `ClickHoldTrigger` — a session event tap holds back mouse-downs over text fields.
  Release or movement before the hold duration replays the press as a normal click or
  drag; otherwise the app never sees it, so a selection under the pointer survives.
  Dragging before any speech is heard cancels dictation and gives you the drag.
- `TouchHoldTrigger` — a fresh single touch that stays still for the hold duration.
  Moving first, a second finger, a click, or (optionally) the bottom thumb zone aborts.
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
| `HOTTY_AUDIO_TEST` | Runs three start/finish recording cycles on the current input device |
