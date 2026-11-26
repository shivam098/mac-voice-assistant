#!/usr/bin/env bash
# The NavigationLab (docs/self-test.md): Voice Assistant's voice navigation in a browser through the real controller and
# desktop, the acceptance scenarios N1–N9 of windows-voice-assistant (docs/specs/acceptance-tests.md), and N10 and N16
# as its nav-lab.selftest.txt has them: tabs by position and by site, clicks by name and side, numbers for a name two
# buttons have, a click that waits for "yes", typing into boxes by name and by number, numbers on everything, a chat
# list's rows, back and forward.
#
#   tests/NavigationLab/run.sh <app> chrome|safari [<results folder>]
#
# <app> is "Voice Assistant.app" or its executable (scripts/self-test.sh). The lab's pages (videos.html, lab.html,
# mail.html and chats.html, in that order) open in a new window of the browser:
# - chrome: Google Chrome with a temporary profile, so a process of its own whatever else Chrome has open, as Windows'
#   NavigationLab starts it; the pages are files. It quits when the lab is done, and the profile is deleted.
# - safari: Safari, which mustn't be running (the lab quits it when it's done). The pages come from a web server on
#   this Mac (python3's, on 127.0.0.1 only) that the lab starts and stops: Safari asks before it shows a file that
#   AppleScript opens. The tabs are opened with AppleScript, and the app lists them with AppleScript, so whatever starts
#   the lab needs the Automation permission for Safari (Terminal asks for it the first time).
# The results folder (by default $TMPDIR/voice-assistant-self-test/nav-lab-<browser>) gets the output (output.txt) and
# the app's log files written during the run (and Safari's web server's log). Exits as scripts/self-test.sh does.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
usage="usage: tests/NavigationLab/run.sh <app> chrome|safari [<results folder>]"
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "$usage" >&2
  exit 2
fi

app="$1"
browser="$2"
case "$browser" in
  chrome)
    bundle="com.google.Chrome"
    browser_app="/Applications/Google Chrome.app"
    ;;
  safari)
    bundle="com.apple.Safari"
    browser_app="/Applications/Safari.app"
    ;;
  *)
    echo "$usage" >&2
    exit 2
    ;;
esac

if [[ ! -d "$browser_app" ]]; then
  echo "error: no $browser_app" >&2
  exit 2
fi

if [[ "$browser" == "safari" ]] && pgrep -x Safari >/dev/null; then
  echo "error: Safari is running; quit it first (the lab quits Safari when it's done)" >&2
  exit 2
fi

results="${3:-${TMPDIR:-/tmp}/voice-assistant-self-test/nav-lab-$browser}"
logs="$HOME/Library/Logs/VoiceAssistant"
mkdir -p "$results"
started="$results/.started"
: >"$started"
profile=""
server=""

# The app in front, by bundle identifier (Launch Services' own tool: no permission needed).
front_app() {
  lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p'
}

# Stops a process: asked first (SIGTERM), then made to after 5 s.
stop() {
  kill "$1" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.5
  done

  kill -9 "$1" 2>/dev/null || true
}

finish() {
  if [[ -n "$profile" ]]; then
    # Only the lab's Chrome: the one with its profile.
    for pid in $(pgrep -f -- "--user-data-dir=$profile" || true); do
      stop "$pid"
    done

    rm -rf "$profile"
  fi

  if [[ "$browser" == "safari" ]]; then
    for pid in $(pgrep -x Safari || true); do
      stop "$pid"
    done
  fi

  if [[ -n "$server" ]]; then
    stop "$server"
  fi

  # The app's log of the run (states, outcomes and timings, never text): the day's log files it wrote to.
  if [[ -d "$logs" ]]; then
    find "$logs" -name '*.log' -newer "$started" -exec cp {} "$results/" \; 2>/dev/null || true
  fi

  rm -f "$started"
}
trap finish EXIT

if [[ "$browser" == "chrome" ]]; then
  profile="$(mktemp -d "${TMPDIR:-/tmp}/voice-assistant-nav-lab-chrome.XXXXXX")"
  pages=()
  for page in videos lab mail chats; do
    pages+=("file://$here/$page.html")
  done

  open -n -a "$browser_app" --args "--user-data-dir=$profile" --no-first-run --no-default-browser-check \
    --hide-crash-restore-bubble --use-mock-keychain --new-window "${pages[@]}"
else
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$here" >"$results/server.log" 2>&1 &
  server=$!
  # Stopped by the lab, not a job for bash to report.
  disown "$server"
  port=""
  for _ in $(seq 1 100); do
    port="$(sed -n 's/^Serving HTTP on .* port \([0-9][0-9]*\) .*/\1/p' "$results/server.log" | head -n 1)"
    if [[ -n "$port" ]]; then
      break
    fi

    sleep 0.1
  done

  if [[ -z "$port" ]]; then
    echo "error: the lab's web server didn't start" >&2
    cat "$results/server.log" >&2
    exit 2
  fi

  osascript - "http://127.0.0.1:$port" <<'SCRIPT'
on run argv
  set base to item 1 of argv
  tell application id "com.apple.Safari"
    activate
    make new document with properties {URL:base & "/videos.html"}
    tell front window
      make new tab at end of tabs with properties {URL:base & "/lab.html"}
      make new tab at end of tabs with properties {URL:base & "/mail.html"}
      make new tab at end of tabs with properties {URL:base & "/chats.html"}
      set current tab to tab 1
    end tell
  end tell
end run
SCRIPT
fi

# The browser in front with the pages loaded; the script's first check stops it if the lab's window isn't in front.
for _ in $(seq 1 30); do
  if [[ "$(front_app)" == "$bundle" ]]; then
    break
  fi

  sleep 0.5
done

sleep 3
echo "in front: $(front_app)"

# The script under the browser's name, so the run says which browser it was.
script="$results/nav-lab-$browser.selftest.txt"
cp "$here/nav-lab.selftest.txt" "$script"
status=0
"$root/scripts/self-test.sh" --expect "$here/nav-lab.$browser.expected.txt" \
  "$app" "$script" "$results/output.txt" || status=$?
exit "$status"
