# The self-test

Voice Assistant's self-test runs a script of transcripts through the real interaction controller and the real Mac
desktop (`MacDesktop`), without the microphone or the speech models, so a flow on the desktop can be checked end to
end: open an app, start typing, dictate, edit, read back. It's the Mac's version of windows-voice-assistant's
`SelfTest` (`src/VoiceAssistant.App/SelfTest.cs`), which its NavigationLab and EditingLab acceptance tests run, with
the same script commands and output; the differences are at the end.

## Running it

```sh
swift package update     # thumbfree-mac at the tip of its main, as CI uses it
swift build -c release
.build/release/VoiceAssistant --self-test <script> [<output>]
```

In the app, the executable is `Voice Assistant.app/Contents/MacOS/VoiceAssistant`. The output goes to
`<script>.out.txt` unless another file is given. The app reads settings.json as it does when it runs (the wake word,
`insertMethod`, the apps it knows), but uses an idea board in memory, saves nothing it learns, plays no sounds and
doesn't open the microphone. It acts on the app in front and types there, so don't use the Mac while it runs.

It shows none of the app's notices (`AppController.notice`, Windows' tray balloons), which the app's UI shows as
balloons by the menu bar icon, replayed when the UI subscribes; withdrawing one isn't announced to handlers already
listening, so the lasting warnings follow the specific events instead (`thumbFreeChanged` for the menu's ThumbFree
warning, `permissionsChanged` for Home's "Permissions needed").

The desktop needs Accessibility, which also lets it send keys. macOS asks it of whatever started the app: Terminal (or
the runner on GitHub) when the executable is started directly, the app itself when it's opened with `open`. Without it,
the output is a single line starting `!! missing permissions` and nothing runs.

`scripts/self-test.sh` starts the app, waits for it, prints the output and says whether the run passed:

```sh
scripts/self-test.sh [--timeout <seconds>] [--expect <file>] <app> <script> <output>
```

- `<app>` is `Voice Assistant.app` or its executable, `VoiceAssistant`.
- The run passes when the app ends by itself without an error, and its output has at least one PASS, no FAIL and no
  line starting `!!`, and, with `--expect`, every line of that file as a whole line of the output (blank lines and lines
  starting `#` aside). The script then exits 0; otherwise 1, and 2 for a wrong command line.
- The app is stopped after `--timeout` seconds, 240 by default (as Windows' NavigationLab waits); what it wrote until
  then stays in the output.
- It prints the output, then what went wrong besides it (`!! missing from the output: <line>`, `!! stopped after <n> s`,
  `!! Voice Assistant exited with code <n>`, `!! the self-test wrote no output`), then a last line such as
  `textedit-lab: 6 passed, 0 failed (31 s)`.
- On GitHub Actions the same goes to the job's summary, and a failed run is marked as an error on the job.
- It runs with the bash macOS comes with (3.2).

## Scripts

One command per line; each runs after the one before has finished, then 400 ms pass, as on Windows. Blank lines and
lines starting `#` are skipped.

| Command | What it does |
|---|---|
| `listen` | Starts listening: standby, or command mode when the wake word is off. |
| `say: <transcript>` | As if Whisper heard it, with confidence 0.9, through the host's work queue as speech goes. |
| `ptt: <transcript>` | As if dictated with the dictation key (Fn): typed where the cursor is. |
| `wait <ms>` | Waits. |
| `fg` | Records the bundle identifier of the app with the keyboard focus. |
| `read` | Records the focused element's Accessibility role, its text's length and a hash of it, never the text. |
| `expect: <text>` | PASS when the focused element's text contains `<text>` (`\n` is a line break). |
| `expectvalue: <text>` | PASS when the focused element's whole text, trailing white space aside, is `<text>` (`\n` is a line break). |
| `expecttitle: <text>` | PASS when the front window's title contains `<text>`; the title isn't written. |
| `expectfocus: <name>` | PASS when the focused control's accessible name contains `<name>` (`describeFocus`). |
| `expectboard: <list> <text>` | PASS when the self-test's own idea board has that note in that list (Ideas, Todo…). |
| `expectchoices: <n>` | PASS when exactly `<n>` numbers show (0: none). The Mac's own. |
| `expectchoice: <name>` | PASS when a number shows on something whose name contains `<name>`; the names aren't written. The Mac's own. |
| `insert Paste` or `insert Type` | Switches how text goes in: pasted, or typed with key events (`insertMethod`). |
| `clipboard` | Records the clipboard's formats, a hash of its text and the text's length. |
| `braindownload` | Downloads the AI brain's missing files and waits; records ok or failed. |
| `brainwait <seconds>` | Loads the AI brain if needed and waits until it's ready; records its state. |
| `stoponfail` | From here, stops at the first FAIL, so nothing is typed into the wrong window. |
| `typing <chunk> <delay>` | Windows' key typing speed: read, and ignored on the Mac. |

`expect` and `expectvalue` compare exactly, case and all; `expecttitle`, `expectfocus` and `expectchoice` ignore case,
as on Windows. Typed text goes through the dictation formatter as it would when spoken, so `say: hello there.` types
`Hello there.` at the start of a sentence.

The numbers ("show numbers", a name two buttons have, text boxes to choose from) and the outline on what was clicked
show over the app in front as in the app (`MarkerOverlay`), so the run's real clicks go through them as a user's do.

## Output

UTF-8, one line per event, each ending with a line feed. It's written as the run goes, so a run that hangs or is stopped
leaves what it did, and once more whole at the end.

| Line | What it says |
|---|---|
| `> <line>` | A script line, as it starts. |
| `   [<Mode>] <Kind>: <message>` | A status line from the assistant: `[Command] Success: Typed.` |
| `   choices shown: <n> at <x>,<y> <w>x<h>; …` | Number badges on the screen, never what they label. |
| `   foreground: <bundle identifier>` | `fg`. |
| `   focused: <role> len=<n> hash=<hex>` | `read` (below). |
| `   PASS: …` and `   FAIL: …` | A check, with lengths but never the text. |
| `   clipboard fingerprint: formats=[…] textHash=<hex> len=<n>` | `clipboard`. |
| `   brain download: ok` or `failed`, `   brain: <state>` | `braindownload` and `brainwait`. |
| `!! stopped after a failed check` | `stoponfail` stopped the run. |
| `!! <error>: <message>` | The script stopped on an error, such as a number that isn't one. |
| `!! missing permissions: …` | Accessibility isn't allowed; nothing ran. |

The output never holds what was typed, read or copied, nor window titles: text in “quotes” in status lines (names, what
was heard) is written `“…”`, so the output can be kept as a CI artifact. A check that needs to know what's in a field
compares in the app. `read`'s `<n>` is the text's length in UTF-16 units and `<hex>` the first 12 hex digits of the
SHA-256 of its UTF-8 bytes (`E3B0C44298FC` for no text), so an expected `focused:` line pins the exact text without
holding it; the role is `(timeout)` or `(error AXError <code>)` when the focused element can't be read. A text's hash:
`printf '%b' 'Hello from the self test.\nA second line.' | shasum -a 256 | cut -c1-12 | tr a-f A-F`.

## Labs

A lab is a folder in `tests/` with a script, the lines its output must have, and a `run.sh` that sets the stage, runs
`scripts/self-test.sh` and cleans up.

**`tests/TextEditLab`**: "Hey Jarvis, open TextEdit" opens a new document in front; "start typing" types two phrases
into it with "new line" between them; a dictation is pasted and another typed with keys, each after a space; `read` and
`expectvalue` find exactly that text; "clear the box" empties the document, which `read` checks too, so a text area
that can't be read doesn't pass as empty (`expectvalue` alone compares what it couldn't read, nothing, to nothing).

```sh
tests/TextEditLab/run.sh .build/release/VoiceAssistant [<results folder>]
```

It refuses to run while TextEdit is open (it quits TextEdit afterwards, without saving), sets TextEdit to start with a
new document rather than its Open panel and to restore no windows, and puts those settings back. The results folder (by
default `$TMPDIR/voice-assistant-self-test/textedit`) gets `output.txt` and the app's log files written during the run.

**`tests/NavigationLab`**: voice navigation in a browser, the acceptance scenarios N1–N9 of windows-voice-assistant's
[acceptance-tests.md](https://github.com/shivam098/windows-voice-assistant/blob/main/docs/specs/acceptance-tests.md),
and N10 and N16 as its `tests/NavigationLab/nav-lab.selftest.txt` has them, on the same four pages (videos.html,
lab.html, mail.html and chats.html, open in that order in a new window):

| | Said | Checked |
|---|---|---|
| N1 | "go to the second tab" | The lab page's tab shows |
| N2 | "click New on the left side" | The page says "clicked New left" |
| N3 | "click New", then "two" | Two numbers, then none, and "clicked New right" |
| N4 | "go to library" | "clicked Library left" (no app or tab is called that) |
| N5 | "click delete account", then "yes" | It waits for "yes" (nothing clicked yet), then "clicked Delete account right" |
| N6 | "start typing in the message box", "hello from voice" | The focus in Message, its text "Hello from voice" |
| N7 | "go to the tab where YouTube is open", "start typing", "lofi music" | The videos tab, the focus in its Search box (the YouTube site profile's), empty, so not the address bar, then "Lofi music" |
| N8 | "go to the third tab", "start typing", "two", "quarterly plan" | Two numbers, on To and Subject (not the address bar), then the focus in Subject, "Quarterly plan" |
| N9 | "show numbers", "hide numbers", on the lab page | Numbers on a button, the link, the Message box and a tab; then none |
| N10 | "select vivash morang", "click family", in the chat list | "opened Bibhash Morang" (a name heard slightly differently), "opened Family": rows that open only on a real click |
| N16 | "go back", "go to the next page", "go to the previous page" | Back, forward, back |

```sh
tests/NavigationLab/run.sh .build/release/VoiceAssistant chrome [<results folder>]
tests/NavigationLab/run.sh .build/release/VoiceAssistant safari [<results folder>]
```

- **chrome:** Google Chrome with a temporary profile, a process of its own whatever else Chrome has open (as Windows'
  NavigationLab starts it), the pages as files. It quits afterwards and the profile is deleted.
- **safari:** Safari mustn't be running. Afterwards the lab closes its own window, by its id, and quits Safari through
  AppleScript, so it doesn't open the lab's tabs again next time; windows of Safari's last session that it opened stay
  (a Safari that doesn't quit within 5 s is stopped). The pages come from a web server the lab starts on this Mac,
  python3's on 127.0.0.1 only, and stops afterwards: Safari asks before it shows a file that AppleScript opens. The
  lab opens the tabs with AppleScript and the app lists them with AppleScript, so whatever starts the lab needs the
  Automation permission for Safari: Terminal asks for it the first time.

Each run's expected lines (`nav-lab.chrome.expected.txt`, `nav-lab.safari.expected.txt`) pin the browser in front,
the numbers offered (N3, N8, N9) and the click that waits for "yes" (N5), the Search box empty before typing (N7: the
address bar holds the page's address), and the three typed texts by their length and hash. The results folder (by
default `$TMPDIR/voice-assistant-self-test/nav-lab-<browser>`) gets `output.txt`, the script under the browser's name
(`nav-lab-chrome.selftest.txt`, so the run's last line and the job's summary say which browser it was), the app's log
files written during the run and, for Safari, the web server's log (`server.log`).

A new lab:

1. `tests/<Name>Lab/<name>-lab.selftest.txt`: start with `stoponfail` and a check that the lab's window is in front
   (`expecttitle:`), then the scenario, a check after each step. Before an empty `expectvalue:`, `read`, with its
   `len=0` line in the expected file: a box that can't be read reads as empty.
2. `tests/<Name>Lab/<name>-lab.expected.txt` (optional): lines the output must have besides its checks, such as
   `   foreground: com.google.Chrome`.
3. `tests/<Name>Lab/run.sh <app> [<results folder>]`: puts the lab's windows in front, runs
   `scripts/self-test.sh --expect …` with the results folder's `output.txt`, copies the app's log files written during
   the run from `~/Library/Logs/VoiceAssistant`, and closes only what it opened, also when the run fails
   (`trap … EXIT`). The TextEdit lab's `run.sh` is the pattern; the NavigationLab's, for browsers.
4. A step in `.github/workflows/self-test.yml` after the others, with `if: ${{ !cancelled() }}` so a failing lab
   doesn't hide the others, writing its results to `$RUNNER_TEMP/self-test/<name>`.

The lab's windows must be another app's: the desktop never acts on Voice Assistant's own windows, and on GitHub's
runners a process can't read the windows it made itself through Accessibility. For web pages, start a browser for the
lab with a profile of its own, so tabs are the lab's whatever else is open, and quit only that browser afterwards, as
the NavigationLab does. GitHub's macOS runners have Safari, Chrome, Edge and Firefox.

## On GitHub

The Self-test workflow (`.github/workflows/self-test.yml`) runs for pull requests that change the sources, a lab, the
runner, Package.swift or the workflow, and by hand (Actions › Self-test › Run workflow, or
`gh workflow run self-test.yml --ref <branch>`). It builds the release executable and runs each lab on the runner's own
desktop: GitHub's macOS runners let what a step starts use Accessibility and send keys. The TextEdit lab goes first,
then the NavigationLab in Chrome and in Safari. Before those, a step takes Chrome out of quarantine (the runner image
installs it with Homebrew, and Launch Services would ask before its first start, with no one to answer) and allows the
runner's processes to control Safari in the user TCC database (the image allows Finder and System Events only). Each
lab's result and output are in the job's summary, and the run's artifact, `self-test-results`, has each lab's output
and the app's log.

## Differences from Windows

- `fg` records the bundle identifier of the app with the keyboard focus; Windows records the process name.
- `read` records the focused element's Accessibility role (`AXTextArea`); Windows records its UI Automation control
  type.
- `expectfocus` asks the desktop's `describeFocus` for the focused control's name.
- `expectchoices` and `expectchoice` are the Mac's own: where the numbers go depends on the screen, so the labs check
  how many show and what they're on instead.
- A Mac text box's line break is `\n` (Windows' is `\r`).
- `typing <chunk> <delay>` does nothing: the Mac's typing has no such setting.
- The number badges and the click outline show, as on Windows; the pill doesn't (Windows shows it too, so screenshots
  of a run show what a user would see).
- Without Accessibility the run stops at once with `!! missing permissions`; Windows needs no permission.
- The output is written as the run goes; Windows writes it at the end.
- The labs' `run.sh` scripts and `scripts/self-test.sh` take the place of Windows' `run.ps1` scripts, and add the
  expected lines, the time limit's note and the exit code.
- The NavigationLab runs in Safari too, its pages over HTTP and its tabs through AppleScript; Windows' runs in Chrome
  only. Its N9 checks what the numbers are on, on the lab page, where Windows' only shows and hides them on the mail
  page, and its N3 and N8 check how many numbers show. N8 goes to "the third tab", as Windows' script does
  (acceptance-tests.md says "the last tab", from before chats.html).
- Windows' `--drag-lab`, which drags notes in the idea board's window, belongs to the UI.