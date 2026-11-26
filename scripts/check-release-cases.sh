#!/usr/bin/env bash
# Tries scripts/check-release.sh on copies of the files it reads, in throwaway repositories. Runs with bash 3.2 (a Mac's
# /bin/bash) and later, and with BSD or GNU sed, grep, awk and tr. CHECK_SHELL is the bash the script is run with (bash
# by default); gh must be signed in (GH_TOKEN).
#
#   check-release-cases.sh <a checkout of mac-voice-assistant>
set -uo pipefail

repo="$(cd "$1" && pwd)"
sh="${CHECK_SHELL:-bash}"
cases="${RUNNER_TEMP:-$PWD}/check-release-cases"
rm -rf "$cases"
mkdir -p "$cases"
passed=0
failed=0
sha=42cfbb1c0d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a
pin="revision: \"$sha\""
mac=https://github.com/shivam098/mac-voice-assistant.git
export GH_REPO=shivam098/mac-voice-assistant
export GITHUB_REF=refs/heads/main
export GIT_TERMINAL_PROMPT=0

# make_case <name> <origin url>: a copy of the files the script reads, in a git repository whose origin is <origin url>.
make_case() {
  local dir="$cases/$1"
  mkdir -p "$dir/scripts" "$dir/Sources/VoiceAssistantApp" "$dir/Sources/VoiceAssistantCore" "$dir/docs/release-notes"
  cp "$repo/scripts/check-release.sh" "$dir/scripts/"
  cp "$repo/Sources/VoiceAssistantApp/VoiceAssistantApp.swift" "$dir/Sources/VoiceAssistantApp/"
  cp "$repo/Sources/VoiceAssistantCore/VoiceAssistantCore.swift" "$dir/Sources/VoiceAssistantCore/"
  cp "$repo/Package.swift" "$dir/"
  echo "Notes" >"$dir/docs/release-notes/v0.1.0.md"
  git -c init.defaultBranch=main -C "$dir" init -q
  git -C "$dir" remote add origin "$2"
  echo "$dir"
}

# edit <file> <sed arguments…>: sed without -i, which BSD and GNU sed take differently.
edit() {
  local file="$1"
  shift
  sed "$@" "$file" >"$file.new" && mv "$file.new" "$file"
}

# awk_edit <file> <awk program>: the same with awk, for lines that become several.
awk_edit() {
  awk -v sha="$sha" "$2" "$1" >"$1.new" && mv "$1.new" "$1"
}

# expect <name> <exit status> <pattern in the output> <command…>
expect() {
  local name="$1" want="$2" pattern="$3" output status
  shift 3
  output="$("$@" 2>&1)"
  status=$?
  if [[ "$status" == "$want" ]] && grep -qE -- "$pattern" <<<"$output"; then
    echo "PASS $name"
    passed=$((passed + 1))
  else
    echo "FAIL $name (exit $status, wanted $want and /$pattern/)"
    sed 's/^/    /' <<<"$output"
    failed=$((failed + 1))
  fi
}

# expect_no <name> <pattern> <command…>: the command succeeds and its output doesn't match.
expect_no() {
  local name="$1" pattern="$2" output status
  shift 2
  output="$("$@" 2>&1)"
  status=$?
  if [[ "$status" == 0 ]] && ! grep -qE -- "$pattern" <<<"$output"; then
    echo "PASS $name"
    passed=$((passed + 1))
  else
    echo "FAIL $name (exit $status, wanted 0 and no /$pattern/)"
    sed 's/^/    /' <<<"$output"
    failed=$((failed + 1))
  fi
}

echo "Running scripts/check-release.sh with $sh: $("$sh" -c 'echo "$BASH_VERSION"')"

d="$(make_case main "$mac")"
s="$d/scripts/check-release.sh"
expect "main, dry run: warns about the pin" 0 '::warning::Package.swift doesn.t pin thumbfree-mac.*branch: "main".*A real run would refuse' "$sh" "$s" 0.1.0 true
expect "main, dry run: reads VoiceAssistantCore.version" 0 'Version 0.1.0: the app.s \(VoiceAssistantApp.version, which is VoiceAssistantCore.version, in Sources/VoiceAssistantCore/VoiceAssistantCore.swift\)\.' "$sh" "$s" 0.1.0 true
expect "main, dry run: started on main" 0 '^Started on main\.$' "$sh" "$s" 0.1.0 true
expect "main, dry run: no tag, no release" 0 'Tag v0.1.0: not on origin yet' "$sh" "$s" 0.1.0 true
expect "main, dry run: goes ahead" 0 'A dry run of 0.1.0 can go ahead' "$sh" "$s" 0.1.0 true
expect "main, real run: refuses the unpinned dependency" 1 "::error::Package.swift doesn't pin thumbfree-mac" "$sh" "$s" 0.1.0 false
expect "main, real run: says it can't be released" 1 "0.1.0 can't be released" "$sh" "$s" 0.1.0 false
expect "wrong version" 1 "The app's version is 0.1.0, not 0.2.0" "$sh" "$s" 0.2.0 true
expect "v prefix" 1 "three numbers such as 0.1.0, not 'v0.1.0'" "$sh" "$s" v0.1.0 true
expect "two numbers" 1 "not '0.1'" "$sh" "$s" 0.1 true
expect "empty version" 1 "not ''" "$sh" "$s" "" true
expect "dry run yes" 1 "must be true or false, not 'yes'" "$sh" "$s" 0.1.0 yes
expect "dry run missing" 1 "must be true or false, not ''" "$sh" "$s" 0.1.0

