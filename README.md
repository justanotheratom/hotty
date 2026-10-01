# HoTTy — Hold To Talk utility

<p align="center">
  <a href="docs/hotty-launch.mp4"><img src="docs/hotty-launch.gif" width="800"
     alt="HoTTy in 80 seconds: hold the trackpad on a text field and talk; two hold modes; works in any app; replace a selection; preview or type-live modes; drag right to send, left to cancel, up for hands-free; on-device and private; install with Homebrew"></a>
</p>
<p align="center">
  <a href="docs/hotty-launch.mp4">Watch in HD (MP4)</a> ·
  <code>brew install justanotheratom/tap/hotty</code>
</p>

HoTTy is a system-wide dictation utility for macOS. Put the pointer on any text field,
**hold the trackpad**, and talk — your words appear at that spot as you speak. Hold on
selected text and your speech replaces just that text. Let go and you're done.

Speech recognition runs entirely **on-device** with Apple's SpeechAnalyzer
(macOS 26), so there's no account, no cloud service, no per-word cost, and it works offline.

What makes it different from keyboard-shortcut dictation apps is the trigger: the
trackpad hold is the whole interface. The pointer already marks *where* you want to
write, so holding there is also *when* to listen.

---

## Features

**Two ways to hold** (switch any time)
- **Press & hold** — click the trackpad and keep it pressed without moving.
- **Rest finger** — rest one finger on the trackpad, no click. Works with the built-in
  trackpad and external Magic Trackpads, including ones connected while HoTTy runs.
- Adjustable hold duration (0.15–1.5 s).

**Dictation**
- Works in any app with a text field: native apps, Safari, Chromium browsers (Chrome,
  Edge, Brave, Arc), and Electron apps (Slack, VS Code, …).
- Hold where you want the text: the caret moves there first (or keep the current caret — a setting).
- Hold on selected text to replace it.
- Automatic spacing when joining existing text, and mid-sentence lowercasing.
- Custom vocabulary: words spelled exactly as you enter them (names, products, jargon),
  and replacements — say one phrase, get other text typed.
- Password fields are always skipped.

**Two live-text modes** (switch any time)
- **Preview overlay** — in-progress words float in a small panel near the pointer; only
  finished phrases are typed into the field.
- **Type live** — in-progress words are typed straight into the field and corrected as
  recognition firms up.

**Release gestures** — drag before letting go:

| Release after… | Result |
|---|---|
| little or no movement | Types what you said |
| dragging **right** ~60 pt | Types it, then presses **Return** (sends in chat apps; only if something was transcribed) |
| dragging **left** ~60 pt | **Cancels**: deletes what was typed and restores any selection it replaced |
| dragging **up** ~60 pt | **Hands-free mode** (below) |

The overlay shows "↵ Send", "✕ Cancel" or "🔒 Lock" while a gesture is armed; slide back
to change your mind.

**Hands-free mode** — for longer dictation while you use the Mac normally
- Hold, drag up, release: HoTTy keeps listening and ignores every gesture, click and key.
- Switch apps, look things up — text only ever goes into the field you started in.
  While that field doesn't have focus, phrases wait ("Paused · N words waiting") and are
  typed when you return.
- End with the overlay's **Cancel / Finish / Send** buttons — the only way out. Finish and
  Send bring the original field back to the front first.

**Other**
- Menu bar app with quick switches for hold type and live-text mode.
- Language picker for any locale SpeechAnalyzer supports; the model downloads on first use.
- Robust to microphone changes mid-dictation (e.g. AirPods connecting).
- Launch at login.

---

## Requirements

- **macOS 26 (Tahoe) or later** — SpeechAnalyzer is new in macOS 26.
- **Apple Silicon Mac** recommended. (If Apple's newer `SpeechTranscriber` model isn't
  available on a machine, HoTTy falls back to `DictationTranscriber`.)
- **Xcode 26** (for the Swift 6 toolchain and macOS 26 SDK).
- A trackpad for the hold gestures (press & hold also works with a mouse).

---

## Install

```bash
brew install justanotheratom/tap/hotty
```

