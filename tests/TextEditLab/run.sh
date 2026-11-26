#!/usr/bin/env bash
# The TextEdit lab (docs/self-test.md): Voice Assistant opens TextEdit by voice, types into a new document by voice
# (with a line break) and by dictation, pasted and with keys, reads it back and clears it, all through the real desktop.
#
#   tests/TextEditLab/run.sh <app> [<results folder>]
#
# <app> is "Voice Assistant.app" or its executable (scripts/self-test.sh). TextEdit mustn't be running: the lab quits
# it when it's done, without saving. While it runs, TextEdit starts with a new document rather than its Open panel and
# restores no windows; those two settings are put back afterwards. The results folder (by default
# $TMPDIR/voice-assistant-self-test/textedit) gets the output (output.txt) and the app's log of the run. Exits as
# scripts/self-test.sh does.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: tests/TextEditLab/run.sh <app> [<results folder>]" >&2
  exit 2
fi

app="$1"
results="${2:-${TMPDIR:-/tmp}/voice-assistant-self-test/textedit}"
logs="$HOME/Library/Logs/VoiceAssistant"
if pgrep -x TextEdit >/dev/null; then
  echo "error: TextEdit is running; quit it first (the lab quits TextEdit when it's done, without saving)" >&2
  exit 2
fi

settings=(NSShowAppCentricOpenPanelInsteadOfUntitledFile ApplePersistenceIgnoreState)
values=(false true)
saved=()
for key in "${settings[@]}"; do
  saved+=("$(defaults read com.apple.TextEdit "$key" 2>/dev/null || echo unset)")
done

mkdir -p "$results"
started="$results/.started"
: >"$started"

finish() {
  pkill -x TextEdit 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x TextEdit >/dev/null || break
    sleep 1
  done

  pkill -9 -x TextEdit 2>/dev/null || true
  for i in "${!settings[@]}"; do
    case "${saved[$i]}" in
      unset) defaults delete com.apple.TextEdit "${settings[$i]}" 2>/dev/null || true ;;
      1) defaults write com.apple.TextEdit "${settings[$i]}" -bool true || true ;;
      *) defaults write com.apple.TextEdit "${settings[$i]}" -bool false || true ;;
    esac
  done

  # The app's log of the run (states, outcomes and timings, never text): the day's log files it wrote to.
  if [[ -d "$logs" ]]; then
    find "$logs" -name '*.log' -newer "$started" -exec cp {} "$results/" \; 2>/dev/null || true
  fi

  rm -f "$started"
}
trap finish EXIT

for i in "${!settings[@]}"; do
  defaults write com.apple.TextEdit "${settings[$i]}" -bool "${values[$i]}"
done

status=0
"$root/scripts/self-test.sh" --expect "$here/textedit-lab.expected.txt" \
  "$app" "$here/textedit-lab.selftest.txt" "$results/output.txt" || status=$?
exit "$status"