d="$(make_case pinned "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Package.swift" -E "s#branch: \"main\"#$pin#"
expect "pinned, real run on main" 0 '0.1.0 can be released' "$sh" "$s" 0.1.0 false
expect "pinned, real run: names the commit" 0 "thumbfree-mac: pinned to $sha" "$sh" "$s" 0.1.0 false
expect_no "pinned, dry run on main: no warning" 'warning' "$sh" "$s" 0.1.0 true
expect "pinned, real run on another branch" 1 '::error::Releases come from main only, but this run was started on refs/heads/release-1\.$' env GITHUB_REF=refs/heads/release-1 "$sh" "$s" 0.1.0 false
expect "pinned, real run on a branch that starts with main" 1 'started on refs/heads/main-old\.$' env GITHUB_REF=refs/heads/main-old "$sh" "$s" 0.1.0 false
expect "pinned, real run on a tag" 1 'started on refs/tags/v0.1.0\.$' env GITHUB_REF=refs/tags/v0.1.0 "$sh" "$s" 0.1.0 false
expect "pinned, real run on a pull request" 1 'started on refs/pull/21/merge\.$' env GITHUB_REF=refs/pull/21/merge "$sh" "$s" 0.1.0 false
expect "pinned, real run without GITHUB_REF" 1 "::error::Releases come from main only, by the Release workflow, and GITHUB_REF isn't set\.$" env -u GITHUB_REF "$sh" "$s" 0.1.0 false
expect "pinned, real run with an empty GITHUB_REF" 1 "GITHUB_REF isn't set" env GITHUB_REF= "$sh" "$s" 0.1.0 false
expect "pinned, real run on another branch: can't be released" 1 "0.1.0 can't be released" env GITHUB_REF=refs/heads/release-1 "$sh" "$s" 0.1.0 false
expect "pinned, dry run on another branch: only warns" 0 '::warning::Releases come from main only, but this run was started on refs/heads/release-1\. A real run would refuse\.$' env GITHUB_REF=refs/heads/release-1 "$sh" "$s" 0.1.0 true
expect "pinned, dry run on another branch: goes ahead" 0 'A dry run of 0.1.0 can go ahead' env GITHUB_REF=refs/heads/release-1 "$sh" "$s" 0.1.0 true
expect "pinned, dry run without GITHUB_REF: only warns" 0 "::warning::Releases come from main only, by the Release workflow, and GITHUB_REF isn't set\. A real run would refuse\." env -u GITHUB_REF "$sh" "$s" 0.1.0 true

d="$(make_case pinned-wrapped "$mac")"
s="$d/scripts/check-release.sh"
awk_edit "$d/Package.swift" '/thumbfree-mac\.git", branch: "main"\),/ { indent = $0; sub(/\..*/, "", indent); print indent ".package("; print indent "    url: \"https://github.com/shivam098/thumbfree-mac.git\","; print indent "    revision: \"" sha "\"),"; next } { print }'
grep -n -A3 'package($' "$d/Package.swift" | sed 's/^/    /'
expect "pinned over three lines" 0 '0.1.0 can be released' "$sh" "$s" 0.1.0 false

d="$(make_case pinned-old-commented "$mac")"
s="$d/scripts/check-release.sh"
awk_edit "$d/Package.swift" '/thumbfree-mac\.git", branch: "main"\),/ { old = $0; sub(/\.package/, "// .package", old); print old; sub(/branch: "main"/, "revision: \"" sha "\""); print; next } { print }'
grep -n 'thumbfree-mac.git' "$d/Package.swift" | sed 's/^/    /'
expect "pinned, the old line commented out" 0 '0.1.0 can be released' "$sh" "$s" 0.1.0 false

d="$(make_case two "$mac")"
s="$d/scripts/check-release.sh"
awk_edit "$d/Package.swift" '/thumbfree-mac\.git", branch: "main"\),/ { print; sub(/branch: "main"/, "revision: \"" sha "\""); print; next } { print }'
expect "two thumbfree-mac dependencies" 1 'more than one thumbfree-mac dependency' "$sh" "$s" 0.1.0 false

d="$(make_case exact "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Package.swift" -E 's#branch: "main"#exact: "1.0.0"#'
expect "an exact version isn't a commit" 1 "doesn't pin thumbfree-mac to a commit" "$sh" "$s" 0.1.0 false

