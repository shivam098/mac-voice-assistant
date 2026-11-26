#!/usr/bin/env bash
# Opens Voice Assistant.app as a person does and checks that it starts into its UI: its log says the menu bar item, the
# pill and the window are ready and the window opened at Home, and it's still running a few seconds later. Then it quits
# the app. The app's log, a screenshot of the screen (what a person sees at first launch, when macOS lets this capture
# it) and any crash report go to <output folder>.
#
#   scripts/launch-check.sh <Voice Assistant.app> <output folder>
#
# It writes the app's settings.json first, so the check is quick and asks for nothing: a speech model that isn't there
# (nothing is downloaded), no listening at launch (macOS doesn't ask for the microphone) and no AI brain. That file is
# this Mac's own, so it runs only on CI (CI=true, as on GitHub's runners). On GitHub Actions the result and the app's
# log also go to the job's summary. It runs with the bash macOS comes with (3.2).
set -euo pipefail

usage="usage: scripts/launch-check.sh <Voice Assistant.app> <output folder>"
if [[ $# -ne 2 ]]; then
  echo "$usage" >&2
  exit 2
fi

app="$1"
out="$2"
if [[ ! -x "$app/Contents/MacOS/VoiceAssistant" ]]; then
  echo "error: no Voice Assistant.app at $app" >&2
  exit 2
fi

if [[ "${CI:-}" != "true" ]]; then
  echo "error: this replaces ~/Library/Application Support/VoiceAssistant/settings.json, so it runs only on CI" >&2
  exit 2
fi

data="$HOME/Library/Application Support/VoiceAssistant"
logs="$HOME/Library/Logs/VoiceAssistant"
mkdir -p "$data" "$out"
cat >"$data/settings.json" <<'EOF'
{
  "modelFile": "launch-check-no-such-model.bin",
  "listenOnStartup": false,
  "brainEnabled": false
}
EOF

ready="ui: menu bar item, pill and window ready"
opened="ui: window opened at Home"
wait_seconds=60
stay_seconds=5

# Through Launch Services, as Finder opens it, so macOS asks its permissions of the app itself.
open "$app"
started=$SECONDS
seen=0
while ((SECONDS - started < wait_seconds)); do
  if grep -qF "$opened" "$logs"/*.log 2>/dev/null; then
    seen=1
    break
  fi

  sleep 1
done

# Time to draw the window and the pill, and to stay up.
sleep "$stay_seconds"
pid="$(pgrep -x VoiceAssistant | head -n 1 || true)"
if ! screencapture -x "$out/first-launch.png" 2>/dev/null; then
  echo "note: macOS didn't let this capture the screen"
fi

if [[ -n "$pid" ]]; then
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi

    sleep 1
  done

  kill -9 "$pid" 2>/dev/null || true
fi

cp "$logs"/*.log "$out/" 2>/dev/null || true
cp "$HOME"/Library/Logs/DiagnosticReports/VoiceAssistant* "$out/" 2>/dev/null || true

problems=0
notes=""
note() {
  notes+="$1"$'\n'
  problems=$((problems + 1))
}

if ! grep -qF "$ready" "$logs"/*.log 2>/dev/null; then
  note "!! its log doesn't say the menu bar item, the pill and the window are ready"
fi

if ((!seen)); then
  note "!! its log doesn't say the window opened at Home within $wait_seconds s"
fi

if [[ -z "$pid" ]]; then
  note "!! it wasn't running $stay_seconds s later"
fi

if grep -qF "start failed" "$logs"/*.log 2>/dev/null; then
  note "!! it couldn't start"
fi

if ((problems)); then
  result="Voice Assistant didn't start into its UI"
else
  result="Voice Assistant started into its UI and was still running $stay_seconds s later"
fi

# The app's log (states, timings and app names; never text or window titles), then what went wrong.
report() {
  cat "$logs"/*.log 2>/dev/null || echo "(no log)"
  printf '%s' "$notes"
}

report
echo
echo "$result"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Launch check"
    echo
    if ((problems)); then
      echo "**Failed:** $result"
    else
      echo "**Passed:** $result"
    fi

    echo
    echo '```'
    report
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi

if ((problems)); then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::error title=Launch check::$result"
  fi

  exit 1
fi