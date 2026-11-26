# The self-test

Voice Assistant's self-test runs a script of transcripts through the real interaction controller and the real Mac
desktop (`MacDesktop`), without the microphone or the speech models, so a flow on the desktop can be checked end to
end: open an app, start typing, dictate, edit, read back. It's the Mac's version of windows-voice-assistant's
`SelfTest` (`src/VoiceAssistant.App/SelfTest.cs`), which its NavigationLab and EditingLab acceptance tests run, with
the same script commands and output; the differences are at the end.

## Running it

```sh
swift build -c release
.build/release/VoiceAssistant --self-test <script> [<output>]
```

In the app, the executable is `Voice Assistant.app/Contents/MacOS/VoiceAssistant`. The output goes to
`<script>.out.txt` unless another file is given. The app reads settings.json as it does when it runs (the wake word,
`insertMethod`, the apps it knows), but uses an idea board in memory, saves nothing it learns, plays no sounds and
doesn't open the microphone. It acts on the app in front and types there, so don't use the Mac while it runs.

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
| `insert Paste` or `insert Type` | Switches how text goes in: pasted, or typed with key events (`insertMethod`). |
| `clipboard` | Records the clipboard's formats, a hash of its text and the text's length. |
| `braindownload` | Downloads the AI brain's missing files and waits; records ok or failed. |
| `brainwait <seconds>` | Loads the AI brain if needed and waits until it's ready; records its state. |
| `stoponfail` | From here, stops at the first FAIL, so nothing is typed into the wrong window. |
| `typing <chunk> <delay>` | Windows' key typing speed: read, and ignored on the Mac. |

`expect` and `expectvalue` compare exactly, case and all; `expecttitle` and `expectfocus` ignore case, as on Windows.
Typed text goes through the dictation formatter as it would when spoken, so `say: hello there.` types `Hello there.`
at the start of a sentence.

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
`expectvalue` find exactly that text; "clear the box" empties the document.

```sh
tests/TextEditLab/run.sh .build/release/VoiceAssistant [<results folder>]
```

It refuses to run while TextEdit is open (it quits TextEdit afterwards, without saving), sets TextEdit to start with a
new document rather than its Open panel and to restore no windows, and puts those settings back. The results folder (by
default `$TMPDIR/voice-assistant-self-test/textedit`) gets `output.txt` and the app's log files written during the run.

A new lab, such as the NavigationLab's scenarios N1–N9 (windows-voice-assistant `tests/NavigationLab`):

1. `tests/<Name>Lab/<name>-lab.selftest.txt`: start with `stoponfail` and a check that the lab's window is in front
   (`expecttitle:`), then the scenario, a check after each step.
2. `tests/<Name>Lab/<name>-lab.expected.txt` (optional): lines the output must have besides its checks, such as
   `   foreground: com.google.Chrome`.
3. `tests/<Name>Lab/run.sh <app> [<results folder>]`: puts the lab's windows in front, runs
   `scripts/self-test.sh --expect …` with the results folder's `output.txt`, copies the app's log files written during
   the run from `~/Library/Logs/VoiceAssistant`, and closes only what it opened, also when the run fails
   (`trap … EXIT`). The TextEdit lab's `run.sh` is the pattern.
4. A step in `.github/workflows/self-test.yml` after the TextEdit lab, with `if: ${{ !cancelled() }}` so a failing lab
   doesn't hide the others, writing its results to `$RUNNER_TEMP/self-test/<name>`.

The lab's windows must be another app's: the desktop never acts on Voice Assistant's own windows, and on GitHub's
runners a process can't read the windows it made itself through Accessibility. For web pages, start a browser for the
lab with a profile of its own, so tabs are the lab's whatever else is open (Chrome: `--user-data-dir=<temporary
folder> --no-first-run --no-default-browser-check --new-window <file URLs>`, as Windows' NavigationLab does), and quit
only that browser afterwards. GitHub's macOS runners have Safari, Chrome, Edge and Firefox.

## On GitHub

The Self-test workflow (`.github/workflows/self-test.yml`) runs for pull requests that change the sources, a lab, the
runner, Package.swift or the workflow, and by hand (Actions › Self-test › Run workflow, or
`gh workflow run self-test.yml --ref <branch>`). It builds the release executable and runs each lab on the runner's own
desktop: GitHub's macOS runners let what a step starts use Accessibility and send keys. Each lab's result and output are
in the job's summary, and the run's artifact, `self-test-results`, has each lab's output and the app's log.

## Differences from Windows

- `fg` records the bundle identifier of the app with the keyboard focus; Windows records the process name.
- `read` records the focused element's Accessibility role (`AXTextArea`); Windows records its UI Automation control
  type.
- `expectfocus` asks the desktop's `describeFocus` for the focused control's name.
- A Mac text box's line break is `\n` (Windows' is `\r`).
- `typing <chunk> <delay>` does nothing: the Mac's typing has no such setting.
- No pill or number badges are shown until the app's UI lands; Windows shows them so screenshots of a run show what a
  user would see.
- Without Accessibility the run stops at once with `!! missing permissions`; Windows needs no permission.
- The output is written as the run goes; Windows writes it at the end.
- The labs' `run.sh` scripts and `scripts/self-test.sh` take the place of Windows' `run.ps1` scripts, and add the
  expected lines, the time limit's note and the exit code.
- Windows' `--drag-lab`, which drags notes in the idea board's window, belongs to the UI.