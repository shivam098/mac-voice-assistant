# Agent instructions

Jarvis for Mac (the app is called Voice Assistant; you wake it with "Hey Jarvis"): hands-free voice control for macOS,
ported from shivam098/windows-voice-assistant. It's a Swift package for macOS 13 and later (VoiceAssistantBoard,
VoiceAssistantCore, VoiceAssistantMac, VoiceAssistantApp and the VoiceAssistant app), and its dictation comes from
shivam098/thumbfree-mac.

**On a real Mac?** Start with [docs/HANDOFF-mac.md](docs/HANDOFF-mac.md): where the project stands, and how to finish
testing and set the app up.

- Build and test: `swift package update`, `swift build -c release` and `swift test`. The tests that act on the Mac or
  download a lot run only when asked (docs/HANDOFF-mac.md, section 3). Build the app with `scripts/make-app.sh`.
- The design and its phases are in docs/design.md.
- Commit as `shivam098 <39924466+shivam098@users.noreply.github.com>`.
- One PR per change, with CI green and an independent review before merging (squash). PR descriptions start with the
  owner's Agent assessment block (docs/HANDOFF-mac.md, section 7). Other agents may be working in this repo too: check
  `gh pr list` before changing files.
