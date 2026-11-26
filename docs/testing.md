# Testing Jarvis for Mac on a real Mac

GitHub's Macs build Jarvis for Mac (the app is called Voice Assistant; you wake it with "Hey Jarvis") on every change,
run its tests, open the app to check that it starts into its menu bar icon, pill and window, and drive TextEdit, the
browsers, Finder and System Settings through it. But they have no microphone, nobody to speak or give permissions, and
no graphics chip the AI brain can use. This page is for a person with a Mac: how to install a test build, and one
checklist to test it with. Tick what works, and report what doesn't (see the end).

A coding agent on a Mac starts with [HANDOFF-mac.md](HANDOFF-mac.md): how to build, the tests that need a real Mac, and
how to record results.

## Install a test build

1. **Get the `.dmg`.** On the [Releases](https://github.com/shivam098/mac-voice-assistant/releases) page, open the
   latest pre-release and download `VoiceAssistant-<version>.dmg` and `SHA256SUMS`, or, with the GitHub CLI,
   `gh release download v0.1.0 --repo shivam098/mac-voice-assistant`. It's a universal build, for Apple silicon and
   Intel Macs, macOS 13 or later. (Builds between releases: the **VoiceAssistant-dmg** artifact of the latest App
   workflow run on `main` is a zip with the `.dmg` inside, and no SHA256SUMS.)
2. **Check the download.** In Terminal, in the folder with both files:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

   It should say `VoiceAssistant-<version>.dmg: OK`. If it says anything else, don't open the `.dmg`: download it
   again, and report it if it happens again.
3. **Install it.** Open the `.dmg` and drag Voice Assistant to Applications. If an older test build is running, quit it
   first.
4. **Open it the first time.** Test builds are signed ad hoc, not by Apple (they aren't notarized), so macOS blocks
   them: open Voice Assistant once, then go to System Settings › Privacy & Security and choose **Open Anyway**.
   (Right-click › Open no longer works on macOS 15 and later. A `.dmg` downloaded with `gh` isn't marked as coming from
   the internet, so macOS may not ask at all.)
5. **Permissions.** The window opens at Home, whose "Permissions needed" card lists what macOS hasn't allowed yet, each
   with **Allow…**, which asks macOS (and then, since macOS asks only once, **Open System Settings**):
   - the **microphone**, to hear "Hey Jarvis", commands and dictation;
   - **Accessibility** (System Settings › Privacy & Security › Accessibility), to read other apps' windows and
     buttons, to click them, and to press keys and type;
   - **Input Monitoring**, listed only while Accessibility isn't allowed, when the Fn key falls back to it. Whether Fn
     needs it on a real Mac is still to be found out, so note whether macOS asks for it.

   Safari's tabs also need **Automation**, which macOS asks for the first time you ask for one of them. The card follows
   System Settings within a few seconds, and goes once everything is allowed.
6. **Each new test build** needs Accessibility given again, because a test build's signature changes every time. If
   Accessibility looks on but Voice Assistant can't use it, run
   `tccutil reset Accessibility io.github.shivam098.voiceassistant` (or remove Voice Assistant from the list), then
   turn it on again.
7. **If Fn already does something** (System Settings › Keyboard › "Press 🌐 key to"), set it to **Do Nothing**. Or
   dictate with Right Option instead: quit Voice Assistant, set `"dictationKey": "RightOption"` in its settings.json,
   and open it again.
8. **The first run downloads the speech models:** Whisper small.en (about 264 MB) and the Silero voice detector (under
   1 MB), with the progress in the pill. The Hindi + English model (82 MB) downloads the first time you choose it, and
   the accurate one (874 MB) the first time you choose that. Models ThumbFree for Mac has already downloaded are used
   from its folder instead. The AI brain is a separate, optional 2.4 GB download, from Settings.
9. **Its files:** `settings.json`, `board.json` (the idea board), `learned.json` (what it has learned), `models/` and
   `brain/` are in `~/Library/Application Support/VoiceAssistant`; the logs are in `~/Library/Logs/VoiceAssistant`.
   The logs never contain your words.

Releases are built by CI: the Release workflow builds the `.dmg` on GitHub's macOS 15 runner, with Xcode 16.4 and
thumbfree-mac pinned to a commit, and checks that it starts. To build it from source instead (`scripts/make-app.sh`;
HANDOFF-mac.md sections 2 to 4), use Xcode 16.4 or later: CI builds with Xcode 16.4, and the owner's Mac with Xcode 26.6
(Swift 6.3.3), where it also needs [#19](https://github.com/shivam098/mac-voice-assistant/pull/19) until that is merged.

## Checklist

Each item says what to do, in bold, then what should happen. Where an item asks how long something takes, write it
down.

### First run and permissions

- [ ] **Open it the first time** (step 4 above). The window opens at Home with "Permissions needed", the status pill
  appears at the bottom of the screen, and its icon in the menu bar (there's no Dock icon).
- [ ] **Watch the first run's download.** The pill shows its progress; then macOS asks for the microphone. Allow it: the
  pill says it's waiting for "Hey Jarvis", and macOS's orange microphone dot is on. Afterwards
  `ls ~/Library/Application\ Support/VoiceAssistant/models` lists `ggml-small.en-q8_0.bin` and
  `ggml-silero-v6.2.0.bin`. How long did it take? With ThumbFree for Mac's models already on the Mac, the ones it has
  aren't downloaded again.
- [ ] **Home's Allow… buttons.** Each asks macOS; Accessibility's also puts Voice Assistant in System Settings' list,
  where it isn't before. After that the button says Open System Settings. Allow something in System Settings: within
  a few seconds Home's card follows, without clicking the window, and it goes once everything is allowed.
- [ ] **Tap Fn before Accessibility is on.** A notice by the menu bar icon says the key can't be seen yet. **Turn
  Accessibility on:** Fn works without a restart, and the notice doesn't come back.
- [ ] **Input Monitoring:** did macOS ask for it? Does Fn work without it once Accessibility is on?
- [ ] **Open Voice Assistant again while it runs** (from Applications, or `open -a "Voice Assistant"`). No second copy
  starts: the running one opens its window.

### The menu bar and the pill

- [ ] **Click the menu bar icon.** Its menu opens: Open Voice Assistant, Idea board, the status, Pause listening (or
  Start listening), Paste last dictation, Dictation language (English, Hindi + English — fast, and — accurate), What
  you can say, Settings…, Always show status pill, Start when I log in and Quit Voice Assistant; Copy text that wasn't
  typed shows only while there's some. The icon reads well on light and dark menu bars, and its dot follows the mode.
- [ ] **Open Voice Assistant** (the menu's first item). Its window opens: Home, the Idea board, Settings and What you
  can say.
- [ ] **Use it for a while.** The pill shows each state: waiting for "Hey Jarvis", listening for a command, typing,
  dictating (a level meter and your words), transcribing, paused. Messages go after a few seconds.
- [ ] **Click the pill's minimize button.** The pill hides until it's needed (it comes back for "Hey Jarvis", Fn and
  messages); menu › Always show status pill brings it back for good.
- [ ] **Try a full-screen app, and a second display if you have one.** The pill shows over full-screen apps and on the
  screen you're using, and never takes the keyboard from the app you're typing in.
- [ ] **Turn on Reduce motion** (System Settings › Accessibility › Display). The pill and the reminder cards appear
  without fading.

### "Hey Jarvis" and commands

- [ ] **Say "Hey Jarvis".** A short tone, and the pill shows it's listening for a command. Commands then work for 30
  seconds without saying it again. Talk without "Hey Jarvis" does nothing.
- [ ] **"Hey Jarvis, open Notes".** Notes opens, or comes to the front, with a new note. **"Switch to Safari"** brings
  Safari to the front.
- [ ] **In Notes: "start typing", say a sentence or two, then "send", then "stop typing".** The words are typed into
  the note as you pause, punctuated. "Send" says Notes has no send action (Notes is for writing); "stop typing" ends
  the typing.
- [ ] **In a chat that sends with Return** (Messages, or WhatsApp Web in Chrome, to yourself): **"start typing", a
  sentence, then "send".** The message is sent, and Voice Assistant goes back to listening for commands.
- [ ] **While typing: "new line", "scratch that", "delete the last two words", "replace the word Monday with
  Tuesday", "clear box".** Each does what it says to the text.
- [ ] **After "start typing" in Notes, click into another app and say a sentence.** Nothing is typed there; the menu
  offers Copy text that wasn't typed, which copies it.
- [ ] **In Safari and in Chrome: "new tab", "scroll down", "scroll up", "go back", "go forward", "refresh", "close
  tab".** Each presses the Mac's key for it (⌘T, Page Down, ⌘[ …). "Go back" in Notes says back works in browsers and
  Finder.
- [ ] **In a text box: "select all", "copy", "paste", "undo".** The ⌘ shortcuts.
- [ ] **"Maximize this window".** The window in front zooms to fill the screen (not full screen).
- [ ] **Speak naturally: "can you please open TextEdit for me".** TextEdit opens. Say something it doesn't know, then
  say it another way within 30 seconds: next time the first way works too.
- [ ] **"Hey Jarvis, pause listening".** The microphone turns off (the orange dot goes); ⌃⇧Space turns it on again.
- [ ] **In a password box (a sign-in page): "start typing", then a sentence.** Nothing is typed.

### Dictation with Fn

- [ ] **Click into a text box (Notes, TextEdit, Safari, Chrome, Mail, Slack, VS Code), tap Fn, speak, and tap Fn
  again.** A start tone; the pill shows a level meter, your words as you speak, and "Fn to finish · Esc to cancel".
  After the second tap, "Transcribing…", then the text is typed where you were, cleaned up and punctuated, after a
  space when there's text before the cursor.
- [ ] **Say "comma", "question mark" and "new line", and an "um".** Punctuation and a line break; the "um" is gone.
- [ ] **Tap Fn, speak, then press Esc.** Nothing is typed, and the app doesn't get the Esc.
- [ ] **Fn shortcuts: Fn+arrows, Fn+Delete, Fn+F-keys, Fn+E.** None of them starts dictation.
- [ ] **Tap Fn in a password box** (or with Terminal's Secure Keyboard Entry on). The pill says "Secure Input is on, so
  dictation can't start."
- [ ] **With Right Option as the key** (step 7 above): tap, speak, tap works the same, and Option+letter (é) doesn't
  start dictation.
- [ ] **Dictate for a minute or two.** It's all typed.

ThumbFree for Mac's checklist
([thumbfree-mac docs/mac-testing.md](https://github.com/shivam098/thumbfree-mac/blob/main/docs/mac-testing.md)) tests
the dictation engine in much more depth (microphones, keyboard layouts, the clipboard); those checks apply here too.

### Hindi + English

- [ ] **Press ⌃⇧H** (or menu › Dictation language › Hindi + English). The first time, its model downloads; then the pill
  shows **HI + EN**. Dictate a mix ("kal meeting reschedule kar do"): Hindi is typed in Roman letters. ⌃⇧H again goes
  back to English.
- [ ] **The first Hindi + English dictation after opening Voice Assistant:** how long does it take?
- [ ] **Menu › Dictation language › Hindi + English — accurate.** The first time, it downloads 874 MB; dictation then
  makes fewer mistakes but takes a few seconds a phrase. Switching back frees its memory (about 1 GB, in Activity
  Monitor).
- [ ] **"Hey Jarvis" and a command while Hindi + English is on.** Commands are still in English, and still work.

### Pause, paste last and the hotkeys

- [ ] **⌃⇧Space.** Listening pauses: the pill says so, the orange microphone dot goes, and "Hey Jarvis" does nothing.
  ⌃⇧Space again resumes.
- [ ] **Pause listening, then tap Fn.** Dictation still works while paused.
- [ ] **⌃⇧Z.** The last dictation is typed again where the cursor is.
- [ ] **With a Dvorak or AZERTY keyboard layout:** ⌃⇧Z is the key that types Z, and switching layouts moves it.
- [ ] **If another app already uses one of the three hotkeys:** Voice Assistant says which one it couldn't have. On a
  first launch, with Accessibility not yet allowed, that balloon and the Fn key's show one after the other.

### The idea board and reminders

- [ ] **Tap Fn, say "add to my ideas, a voice game for kids", and tap Fn.** It goes on the Idea board instead of being
  typed, and the pill says so.
- [ ] **"Hey Jarvis, add renew passport to my to-do list", and "Hey Jarvis, note down that the demo needs
  subtitles".** The first is on the To-do list, the second in Ideas.
- [ ] **"Hey Jarvis, show my ideas", and "show my reminders".** The window opens on the board, and that list's outline
  lights up for a moment.
- [ ] **"Hey Jarvis, remind me to stretch in 2 minutes".** Two minutes later a card appears in the bottom-right corner,
  with a sound: Done, Snooze 10 min and Open board. It doesn't take the keyboard from the app you're in. Done ticks
  the reminder off, Snooze brings it back 10 minutes later, and Open board opens the board.
- [ ] **"Hey Jarvis, remind me to call mom tomorrow at 5 pm".** It's on the board for tomorrow at 5 pm.
- [ ] **Quit Voice Assistant before a reminder is due, and open it again after.** The reminder's card appears when it
  starts.
- [ ] **"Hey Jarvis, mark renew passport as done".** It's ticked off.
- [ ] **On the window's Idea board:** type a note in a list's box (Return adds it), tick it, drag it to another place or
  another list (a line shows where it will land), double-click to edit it (Return saves, Esc doesn't), and right-click
  to move, snooze or delete it. Dragging a note onto another app does nothing. An edit left open without Return is
  kept when you close the window, click another app or quit. Everything is still there after quitting and opening
  Voice Assistant again.

### Navigation by name and by numbers, in Safari, Chrome and Edge

- [ ] **In Chrome, with a few tabs open: "go to the first tab", "last tab", "go to the YouTube tab", "go to the tab
  where WhatsApp is open".** Each goes to that tab.
- [ ] **The same in Safari.** The first time, macOS asks whether Voice Assistant may control Safari: allow it, and the
  commands work. (If you don't, note what Voice Assistant says; System Settings › Privacy & Security › Automation
  allows it later.)
- [ ] **On github.com: "click Pull requests", "click Issues", "select" or "expand" something in a list.** It clicks what
  you name, and the pill shows where you are (📍 Safari › … ). When two things have the same name, yellow numbers
  appear: say the number.
- [ ] **"Show numbers".** Numbers appear on everything you can click; say one ("seven") and it's clicked (a text box
  starts typing). "Hide numbers" takes them away.
- [ ] **Close Voice Assistant's window, then say "Hey Jarvis, show numbers".** The numbers appear (closing the window
  hides the app, which mustn't take the numbers with it). Numbers already showing stay when you close the window.
- [ ] **In Chrome, after "show numbers" or a click by name: "maximize this window".** The window fills the screen at
  once, as in other apps. (To describe its pages, Chrome is asked for what VoiceOver asks for, which can make window
  moves animate slowly in some apps; Rectangle or Magnet moving Chrome's window is worth a look too.)
- [ ] **"Start typing in the search box".** It types into the page's search box, never the address bar.
- [ ] **"Click" a button that deletes, signs out or pays** (on something you don't mind losing). It asks for a "yes"
  first; "no" does nothing.
- [ ] **In WhatsApp Web: "click" a contact's name.** That chat opens, also for a name it hears slightly differently.
- [ ] **Edge or Brave**, if you have them: tabs and clicks work as in Chrome.
- [ ] **The NavigationLab acceptance tests,** N1 to N9 in windows-voice-assistant's
  [acceptance-tests.md](https://github.com/shivam098/windows-voice-assistant/blob/main/docs/specs/acceptance-tests.md),
  with N10 and N16, in Chrome and in Safari. They need this repo and Xcode (HANDOFF-mac.md sections 2 and 3): after
  `swift build -c release`, run `tests/NavigationLab/run.sh .build/release/VoiceAssistant chrome`, then the same with
  `safari` with Safari closed ([self-test.md](self-test.md)), and don't use the Mac while each runs (about a minute).
  Each ends with a line such as "nav-lab-chrome: 33 passed, 0 failed". They pass on GitHub's runner; this Mac's screen,
  fonts and browser versions are what's new.

### The AI brain

It needs Apple silicon and macOS 13.3 or later. On an Intel Mac, check only that Settings doesn't offer it.

- [ ] **Settings › AI brain › Download.** About 2.4 GB, with progress; Cancel stops it, and downloading again carries on
  where it stopped. Voice Assistant keeps working meanwhile, and the status says it's ready at the end. How long did it
  take?
- [ ] **"Hey Jarvis, open the MrBeast video on YouTube"**, with YouTube open in a browser window behind another one. The
  pill says Thinking…, then the YouTube window comes to the front and a video opens. How long did it think?
- [ ] **The same with that browser window minimized, then with the browser hidden (⌘H).** The window comes back to the
  front each time.
- [ ] **More requests: "Hey Jarvis, mute the video", "open Instagram in a new tab", "what's the weather in
  Bangalore?", "tell me a joke", "reply thanks to Rahul on WhatsApp"** (it types the reply and asks "Send it?": say
  "no"). Which come out right?
- [ ] **Press Esc while it's thinking.** It stops at once. Talking while it thinks is ignored, and the pill says "Still
  working on your last request."
- [ ] **Ask for something risky: "Hey Jarvis, close all my windows", "empty the trash", or anything that would type in
  Terminal, Spotlight or System Settings.** It asks for a "yes" or refuses; it never does it without asking.
- [ ] **Memory:** with the model loaded, llama-server's memory in Activity Monitor. It unloads after an hour unused,
  and "Hey Jarvis" starts loading it again.
- [ ] **Force Quit while the model is loading.** Open Voice Assistant (the brain starts loading a few seconds after
  the speech models, or when you say "Hey Jarvis" after it has unloaded), and while `pgrep -l llama-server` shows it,
  Force Quit Voice Assistant (⌥⌘⎋, or Activity Monitor). Within a few seconds `pgrep llama-server` prints nothing: the
  server never outlives the app.
- [ ] **The brain's bench on this Mac** (it needs Xcode and a clone of this repo: HANDOFF-mac.md sections 2 and 3):

  ```sh
  swift package update
  BRAIN_BENCH_FOLDER="$HOME/brain-bench" BRAIN_BENCH_SUMMARY="$HOME/brain-bench/summary.md" \
    swift test --filter BrainBenchTests
  ```

  It downloads the 2.4 GB model once, then writes the summary: the right answers out of 25, the time a request takes,
  the first load's time and llama-server's peak memory. Write them down with the Mac's chip and memory. It scored
  21/25 on GitHub's Macs, and Windows scores 22/25 at about 1.9 s a request; GitHub's Macs had no graphics chip it could
  use, so these are the first real numbers for a Mac.

### Settings and starting at login

- [ ] **Change a setting** (turn the sounds off, say) **and choose Save and restart.** Voice Assistant quits and opens
  again within a few seconds, with the change, and `settings.json` has it.
- [ ] **Quit, put a mistake in settings.json, and open Voice Assistant.** It starts with the defaults, Settings says
  where the mistake is, and the file is left as it was.
- [ ] **Start when I log in** (in the menu or Settings). macOS may ask you to allow it in System Settings › General ›
  Login Items. Log out and in again: Voice Assistant starts in the menu bar, with its window closed. Turning it off
  takes it out of Login Items.
- [ ] **Settings › Forget what I've learned.** What it had learned (the second phrasing above) is forgotten.
- [ ] **Type `sig = "Thanks" -- me` into Settings › Snippets and choose Save.** `settings.json` has it exactly as
  typed: straight quotes and two hyphens, whatever System Settings › Keyboard › Text Input says about smart quotes,
  dashes and spelling.
- [ ] **VoiceOver (⌘F5) on Home and Settings.** The menus, boxes and buttons say what they're for ("Dictation
  language", "Allow Microphone"), and the sidebar says which page is open.

### ThumbFree for Mac side by side

- [ ] **With ThumbFree for Mac running, open Voice Assistant.** Each warns that the other uses Fn too.
- [ ] **Quit ThumbFree.** Fn dictation works in Voice Assistant; and the other way round.
- [ ] **Speech models ThumbFree already has** aren't downloaded again (see the first run).

### Quitting

- [ ] **Menu › Quit Voice Assistant.** The icon and the pill go, the orange microphone dot goes, and
  `pgrep llama-server` prints nothing.
- [ ] **Log out, or restart the Mac, with Voice Assistant running.** Nothing holds it up.

### Every day

- [ ] **Sleep and wake.** "Hey Jarvis" and Fn still work afterwards.
- [ ] **Change the microphone** (AirPods, a USB microphone) while it listens. It carries on with the new one.
- [ ] **Waiting for "Hey Jarvis" for a few minutes:** Voice Assistant's % CPU and Energy Impact in Activity Monitor.
- [ ] **Search the logs for a word you said or dictated:** `grep -ri "<the word>" ~/Library/Logs/VoiceAssistant` finds
  nothing.

## If something goes wrong

- **The log:** `~/Library/Logs/VoiceAssistant` (`open ~/Library/Logs/VoiceAssistant`, or Console). It has states,
  timings and errors, never your words; the lines from when it went wrong usually say what happened.
- **If it quit unexpectedly,** macOS kept a crash report: Console › Crash Reports, or
  `~/Library/Logs/DiagnosticReports/VoiceAssistant-*.ips`.
- **What to send:** open an [issue](https://github.com/shivam098/mac-voice-assistant/issues) with the checklist item,
  what you did, what you expected and what happened; your Mac (model, Apple silicon or Intel, memory) and macOS
  version; the build (the release, such as v0.1.0, or the App workflow run); and the latest log, or its lines from
  then. A crash report, a screenshot or a screen recording helps too. (Agents: HANDOFF-mac.md section 6.)
- **What not to send:** `board.json` (your notes, to-dos and reminders), `learned.json` (phrases you've said), what you
  dictated, and screenshots that show messages or passwords. `settings.json` can hold your own words (the dictation
  vocabulary, snippets and replacements): send it only if asked, after reading it.
- **Starting again:** quit Voice Assistant, then move `settings.json` out of
  `~/Library/Application Support/VoiceAssistant` to get the defaults, or the whole folder to start from nothing (its
  models download again). `tccutil reset All io.github.shivam098.voiceassistant` takes back its permissions.
- **Uninstalling:** quit it, turn off Start when I log in, drag Voice Assistant from Applications to the Bin, delete
  `~/Library/Application Support/VoiceAssistant` and `~/Library/Logs/VoiceAssistant`, and run
  `tccutil reset All io.github.shivam098.voiceassistant`.

The checklists in pull requests #14, #15, #22, #24, #25 and #27 have more detail behind some of these items.
