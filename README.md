# Mac Voice Assistant

Talk to your Mac: dictate into any app, control apps hands-free with **"Hey Jarvis"**, keep ideas, to-dos and
reminders on a voice **idea board**, and ask an AI brain that runs on your Mac for anything else.

**Status: in development.** Test builds come as pre-releases: see [Install a test build](#install-a-test-build). This is
the Mac version of [Windows Voice Assistant](https://github.com/shivam098/windows-voice-assistant); the design and the
plan are in [docs/design.md](docs/design.md).

Everything will run **on your Mac**: speech is recognised locally and the AI model runs on the Mac's graphics chip.
Nothing you say is uploaded, and there's no account.

## What it will do

- **Dictate anywhere.** Tap **Fn (🌐)**, speak, and tap it again: your words are typed into the app you're using,
  cleaned up and punctuated, in English or Hindi + English. This is ThumbFree's dictation, from
  [thumbfree-mac](https://github.com/shivam098/thumbfree-mac).
- **"Hey Jarvis".** Open and switch apps, start typing in the right box and send, go to a tab by position or name,
  click buttons by name or by number, and edit what you've typed ("delete the last three words", "replace Monday with
  Tuesday").
- **Idea board.** "Add renew passport to my to-do list", "remind me to call mom tomorrow at 5 pm".
- **AI brain.** Requests the commands don't cover ("open the MrBeast video on YouTube", "reply thanks to Rahul on
  WhatsApp") are planned by a small language model on your Mac, which asks before it sends, deletes or closes anything.

It follows the same specs as Windows
([docs/specs](https://github.com/shivam098/windows-voice-assistant/tree/main/docs/specs)), with Mac shortcuts (⌘ where
Windows uses Ctrl).

## Voice Assistant and ThumbFree

ThumbFree for Mac is the dictation-only app: no wake word, and the microphone is on only while you dictate. Both apps
use the same dictation engine and the same key, Fn, so run one at a time; each one tells you if the other is running.

## Install a test build

Test builds are for trying Jarvis on a Mac before it's finished, and saying what breaks. They're for macOS 13 or later,
on Apple silicon and Intel Macs; the AI brain needs Apple silicon and macOS 13.3 or later.

1. From the latest pre-release on the [Releases](https://github.com/shivam098/mac-voice-assistant/releases) page,
   download `VoiceAssistant-<version>.dmg` and `SHA256SUMS`, and check the download: `shasum -a 256 -c SHA256SUMS`.
2. Open the `.dmg` and drag Voice Assistant to Applications. Test builds are signed ad hoc, not by Apple, so the first
   time, open it, then choose System Settings › Privacy & Security › **Open Anyway**.
3. Give it the microphone and Accessibility: the window opens at Home, which lists them, each with a button that asks
   macOS. The first run downloads the speech models (about 265 MB).

[docs/testing.md](docs/testing.md) has each step, the checklist to test it with, and how to report a problem.

## Develop

A Swift package for macOS 13 or later. GitHub's macOS runners build and test it on every change, and daily against the
newest thumbfree-mac:

```sh
swift build
swift test
```

Releases are built by CI. The Release workflow, run by hand on `main`, builds the app as the App workflow does (below)
and publishes `VoiceAssistant-<version>.dmg` and `SHA256SUMS`, with `docs/release-notes/v<version>.md` as the notes, as
the pre-release `v<version>`. By default it's a dry run, which keeps the files as the run's artifact instead.
`scripts/check-release.sh` refuses a version that isn't the app's (`VoiceAssistantCore.version`), and a real release
unless it was started on `main` and `Package.swift` pins thumbfree-mac to a commit; a tag or a release that exists is
never replaced.

`scripts/make-app.sh` builds `Voice Assistant.app` (Apple silicon and Intel, signed ad hoc) and
`VoiceAssistant-<version>.dmg` in `dist/`. The App workflow runs it for every pull request and every change to `main`
that touches the app, and keeps the `.dmg` as the run's artifact (`VoiceAssistant-dmg`). To try one, open the `.dmg`,
drag the app to Applications, open it, and the first time choose System Settings › Privacy & Security › Open Anyway.
It opens at Home, with its icon in the menu bar and the status pill at the bottom of the screen. Home lists what macOS
hasn't allowed yet, each with a button that asks for it: the microphone, and Accessibility (System Settings › Privacy &
Security › Accessibility) to open apps and type. The first time, it downloads the speech model (about 264 MB). Then
"Hey Jarvis" and tap-to-dictate with Fn work, reminders pop up as cards, and what happens is in the log
(`~/Library/Logs/VoiceAssistant`). "Show numbers" draws its numbers over the app in front; the idea board's page isn't
there yet. The settings are in `~/Library/Application Support/VoiceAssistant/settings.json`. The App workflow also opens
the app on the runner and checks that it starts into its UI (`scripts/launch-check.sh`), keeping its log and a
screenshot as the run's artifact (`launch-check`).

The self-test ([docs/self-test.md](docs/self-test.md)) runs scripted transcripts through the real controller and
desktop, as the acceptance labs do. The TextEdit lab opens TextEdit, types into it and quits it, so leave the Mac alone
while it runs (and give Terminal Accessibility):

```sh
swift package update     # thumbfree-mac at the tip of its main, as CI uses it (Package.resolved isn't committed)
swift build -c release
tests/TextEditLab/run.sh .build/release/VoiceAssistant
```

The Self-test workflow runs the labs on GitHub's runners for pull requests that touch the app, with each lab's result
in the job's summary, and keeps their output and the app's log as the run's artifact (`self-test-results`).
