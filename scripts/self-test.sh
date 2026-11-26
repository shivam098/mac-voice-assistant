#!/usr/bin/env bash
# Runs a self-test script through Voice Assistant's real controller and desktop (docs/self-test.md): starts the app with
# --self-test, waits for it, prints what it recorded, and says whether it passed.
#
#   scripts/self-test.sh [--timeout <seconds>] [--expect <file>] <app> <script> <output>
#
# <app> is "Voice Assistant.app" or its executable, VoiceAssistant (`swift build -c release` puts it in .build/release).
# The run passes when the app ends by itself, without an error, within --timeout seconds (240 by default, as Windows'
# NavigationLab waits), and its output has a PASS, no FAIL and no line starting "!!", and, with --expect, each line of
# that file as a whole line (blank lines and lines starting "#" aside). Then this exits 0; otherwise 1, and 2 for a
# wrong command line. On GitHub Actions the result and the output also go to the job's summary, and a failed run is
# marked as an error.
#
# The script acts on the app in front: don't use the Mac while it runs. Whatever starts this needs Accessibility (System
# Settings › Privacy & Security › Accessibility: Terminal, say), which GitHub's macOS runners have. It runs with the
# bash macOS comes with (3.2).
set -euo pipefail

usage="usage: scripts/self-test.sh [--timeout <seconds>] [--expect <file>] <app> <script> <output>"
timeout=240
expect=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout | --expect)
      if [[ $# -lt 2 ]]; then
        echo "$usage" >&2
        exit 2
      fi

      if [[ "$1" == "--timeout" ]]; then
        timeout="$2"
      else
        expect="$2"
      fi

      shift 2
      ;;
    -*)
      echo "$usage" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 3 || ! "$timeout" =~ ^[0-9]+$ ]]; then
  echo "$usage" >&2
  exit 2
fi

app="$1"
script="$2"
output="$3"
executable="$app"
if [[ -d "$app" ]]; then
  executable="$app/Contents/MacOS/VoiceAssistant"
fi

if [[ ! -f "$executable" || ! -x "$executable" ]]; then
  echo "error: no Voice Assistant executable at $executable" >&2
  exit 2
fi

if [[ ! -f "$script" ]]; then
  echo "error: no self-test script at $script" >&2
  exit 2
fi

if [[ -n "$expect" && ! -f "$expect" ]]; then
  echo "error: no expected-lines file at $expect" >&2
  exit 2
fi

name="$(basename "$script")"
name="${name%.selftest.txt}"
mkdir -p "$(dirname "$output")"
rm -f "$output"

# Started directly rather than with `open`, so macOS counts what started it for the permissions.
started=$SECONDS
"$executable" --self-test "$script" "$output" &
pid=$!
timed_out=0
while kill -0 "$pid" 2>/dev/null; do
  if ((SECONDS - started >= timeout)); then
    timed_out=1
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    break
  fi

  sleep 1
done

code=0
wait "$pid" 2>/dev/null || code=$?
elapsed=$((SECONDS - started))

# What went wrong besides the output's own lines.
notes=()
if ((timed_out)); then
  notes+=("!! stopped after ${timeout} s")
elif ((code != 0)); then
  notes+=("!! Voice Assistant exited with code $code")
fi

passes=0
failures=0
stops=0
if [[ -f "$output" ]]; then
  passes="$(grep -c '^   PASS: ' "$output" || true)"
  failures="$(grep -c '^   FAIL: ' "$output" || true)"
  stops="$(grep -c '^!!' "$output" || true)"
else
  notes+=("!! the self-test wrote no output")
fi

missing=0
if [[ -n "$expect" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "$line" || "$line" == "#"* ]]; then
      continue
    fi

    if [[ ! -f "$output" ]] || ! grep -qxF -- "$line" "$output"; then
      notes+=("!! missing from the output: $line")
      missing=$((missing + 1))
    fi
  done <"$expect"
fi

failed=0
if ((timed_out || code != 0 || failures > 0 || stops > 0 || passes == 0 || missing > 0)); then
  failed=1
fi

summary="$passes passed, $failures failed"
if ((missing > 0)); then
  summary+=", $missing expected lines missing"
fi

summary+=" ($elapsed s)"

# The output and the notes, as printed here and in the job's summary.
report() {
  if [[ -f "$output" ]]; then
    cat "$output"
  fi

  for note in ${notes[@]+"${notes[@]}"}; do
    echo "$note"
  done
}

report
echo
echo "$name: $summary"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Self-test: $name"
    echo
    if ((failed)); then
      echo "**Failed:** $summary"
    else
      echo "**Passed:** $summary"
    fi

    echo
    echo '```'
    report
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi

if ((failed)) && [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "::error title=Self-test ${name}::$summary"
fi

exit "$failed"