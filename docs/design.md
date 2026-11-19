# Mac Voice Assistant: design and plan

What the assistant does is specified once, for every platform, in windows-voice-assistant's
[docs/specs](https://github.com/shivam098/windows-voice-assistant/tree/main/docs/specs). How each Windows capability
maps to macOS APIs is in its
[platform porting guide](https://github.com/shivam098/windows-voice-assistant/blob/main/docs/specs/platform-porting.md).
This page records the Mac decisions made since, the shape of the code, and the order of work.

## Decisions (November 2026)

- **Two Mac apps, one dictation engine.** ThumbFree for Mac, the dictation-only app, is built first, in
  [thumbfree-mac](https://github.com/shivam098/thumbfree-mac) (the porting guide's step 3, "the dictation-only app").
  This app depends on its Swift packages for everything dictation needs: formatting, emails and lists, live typing and
  the field rules (`ThumbFreeCore`); the speech engines and model downloads (`ThumbFreeSpeech`); and the Fn key, the
  microphone, reading and typing into the text box, the pill and the permissions (`ThumbFreeMac`). Only the
  assistant's own parts live here.
- **The same key as ThumbFree: Fn (🌐),** tap to start and tap again to finish, as the porting guide planned. Run one
  app at a time; each one warns you when the other is running.
- **Dictation is ThumbFree's.** Jarvis on Windows has its own copies of the formatter and `TranscriptText`. The Mac
  uses ThumbFreeCore's, which is held to the shared test data on every ThumbFree platform and has the same options and
  `Format` call, and adds only what is Jarvis's own: snippets.
- **The core is Swift,** ported from `src/VoiceAssistant.Core` and `src/VoiceAssistant.Board` together with their
  unit tests (same inputs, same expected outputs), as ThumbFree's core is ported from C#.
- **The AI brain comes to the Mac too** (the porting guide still lists it as not ported): llama.cpp's `llama-server`
  with Metal, and the same model, prompt and safety limits as Windows.

## Shape

| Swift target | Ported from (windows-voice-assistant) | Uses |
|---|---|---|
| `VoiceAssistantBoard` | `src/VoiceAssistant.Board`: notes, lists, reminder times, the board's voice grammar, the JSON store | Nothing |
| `VoiceAssistantCore` | `src/VoiceAssistant.Core`: command parser and wake word, navigation and editing grammars, text editing, utterance segmenter, phrase memory, app catalog, screen summary, the brain's prompt and plan reader, the interaction controller, and the `IDesktop` interface | Board, ThumbFreeCore |
| `VoiceAssistantMac` | The Windows `IDesktop` (Win32 and UI Automation in `src/VoiceAssistant.App`), rebuilt on `AXUIElement`, `NSWorkspace` and `CGEvent`; the number badges and click outlines; the brain's `llama-server` and its download | Core, ThumbFreeMac |
| `VoiceAssistant` (the app) | The menu-bar app: the pill, the window (Home, Idea board, Settings, What you can say), reminders | Everything, ThumbFreeSpeech |

- Settings, the board and what it has learned go in `~/Library/Application Support/VoiceAssistant`, in the same files
  and formats as Windows (`settings.json`, `board.json`, `learned.json`). Logs hold states and timings, never words.
- Reminders become notifications (`UNUserNotificationCenter`) with **Done**, **Snooze 10 min** and **Open board**,
  scheduled with macOS so they appear on time.

## Speech

- **Dictation** uses ThumbFree's models and engines (Kroko, Parakeet, and the Hindi + English Whisper models).
- **"Hey Jarvis" and commands** start on whisper.cpp with the same `small.en` model and Silero filter as Windows, so the
  command measurements in
  [BENCHMARKS.md](https://github.com/shivam098/windows-voice-assistant/blob/main/docs/BENCHMARKS.md) carry over.
  Parakeet is compared with it on the same recordings before the first release.
- Listening for "Hey Jarvis" keeps the microphone on, so macOS shows its orange microphone dot. **Pause listening**
  turns the microphone off; Fn dictation still works while paused, as Ctrl+Win does on Windows.

## The Mac desktop layer

The porting guide's capability map is the plan. These are the points it leaves open:

- **Mac shortcuts:** ⌘C, ⌘V, ⌘X, ⌘Z, ⇧⌘Z, ⌘A and ⌘S for editing; ⌘T, ⌘W and ⌘R for tabs; ⌘[ and ⌘] for back and
  forward; ⌘↑ for the parent folder in Finder. "Maximize this window" zooms the window to fill the screen through
  Accessibility, instead of Win+Up. The built-in app list (`apps` in settings) gets Mac keys, and TextEdit, Notes and
  Safari join the apps that exist on both.
- **Finding apps:** the app bundles in `/Applications`, `/System/Applications` and `~/Applications`, by name and display
  name, instead of the Start menu. Misheard names are matched as on Windows.
- **Browser tabs:** Chrome, Edge and Brave describe their tabs to Accessibility once `AXEnhancedUserInterface` is set
  (the porting guide's starred item: measure it first). Safari's tabs come from AppleScript, which needs the Automation
  permission; it's asked for the first time you ask for a Safari tab.
- **Where it never types:** password fields and secure input, as everywhere. The brain's no-go places become Terminal
  and other terminals, Spotlight and Finder; in a browser it types only inside the page (an `AXWebArea` ancestor),
  never into the address bar.

## The AI brain

- llama.cpp build **b12483**, as on Windows: `llama-b12483-bin-macos-arm64.tar.gz` (17.2 MB, SHA-256 `a7e77443…`),
  and the same model file, `Qwen3-4B-Instruct-2507-Q4_0.gguf` (2.4 GB, SHA-256 `e0ba675d…`). Each is downloaded once,
  on request, and checked. Q4_0 was chosen for the Snapdragon's graphics chip; on Metal, Q4_K_M is measured against it
  with the brain's test requests before the first release.
- It runs on 127.0.0.1 with a random port and key, unloads after an hour unused, and keeps every safety limit from the
  core: it acts only after "Hey Jarvis", asks for a **yes** before sending, deleting, buying, closing, opening a program
  or typing more than 200 characters, stops after 8 steps or 30 seconds, and **Esc** stops it at once.
- Apple silicon first. Whether 8 GB Macs and Intel Macs run it usefully is measured before it's offered there.

## Permissions

Microphone; **Accessibility** (to read and control other apps); **Input Monitoring** (Fn); and **Automation** for
Safari, only if you use Safari tabs. The first-run guide explains each one, like ThumbFree's.

## Testing

- **GitHub's macOS runners:** the ported unit tests on every change (the core's with a fake desktop, as on Windows),
  and the app build. A daily build catches a change in thumbfree-mac that breaks this app.
- **A real Mac:** the navigation acceptance tests
  ([acceptance-tests.md](https://github.com/shivam098/windows-voice-assistant/blob/main/docs/specs/acceptance-tests.md)
  N1–N9) with the same `tests/NavigationLab` pages in Chrome and Safari, plus a checklist for the microphone, the
  permissions, the wake word, Fn and the brain.

## Phases

| Phase | Done when |
|---|---|
| 1. Board in Swift | The ported board tests pass on macOS CI. It needs nothing else, so it starts now |
| 2. Core in Swift | The ported core tests pass on macOS CI, on ThumbFree's Swift core (thumbfree-mac phase 1) |
| 3. Desktop layer | Apps, windows, Accessibility scans, clicks, tabs, focus and shortcuts work in the NavigationLab pages on a real Mac |
| 4. App | Menu bar, wake word and commands, the pill, Fn dictation (thumbfree-mac phases 2 and 3), the window and the idea board, reminders |
| 5. AI brain | The brain's test requests come out right as often as on Windows, on an Apple silicon Mac |
| 6. Test builds and release | As for ThumbFree for Mac: a `.dmg` from CI, the real-Mac checklist, then Developer ID and notarization |
