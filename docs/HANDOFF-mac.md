# Handoff: finishing on a real Mac

For whoever picks this up on a Mac: a person, or a coding agent started in this repo (AGENTS.md points here). Work
through it in order: check where things stand, set up the Mac, build and test, install and set up the app, run the
checks only a real Mac can do, then report what you found.

Written on 26 November 2026 on a Windows PC with no Mac, while coding agents there were still finishing features through
PRs. Until now everything has been built and tested only on GitHub's macOS runners.

## 1. Where things stand

Jarvis for Mac (the app is called Voice Assistant; you wake it with "Hey Jarvis"): hands-free voice control for macOS.
Open apps, dictate, navigate and send by voice, with an optional offline AI brain, all on the Mac. It's a port of the
Windows app (shivam098/windows-voice-assistant). Its dictation is ThumbFree for Mac's (shivam098/thumbfree-mac), which
this package uses at the tip of that repo's main. docs/design.md is the design and has the phase table.

Merged (main was `2c2a6a9` when this was written):

- **The idea board and the assistant's core in Swift** (PRs #1–#5): commands and the wake word, the navigation and
  editing grammars, the AI brain's prompt and plan reader, and the interaction controller. Every C# core test is
  ported.
- **The app's foundation** (#8): settings.json and learned.json in the Windows format, the log, model downloads, and
  the test build. The **App** workflow builds `VoiceAssistant-0.1.0.dmg` (artifact **VoiceAssistant-dmg**) on every
  push.
