# Mac Voice Assistant

Talk to your Mac: dictate into any app, control apps hands-free with **"Hey Jarvis"**, keep ideas, to-dos and
reminders on a voice **idea board**, and ask an AI brain that runs on your Mac for anything else.

**Status: in development.** There's nothing to install yet. This is the Mac version of
[Windows Voice Assistant](https://github.com/shivam098/windows-voice-assistant); the design and the plan are in
[docs/design.md](docs/design.md).

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

## Develop

A Swift package for macOS 13 or later. GitHub's macOS runners build and test it on every change, and daily against the
newest thumbfree-mac:

```sh
swift build
swift test
```