d="$(make_case short-sha "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Package.swift" -E 's#branch: "main"#revision: "42cfbb1"#'
expect "a short SHA isn't enough" 1 "doesn't pin thumbfree-mac to a commit" "$sh" "$s" 0.1.0 false

d="$(make_case none "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Package.swift" -E '/thumbfree-mac.git/d'
expect "no dependency" 1 'no thumbfree-mac dependency this script can read' "$sh" "$s" 0.1.0 false

d="$(make_case no-notes "$mac")"
s="$d/scripts/check-release.sh"
rm "$d/docs/release-notes/v0.1.0.md"
expect "no notes, dry run" 1 'no release notes for 0.1.0: docs/release-notes/v0.1.0.md' "$sh" "$s" 0.1.0 true

d="$(make_case empty-notes "$mac")"
s="$d/scripts/check-release.sh"
: >"$d/docs/release-notes/v0.1.0.md"
expect "empty notes" 1 'missing or empty' "$sh" "$s" 0.1.0 true

d="$(make_case literal "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Sources/VoiceAssistantApp/VoiceAssistantApp.swift" -E 's#version = VoiceAssistantCore.version#version: String = "0.1.0" // the app'"'"'s#'
edit "$d/Sources/VoiceAssistantCore/VoiceAssistantCore.swift" -E 's#version = "0.1.0"#version = "9.9.9"#'
grep -n 'let version' "$d/Sources/VoiceAssistantApp/VoiceAssistantApp.swift" | sed 's/^/    /'
expect "VoiceAssistantApp.version as a string" 0 'Version 0.1.0: the app.s \(VoiceAssistantApp.version, in Sources/VoiceAssistantApp/VoiceAssistantApp.swift\)\.' "$sh" "$s" 0.1.0 true

d="$(make_case expression "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Sources/VoiceAssistantApp/VoiceAssistantApp.swift" -E 's#version = VoiceAssistantCore.version#version = Other.version#'
expect "an expression it can't read" 1 "Can't read the app's version \(VoiceAssistantApp.version, in .*\): it's Other.version, not a string" "$sh" "$s" 0.1.0 true

d="$(make_case interpolated "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Sources/VoiceAssistantCore/VoiceAssistantCore.swift" -E 's#version = "0.1.0"#version = "\\(major).1.0"#'
expect "an interpolated version" 1 'The app.s version is \\\(major\).1.0, not 0.1.0' "$sh" "$s" 0.1.0 true

d="$(make_case no-version "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Sources/VoiceAssistantCore/VoiceAssistantCore.swift" -E '/static let version/d'
expect "no version line" 1 "Expected one 'static let version = .*' in Sources/VoiceAssistantCore/VoiceAssistantCore.swift" "$sh" "$s" 0.1.0 true

d="$(make_case missing-file "$mac")"
s="$d/scripts/check-release.sh"
rm "$d/Sources/VoiceAssistantCore/VoiceAssistantCore.swift"
expect "a missing source file" 1 'Sources/VoiceAssistantCore/VoiceAssistantCore.swift is missing' "$sh" "$s" 0.1.0 true

# A tag and a release that exist: windows-voice-assistant's v0.12.1.
d="$(make_case taken https://github.com/shivam098/windows-voice-assistant.git)"
s="$d/scripts/check-release.sh"
edit "$d/Sources/VoiceAssistantCore/VoiceAssistantCore.swift" -E 's#version = "0.1.0"#version = "0.12.1"#'
edit "$d/Package.swift" -E "s#branch: \"main\"#$pin#"
echo "Notes" >"$d/docs/release-notes/v0.12.1.md"
expect "existing tag, real run" 1 '::error::The tag v0.12.1 exists already' env GH_REPO=shivam098/windows-voice-assistant "$sh" "$s" 0.12.1 false
expect "existing release, real run" 1 '::error::A release with the tag v0.12.1 exists already' env GH_REPO=shivam098/windows-voice-assistant "$sh" "$s" 0.12.1 false
expect "existing tag and release, dry run: warnings" 0 '::warning::A release with the tag v0.12.1 exists already.*A real run would refuse' env GH_REPO=shivam098/windows-voice-assistant "$sh" "$s" 0.12.1 true

d="$(make_case bad-origin https://github.com/shivam098/no-such-repository-here.git)"
s="$d/scripts/check-release.sh"
edit "$d/Package.swift" -E "s#branch: \"main\"#$pin#"
expect "origin can't be read" 1 "Couldn't list origin's tags" "$sh" "$s" 0.1.0 false

d="$(make_case bad-gh "$mac")"
s="$d/scripts/check-release.sh"
edit "$d/Package.swift" -E "s#branch: \"main\"#$pin#"
expect "gh can't list the releases" 1 "Couldn't list the releases with gh" env GH_REPO=shivam098/no-such-repository-here "$sh" "$s" 0.1.0 false

echo "passed $passed, failed $failed"
((failed == 0))