- **The AI brain** (#7, #12): llama.cpp's llama-server with Qwen3 4B (an optional 2.4 GB download), supervised so it
  never outlives the app, and a bench that scores it against Windows.
- **The desktop layer, part 1** (#9): apps, windows, keys, typing and focus through Accessibility. Also the core's
  fixes for the Mac (#10, #13).

In review or being built on the Windows PC, through PRs (check `gh pr list`):

- **#14, the assistant host:** always listening for "Hey Jarvis", Fn dictation with live preview, Hindi + English, the
  hotkeys (⌃⇧Space pause, ⌃⇧Z paste last, ⌃⇧H dictation language), start at login, and a `--self-test` runner.
- **#15, the UI, part 1:** the menu bar, the status pill and the reminder cards. Then the window (Home, Settings, Help
  and the idea board) and the wiring that connects the host, the UI, the desktop and the brain.
- **The desktop layer, parts 2 and 3:** navigation (clicking by name, number badges, browser tabs) and the
  NavigationLab acceptance tests.
- **Release preparation:** a release workflow, docs/testing.md (the full real-Mac checklist for the app) and the
  v0.1.0 release notes.

**What that means on this Mac today:** the app on main is still a placeholder (a menu-bar item; the assistant isn't
connected yet). So for now: set up the Mac, run every test, including the ones that need a real Mac (sections 3 and 5),
and measure the AI brain on a real graphics chip. Once the host, the UI and the wiring have merged and v0.1.0 is
released (or the App workflow's .dmg shows the whole app), install it and go through the app checklist in section 5.

Before you start, see what has changed since this was written:

```sh
git pull
gh pr list
gh release list
gh run list --branch main --limit 3
```

## 2. Set up this Mac

- **To run the app:** macOS 13 or later. The AI brain needs macOS 13.3 or later and Apple silicon.
- **To build it:** Xcode 16 with Swift 6.1 or later. CI uses Xcode 16.4 on macOS 15. Install Xcode from the App
  Store, open it once to finish installing, then:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  xcodebuild -version
  swift --version
  ```

- **GitHub:** the GitHub CLI, signed in as shivam098, then the clone and the identity for commits:

  ```sh
  brew install gh          # or the installer from https://cli.github.com
  gh auth login
  gh repo clone shivam098/mac-voice-assistant
  cd mac-voice-assistant
  git config user.name shivam098
  git config user.email 39924466+shivam098@users.noreply.github.com
  ```

## 3. Build and test

```sh
swift package update     # thumbfree-mac at the tip of its main, as CI does (Package.resolved isn't committed)
swift build -c release
swift test
```

On CI, `swift test` ran about 660 tests on main with no failures. Three groups skip unless you ask for them, because
they act on this Mac or download a lot:

1. **The Accessibility tests** open TextEdit, type into it and quit it. Give Accessibility to the app you run them from
   (Terminal or iTerm: System Settings › Privacy & Security › Accessibility), keep your hands off the keyboard and
   mouse while they run, then:

   ```sh
   VOICE_ASSISTANT_AX_TESTS=1 swift test --filter AccessibilityIntegrationTests
   ```

   They change two of TextEdit's settings and put them back afterwards.

2. **The AI brain's integration test** downloads llama.cpp (17 MB) and a 1.2 MB test model, starts llama-server on the
   graphics chip, and checks that the server ends when the app is killed:

   ```sh
   BRAIN_INTEGRATION_FOLDER="$HOME/brain-integration" swift test --filter BrainIntegrationTests
   ```

3. **The AI brain bench** downloads the real 2.4 GB model: section 5, item 1.

Anything that fails here but passes on CI is a finding: write it down (section 6).

## 4. Install and set up the app

1. **Get the app.** Either build it here:

   ```sh
   scripts/make-app.sh      # dist/Voice Assistant.app and dist/VoiceAssistant-0.1.0.dmg
   ```

   or download the .dmg CI built from the latest App run on main (or the v0.1.0 release, once there is one):

   ```sh
   gh run list --workflow App --branch main --limit 1
   gh run download <run id> -n VoiceAssistant-dmg
   ```

2. **Install it:** open the .dmg and drag Voice Assistant to Applications. Test builds are signed ad hoc, so macOS
   blocks them the first time: open it once, then choose System Settings › Privacy & Security › **Open Anyway**.
3. **Permissions:** the microphone; Accessibility, to read other apps and act on them, and to type; and Automation for
   Safari's tabs, when it asks. Each new test build needs Accessibility given again, because its ad-hoc signature
   changes: run `tccutil reset Accessibility io.github.shivam098.voiceassistant`, then turn it on again.
4. **First run** downloads the speech models (Whisper small.en, about 264 MB, and the Silero voice detector; the
   Hindi + English models on first use). Models ThumbFree for Mac has already downloaded are reused. The AI brain is a
   separate, optional 2.4 GB download from Settings.
5. **Its files:** settings.json, board.json, learned.json, `models/` and `brain/` are in
   `~/Library/Application Support/VoiceAssistant`; the logs are in `~/Library/Logs/VoiceAssistant`. They never contain
   your words.
6. **ThumbFree for Mac** uses Fn too. Run one of the two at a time; each warns while the other is running.

## 5. What only a real Mac can check

**Now, with main as it is:**

1. **The AI brain on a real graphics chip.** GitHub's Apple silicon runner had no graphics chip llama.cpp could use, so
   its speed and memory figures aren't a real Mac's. Here:

   ```sh
   BRAIN_BENCH_FOLDER="$HOME/brain-bench" BRAIN_BENCH_SUMMARY="$HOME/brain-bench/summary.md" \
     swift test --filter BrainBenchTests
   ```

   The summary has the correct answers out of 25, the time per request, the first load time and llama-server's peak
   memory. On GitHub's runners it scored 21/25 (17 of the first 21); Windows scores 22/25 (18 of 21) at about 1.9 s a
   request. Record the numbers with the Mac's chip and memory. Don't decide anything from them: that's the owner's
   call (section 8).
2. **The Accessibility tests and the brain's integration test** (section 3) on a real Mac.

**Once the whole app is out** (v0.1.0, or the App workflow's .dmg after the wiring PR has merged):

3. **docs/testing.md's checklist**, top to bottom. It's being written in the release-preparation PR. Until it's on
   main, check at least the following:
   - the menu bar item, its menu and the status pill;
   - "Hey Jarvis, open Notes", "start typing", a dictation, then "send";
   - Fn dictation with its live preview, and Esc to cancel;
   - Hindi + English dictation;
   - ⌃⇧Space (pause), ⌃⇧Z (paste last) and ⌃⇧H (dictation language);
   - the idea board and a reminder;
   - navigation by name and by numbers in Safari and Chrome;
   - the AI brain's download, then a request it has to plan;
   - Force Quit while the brain's model is loading: llama-server must not keep running (`pgrep llama-server` prints
     nothing);
   - Quit, start at login, and ThumbFree for Mac side by side.
4. **The NavigationLab acceptance tests** (windows-voice-assistant `tests/NavigationLab`; N1–N9 in
   `docs/specs/acceptance-tests.md`), once the desktop layer's navigation parts have merged.

## 6. Report what you found

- **Results:** write `docs/test-results/<YYYY-MM-DD>-<Mac model>.md` with the Mac model, chip and memory, the macOS
  version, what you tested (a commit, the App run's id, or a release), the bench's numbers, and each check as pass,
  fail (with what happened) or not tried. Open a PR with it.
- **Problems:** open one GitHub issue per problem, with the steps, what should have happened, what happened, the Mac
  model and macOS version, and the relevant lines from `~/Library/Logs/VoiceAssistant`. Label the issues `real-mac`
  (create the label if it doesn't exist).
- **Fixes:** fix only what is clearly broken, each fix in its own PR, with a test where one can be written. Check
  `gh pr list` first: agents on the Windows PC may be changing the same files.
- **Done:** update docs/design.md's phase table when a phase's "done when" is met on this Mac.

## 7. Rules for agents working here

- One change per PR. CI green and an independent review (for example a code-review agent) before merging, then
  squash-merge. Don't merge other people's or other agents' PRs without that review.
- PR descriptions start with the owner's Agent assessment block: between `<!-- copilot-assessment:v1 -->` and
  `<!-- /copilot-assessment -->`, a "### Agent assessment" heading, the line "Self-reported assessment, not an
  independent review.", "Assessed revision:" with the full head commit SHA, and a table scoring Change confidence out
  of 10 (bug fixes also score Diagnosis confidence and Evidence fit). Each score's rationale lists evidence items,
  marked ↑ (supports it) or ↓ (missing, unverified or against it).
- Commit as `shivam098 <39924466+shivam098@users.noreply.github.com>`.
- Never commit secrets, models, llama.cpp or build output (`*.gguf`, `*.bin`, `models/` and `dist/` are ignored).
- Behave as the Windows app does unless there's a Mac reason not to, and say why in the PR.
- Don't build a reduced version of a feature, or add security measures nobody asked for, without asking the owner.
  State measurements as findings, and ask the owner before drawing conclusions from them.
- Don't publish a release without the owner's go-ahead.

## 8. Decisions waiting for the owner

- **The AI brain on Intel Macs:** on GitHub's Intel runner it scored 21/25, at about 9 s a request (Windows: 1.9 s),
  50–68 s for the first request, and 4.9 GB of peak memory. Intel Macs aren't offered the brain today.
- **The brain on Apple silicon:** what the real-Mac bench shows (item 1 of section 5). docs/design.md also says to
  compare the Q4_K_M model with Q4_0 on the graphics chip before the first release; the bench can't switch models yet.
- **Windows bugs found while porting:**
  - a reminder time that has passed moves exactly 24 hours, which is an hour off across a daylight-saving change;
  - "tonight" after 8 pm gives a time that has already passed;
  - "at १० pm" (digits that aren't ASCII) fails and the words are lost;
  - the brain prompt's line endings depend on how the Windows repo is checked out;
  - some web addresses with non-ASCII host names make the brain's request fail.

  The Mac keeps the first three for now, to behave the same, sends the prompt exactly as the Windows release does, and
  refuses such web addresses instead of failing. Fix them on both platforms?
- **Signing:** Developer ID signing and notarization need a paid Apple Developer account. Until then, every build needs
  Open Anyway and its permissions given again.