Update with `brew upgrade hotty`. Releases are signed with Developer ID and notarized by
Apple, so they open without Gatekeeper warnings. You can also download the zip from
[Releases](https://github.com/justanotheratom/hotty/releases) and drag `HoTTy.app` into
`/Applications`.

## Build from source

```bash
git clone https://github.com/justanotheratom/hotty.git
cd hotty
scripts/build.sh --run
```

`scripts/build.sh` builds a release binary with SwiftPM, wraps it into
`build/HoTTy.app`, signs it, and (with `--run`) launches it. It's a development build named
**HoTTy Dev** (`llc.fungee.hotty.dev`, also what Xcode's Debug configuration uses), so it
keeps its own permissions and settings next to a Homebrew install. HoTTy shows in the Dock and
in the menu bar (the H icon); click either to open it. It can also be built and run
from Xcode: open `HoTty.xcodeproj` and press ⌘R.

**Code signing.** The script signs with the first *Apple Development* identity in your
keychain, falling back to ad-hoc signing. Use a real identity if you can: macOS ties the
Accessibility permission to the signature, so with ad-hoc signing you have to re-grant it
after every rebuild. To pick an identity explicitly:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build.sh --run
```

**First launch — grant permissions** (for Homebrew installs too). macOS will ask for:
1. **Accessibility** — to detect text fields, see the trackpad hold, and type text.
   System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable HoTTy (or HoTTy Dev). HoTTy picks it
   up within a couple of seconds; no restart needed.
2. **Microphone** — to hear you.
3. **Speech Recognition**, if prompted.

The first dictation in a language downloads Apple's on-device speech model (Settings
shows the status).

To keep it running across restarts, turn on **Launch at login** in Settings, or copy
`build/HoTTy.app` to `/Applications` first.

---

## How to use

1. Put the pointer on a text field (or on selected text you want to replace).
2. **Hold** — press and keep pressed, or rest one finger, depending on your setting.
   A short sound and a small overlay near the pointer mean it's listening.
3. **Talk.**
4. **Let go** to finish — or drag right first to also press Return, left to cancel, or
   up to switch to hands-free.

In **hands-free mode**, talk as long as you like and use the Mac normally; end with the
overlay's **Cancel**, **Finish** or **Send** button.

### Settings

Menu bar ▸ H icon ▸ **Settings…**

| Setting | Options |
|---|---|
| Hold gesture | Press & hold (click) · Rest finger (no click) |
| Hold for | 0.15–1.5 s |
| Ignore bottom edge | Rest-finger only: ignore touches where thumbs rest |
| While speaking | Preview overlay · Type live |
| Without a selection | Move caret to where I hold · Keep the current caret |
| Language | System, or any supported locale |
| Sounds | Start/stop sounds on or off |
| Launch at login | On/off |

Hold type and live-text mode can also be switched straight from the menu bar.

---

## Current limitations

**Platform and distribution**
- macOS 26+ only. Not on the Mac App Store: HoTTy needs Accessibility access and a
  system-wide event tap, which the App Store sandbox doesn't allow. Releases are signed with
  Developer ID and notarized, and ship through Homebrew.
- **Rest-finger mode uses Apple's private `MultitouchSupport` framework**, with a data
  layout that was reverse-engineered. A macOS update could break it; press & hold uses
  only public APIs.

**Holding and gestures**
- Press & hold: a normal click on a text field reaches the app when you release it, so
  it's delayed by the length of the click. Clicks elsewhere aren't delayed.
- Because drags during a hold are gestures, you can't pause and then drag to select text
  in press & hold mode — if a hold catches you, drag left and release to cancel.
- Rest-finger mode can occasionally trigger if you rest a finger still on a text field
  while thinking; a click before you speak cancels it silently.
- Some system gestures (swiping between desktops, Mission Control) are handled by macOS
  and can't be intercepted.

**Text fields and typing**
- Text-field detection relies on Accessibility. Apps that don't expose their text fields
  (custom-drawn editors, games, some terminals) may not trigger, and "replace the
  selection under the pointer" needs the app to report selection bounds.
- Text is entered as synthesized keystrokes: each chunk is its own undo step, and in
  "Type live" mode autocomplete or autocorrect popups can interfere.
- **Send is plain Return** — it sends in chat apps and search boxes but inserts a newline
  in documents and email bodies; apps that send with ⌘Return won't send.
- Cancel restores text by counting what HoTTy typed; if an app autocorrects or reformats
  during dictation, the restore can be off. In hands-free mode, Cancel only removes text
  typed since you last returned to the field.
- The mid-sentence lowercasing heuristic can lowercase a proper noun that starts a phrase.

**Recognition**
- Languages are limited to what Apple's SpeechAnalyzer supports (~22 languages).
- No AI cleanup (filler removal, rephrasing) and no voice commands.
- With AirPods as the microphone, the first dictation can start about a second late while
  Bluetooth switches modes.

**Hands-free**
- No automatic stop: the microphone stays on until you press Cancel, Finish or Send.

**Project**
- No automated test suite yet — there are self-test modes (below) that drive the real app.

---

## How it works

| Component | Role |
|---|---|
| `ClickHoldTrigger` | Session event tap on its own thread. Holds back mouse-downs over text fields; a release or movement before the hold duration replays them as a normal click or drag, otherwise the app never sees the press (which keeps a selection intact). After recognition, drags steer the release gesture. |
| `TouchHoldTrigger` | Raw contacts from `MultitouchSupport` (loaded with `dlopen`). One still finger for the hold duration triggers; tracks one pad per gesture, rescans for pads every 3 s, re-registers after wake. |
| `AX` | Accessibility helpers: find the editable element under the pointer (walking up, and searching down for Chromium UI), selection bounds, text before the caret, focus checks. |
| `DictationEngine` | Microphone → format conversion → `SpeechAnalyzer` with `SpeechTranscriber` (fallback `DictationTranscriber`). Audio is buffered while the analyzer starts; capture restarts on device changes. |
| `TextInjector` | Serial queue typing Unicode keystrokes; diffs volatile text for minimal backspacing; spacing/capitalization; checks the target still has focus before every phrase; pause/resume; revert. |
| `Coordinator` | Session state machine: hold → caret/selection → listen → type → release gesture → finish/send/cancel/lock. |
| `Overlay` | Fixed-size, non-activating, never-key panel (resizing SwiftUI-hosted windows caused layout-loop crashes); buttons clickable only over the visible box. |

---

## Development

```bash
swift build                 # compile only
scripts/build.sh            # build and sign build/HoTTy.app
scripts/build.sh --run      # …and relaunch it
```

### Debug and self-test modes

Launch through `open` so macOS attributes privacy prompts to HoTTy (running the binary
directly from a shell aborts on a privacy check):

```bash
open --env HOTTY_DEBUG_TOUCH=1 --stdout /tmp/hotty.log --stderr /tmp/hotty.log build/HoTTy.app
```

| Variable | What it does |
|---|---|
| `HOTTY_DEBUG_TOUCH` | Logs raw trackpad contacts, pad registration, and rest-finger state changes |
| `HOTTY_DEBUG_AX` | Logs the Accessibility role chain under the pointer every second — use it when a text field isn't detected |
| `HOTTY_OVERLAY_DEMO` | Runs six fake sessions through the overlay and menu bar icon at dictation speed |
| `HOTTY_AUDIO_TEST` | Runs three start/finish recording cycles on the current input device |
| `HOTTY_GESTURE_TEST` | In a focused **TextEdit** document (refuses any other app): replace a selection then cancel, then dictate and send |
| `HOTTY_LOCK_TEST` | In a focused **TextEdit** document: hands-free session with simulated phrases while focused and while Finder is in front, then clicks the overlay's Finish button |

The TextEdit tests type real keystrokes, so they refuse to run unless TextEdit is the
focused app — don't type while they run.

### Releasing

Push a version tag and GitHub Actions does the rest
([release.yml](.github/workflows/release.yml)):

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The workflow builds for Apple silicon and Intel, signs with the FUNGEE LLC Developer ID
certificate, notarizes and staples, uploads `HoTTy-<version>.zip` to this repo's GitHub
Releases, and updates `Casks/hotty.rb` in
[justanotheratom/homebrew-tap](https://github.com/justanotheratom/homebrew-tap). It needs
these repository secrets:

| Secret | Contents |
|---|---|
| `APPLE_CERTIFICATE` | base64 of the *Developer ID Application* `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `NOTARYTOOL_KEY` | base64 of the App Store Connect API key (`AuthKey_XXXX.p8`) |
| `NOTARYTOOL_KEY_ID` | that key's ID |
| `NOTARYTOOL_ISSUER` | the App Store Connect issuer ID |
| `TAP_DEPLOY_KEY` | private half of a write deploy key on `justanotheratom/homebrew-tap` |

The version comes from the tag; the committed `Info.plist` version isn't changed, so bump
it in a commit too if you want local builds to match.

To release from your own Mac instead, one-time setup:

1. A **Developer ID Application** certificate: Xcode › Settings › Accounts › Manage
   Certificates › + › Developer ID Application.
2. An app-specific password from [account.apple.com](https://account.apple.com), saved
   to the keychain (you'll be prompted for it; don't put it in a script):
   ```sh
   xcrun notarytool store-credentials hotty-notary --apple-id <you@example.com> --team-id 58MYNHGN72
   ```
3. `gh auth login` with write access to the tap repo.

Then, for each release:

```sh
./scripts/release.sh 0.2.0            # build, sign, notarize, zip, write the cask; uploads nothing
./scripts/release.sh 0.2.0 --publish  # the same, then GitHub release + tap update
```

The script sets the version in `Info.plist` and the Xcode project, builds for Apple
silicon and Intel, and puts the zip in `dist/`. Commit the version bump afterwards.
`--no-notarize` makes a local test build signed with your development certificate.

### Launch video

`docs/hotty-launch.mp4` and `docs/hotty-launch.gif` are rendered from
[`design/launch-video/scene.html`](design/launch-video/scene.html), a scripted animation
of HoTTy's UI (open it in a browser to preview it playing). To re-render after editing it,
with ffmpeg, Google Chrome and `playwright-core` installed:

```sh
cd design/launch-video
node render.mjs video ../../docs/hotty-launch.mp4
node render.mjs gif ../../docs/hotty-launch.gif
```

### Contributing

Work on a branch and open a pull request against `main`. Please test the flows your
change touches in a few apps (a native app like TextEdit or Notes, a Chromium browser,
and an Electron app) and with both hold types, and note in the PR what you tried.

---

## License

HoTTy is free and open source under the [MIT License](LICENSE).
