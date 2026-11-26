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
- Reminders pop up as cards in the bottom-right corner, as on Windows, with **Done**, **Snooze 10 min** and **Open
  board**: floating panels that never take the focus and stay until they're answered, which Notification Center's
  banners don't, and they need no permission.
- The window looks as on Windows and stays light whatever the Mac's appearance. Closing it hides it (the assistant
  keeps running in the menu bar), **Settings…** is ⌘, and **Quit Voice Assistant** is ⌘Q. Home adds a card for the
  permissions macOS hasn't given yet (the microphone, Accessibility, and Input Monitoring when the Fn key needs it),
  whose buttons ask macOS, then open System Settings. The window opens at Home when the app starts, unless it started
  at login, and then too while a permission is missing.
- What Windows says in tray balloons (a hotkey another app has, the Fn key the app can't see yet, ThumbFree running too,
  a failed restart, a change the board can't save) shows in a balloon under the menu bar icon, one at a time as
  Windows shows them: what's said at the same moment waits its turn. While ThumbFree runs with the same key, the menu
  also says so under its status line, until ThumbFree quits.
- The idea board's notes are dragged as AppKit drags (`NSDraggingSource`), which only the board accepts: a note can't
  be dropped into another app. The pointer over a note is the open hand.

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
- **Browser tabs:** Chrome, Edge, Brave and the other Chromium browsers describe their tab strips to Accessibility, as
  Firefox does. Their pages, and Electron apps', may be described only once an assistive app asks
  (`AXEnhancedUserInterface`, `AXManualAccessibility`): the host's ThumbFree reader asks each app that comes to the
  front, and a scan asks one the desktop hasn't asked yet; any scan within 2.5 s of the ask waits for the page. Chromium
  turns its page descriptions on 2 s after the last ask, and answers each ask with "no such attribute" while acting on
  it, so each browser is asked once. Safari's tabs come from AppleScript, which needs the Automation permission;
  it's asked for the first time Safari's tabs are wanted, and they're listed from then on.
- **Clicking by name and the numbers:** a scan walks the window's Accessibility tree, as UI Automation's `FindAll`
  does on Windows: the buttons, links, tabs, menu items, checkboxes, radio buttons, pop-up buttons and rows that are
  enabled, named and show (inside the window and every scroll area around them), at most 1,500. A click uses
  Accessibility's own actions (`AXPress`, `AXSelected`, `AXDisclosing`), as Windows uses UI Automation's patterns.
  Rows get a real click when it lands on them: a web chat list opens a chat only then, and Finder's sidebar goes to the
  folder only then (an app's row only when the click lands on the row or its text, never on a checkbox or button in
  it). Anything whose action the app refuses gets one too, only where the click lands in the window, which
  Accessibility's system-wide hit test says (the window server's list can't tell which windows let clicks through:
  the Dock's spans the screen). Jarvis's own pill, reminder cards and balloons cover what's under them, as on Windows.
  An action the app doesn't answer in time isn't followed by a click: the app may be doing it still (AppKit runs a
  pop-up button's menu inside the press). The numbers and the click outline are a borderless panel above other
  windows that clicks go through, that never takes the focus, and that stays when Jarvis hides (closing its window
  hides the app), as the pill and the reminder cards do.
- **The AI brain's windows** (`listWindows`, `activateWindow`): the standard windows of the apps in the Dock, and of
  the app in front, front-most first with the one taking the keys first of all, at most 12, as on Windows. Minimized
  windows count, and a hidden app's too, as minimized; so does a window without a title, which Windows skips (a Mac
  app's only window can have none). macOS calls a minimized window, and every window of a hidden app, a dialog, as it
  calls an alert, so in a hidden app only a window that can be minimized counts. The list waits on apps, which
  Windows' doesn't: it asks them for 1.5 s, the app in front first, then by their front-most window on screen, so time
  running out cuts the back of the list, as Windows cuts it; it describes the windows until 3 s, inside the 4-second
  limit, and lists any it didn't reach with what's known. An app that doesn't answer isn't asked again. Bringing a
  window to the front unhides its app and restores it first.
- **Where it never types:** password fields and secure input, as everywhere. The brain's no-go places become Terminal
  and other terminals, Spotlight and Finder; in a browser it types only inside the page (an `AXWebArea` ancestor),
  never into the address bar.
- **Back and forward** (⌘[ and ⌘]) are pressed only in browsers and Finder: elsewhere those keys change the indent or
  list level (Notes, Mail, Pages, Xcode, VS Code), so the pill says "Back works in browsers and Finder."
- **What the desktop layer must supply** (the core's `JarvisDesktop`, settled in the core's reviews):
  - the app with the **keyboard focus** (the Accessibility focused application), by **bundle ID**: Spotlight,
    launchers and a notification's reply take the keys while another app stays in front, and localized or
    executable names vary;
  - the app's display name (`NSRunningApplication.localizedName`), since Mac window titles don't end in the app's
    name;
  - the window's **default button** (`AXDefaultButton`), because Return presses it whatever has the focus;
  - a chord presser for the core's Mac chords: letters typed by the current keyboard layout, `[` and `]`, "Delete" as
    ⌦ and "Backspace" as ⌫ (ThumbFreeMac's chord reader handles only the new-line keys), and F1 to F20: the core never
    asks for F21 to F24, which Macs don't have;
  - **typing with line breaks** as one call (`typeText(_:newLineKeys:)`), which every typing and the "new line" command
    use: under secure input (a password being typed, Terminal's Secure Keyboard Entry) nothing of it goes out, its
    line breaks included, while keys asked for by name ("press enter", the brain's keys) still do, as on Windows;
  - a **zoom** for the window in front (`zoom`): the brain's plans maximize with Win+Up, which no Mac key does.
- **The core's threading contract:** the app awaits each controller call before making the next, drops speech while
  the brain is running, and acts on `ControllerBusy` (a call that overlapped did nothing and says so).

## The AI brain

- llama.cpp build **b12483**, as on Windows: `llama-b12483-bin-macos-arm64.tar.gz` (17.2 MB, SHA-256 `a7e77443…`),
  and the same model file, `Qwen3-4B-Instruct-2507-Q4_0.gguf` (2.4 GB, SHA-256 `e0ba675d…`). Each is downloaded once,
  on request, and checked. Q4_0 was chosen for the Snapdragon's graphics chip; on Metal, Q4_K_M is measured against it
  with the brain's test requests before the first release.
- It runs on 127.0.0.1 with a random port and key, unloads after an hour unused, and keeps every safety limit from the
  core: it acts only after "Hey Jarvis", asks for a **yes** before sending, deleting, buying, closing, opening a program
  or typing more than 200 characters, stops after 8 steps or 30 seconds, and **Esc** stops it at once.
- **The Mac's guardrails** (the core's `BrainPlatform.mac`, required by the desktop, with no fallback to Windows'):
  - Apps are matched by bundle ID: terminals, launchers (Spotlight, Raycast, Alfred, LaunchBar), script runners
    (Script Editor, Automator, Shortcuts), System Settings, Activity Monitor, Disk Utility, Keychain Access, Passwords,
    Finder and the login and password prompts are no-go places.
  - The prompt and plans still name keys as on Windows (the prompt is Windows' byte for byte, as measured). Each
    chord is translated to its Mac chord and judged as pressed: ⌘Space, ⌥⌘⎋, ⌘Q, ⇧⌘Q, ⌃⌘Q, Trash and screenshot
    chords are refused, and ⌘W asks. The core presses only the chord it judged. Win+Up (maximize) zooms the window in
    front instead; the other Win chords have no Mac key, and a Mac keyboard has no F21 to F24, so those are refused.
  - A "yes" is needed for Backspace outside a text box, "Force Quit", "Open Anyway", Mac program files (`.app`,
    `.command`, `.pkg`, …), and for Return when the window's default button sends, deletes or runs something, or
    can't be read.
  - A Mac version of the prompt and the key rules is measured with the brain's test requests in phase 5.
- Apple silicon first. Whether 8 GB Macs and Intel Macs run it usefully is measured before it's offered there.

## Permissions

Microphone; **Accessibility** (to read and control other apps, and for the Fn key's tap); **Input Monitoring** only if
the Fn tap has to fall back to listening; and **Automation** for Safari, only if you use Safari tabs. The first-run
guide explains each one, like ThumbFree's.

## Testing

- **GitHub's macOS runners:** the ported unit tests on every change (the core's with a fake desktop, as on Windows),
  the app build, the desktop's integration tests in other apps, and the self-test's labs through the app: TextEdit, and
  the navigation acceptance tests
  ([acceptance-tests.md](https://github.com/shivam098/windows-voice-assistant/blob/main/docs/specs/acceptance-tests.md)
  N1–N9) on the same `tests/NavigationLab` pages in Chrome and Safari ([self-test.md](self-test.md)). A daily build
  catches a change in thumbfree-mac that breaks this app.
- **A real Mac:** the same NavigationLab runs, plus a checklist for the microphone, the permissions, the wake word, Fn
  and the brain: [testing.md](testing.md), which also says how to install a test build.

## Phases

| Phase | Done when | Status (November 2026) |
|---|---|---|
| 1. Board in Swift | The ported board tests pass on macOS CI. It needs nothing else, so it starts now | Done |
| 2. Core in Swift | The ported core tests pass on macOS CI, on ThumbFree's Swift core (thumbfree-mac phase 1) | Done: every C# core test is ported, the brain's controller tests also run with the Mac's rules, and differential runs matched the C# |
| 3. Desktop layer | Apps, windows, Accessibility scans, clicks, tabs, focus and shortcuts work in the NavigationLab pages on a real Mac | Done on GitHub's Mac: part 1 (apps, windows, keys, typing and focus), part 2 (navigation: scans and clicks, browser tabs, the numbers) and part 3 (the AI brain's window list and switching, so the Mac implements all 18 of the core's desktop requirements; the NavigationLab's acceptance tests N1–N9, with N10 and N16, pass through the app's self-test in Chrome and Safari, 33 checks each). The integration tests pass in Chrome, Edge, Safari, Finder, TextEdit and System Settings. The real-Mac checklist ([testing.md](testing.md)) is pending |
| 4. App | Menu bar, wake word and commands, the pill, Fn dictation (thumbfree-mac phases 2 and 3), the window and the idea board, reminders | Built: the menu bar, the pill, the reminder cards and the window (Home with its permissions card, the idea board, Settings and What you can say), drawn on CI and wired to the assistant; the App workflow checks that the app starts into them, and the self-test drives TextEdit through it. The real-Mac checklist ([testing.md](testing.md)) is pending |
| 5. AI brain | The brain's test requests come out right as often as on Windows, on an Apple silicon Mac | |
| 6. Test builds and release | As for ThumbFree for Mac: a `.dmg` from CI, the real-Mac checklist, then Developer ID and notarization (the hardened runtime then needs the `com.apple.security.automation.apple-events` entitlement for Safari's tabs through AppleScript) | Test builds: the v0.1.0 pre-release, from the Release workflow (thumbfree-mac pinned, Xcode 16.4). The real-Mac checklist is pending; Developer ID and notarization need a paid Apple Developer account |
