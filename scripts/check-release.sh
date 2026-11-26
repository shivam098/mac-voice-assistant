#!/usr/bin/env bash
# Checks that Voice Assistant can be released at a version. The Release workflow (.github/workflows/release.yml) runs
# it before building, and again just before publishing.
#
#   scripts/check-release.sh <version> <dry run: true or false>
#
# - The version is three numbers such as 0.1.0, and it's the app's own: VoiceAssistantApp.version in the source, which
#   is VoiceAssistantCore.version.
# - Its release notes are in docs/release-notes/v<version>.md.
# - The run was started on main (GITHUB_REF, which GitHub sets, is refs/heads/main): releases come from main only.
# - Package.swift pins thumbfree-mac to a commit (revision: "<its 40-character SHA>"), so the release can be built
#   again. The Mac workflow's daily run builds against thumbfree-mac's main instead, as a canary.
# - Neither the tag v<version> nor a release with that tag exists, so nothing is replaced.
#
# The first two stop any run. The last three stop a real run; a dry run only warns about them, and says that a real run
# would refuse. Needs git with an origin remote, and gh signed in (GH_TOKEN, and GH_REPO for the repository). It runs
# with bash 3.2 (a Mac's /bin/bash) and later, and with the Mac's sed, grep and tr as well as GNU's.
set -euo pipefail
# Bash 4.4 and later only; nothing here relies on it, since every command whose output it reads is checked.
shopt -s inherit_errexit 2>/dev/null || true

cd "$(dirname "$0")/.."

version="${1:-}"
dry_run="${2:-}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

# What stops a real run, and only warns in a dry run.
refusals=0
refuse() {
  if [[ "$dry_run" == true ]]; then
    echo "::warning::$* A real run would refuse." >&2
  else
    echo "::error::$*" >&2
    refusals=$((refusals + 1))
  fi
}

if [[ "$dry_run" != true && "$dry_run" != false ]]; then
  fail "The dry run must be true or false, not '$dry_run'."
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "The version must be three numbers such as 0.1.0, not '$version'."
fi

# What the one `static let version = …` in a Swift file says, as written: a string literal with its quotes, or an
# expression such as VoiceAssistantCore.version.
swift_version() {
  local values pattern
  [[ -f "$1" ]] || fail "$1 is missing."
  pattern='^[[:space:]]*(public[[:space:]]+)?static[[:space:]]+let[[:space:]]+version'
  pattern+='([[:space:]]*:[[:space:]]*String)?[[:space:]]*=[[:space:]]*'
  values="$(sed -nE "s#$pattern##p" "$1" | sed -E 's#[[:space:]]*(//.*)?$##')"
  if [[ -z "$values" || "$values" == *$'\n'* ]]; then
    fail "Expected one 'static let version = …' in $1."
  fi
  echo "$values"
}

app_file=Sources/VoiceAssistantApp/VoiceAssistantApp.swift
core_file=Sources/VoiceAssistantCore/VoiceAssistantCore.swift
source_version="$(swift_version "$app_file")"
where="VoiceAssistantApp.version, in $app_file"
if [[ "$source_version" == VoiceAssistantCore.version ]]; then
  source_version="$(swift_version "$core_file")"
  where="VoiceAssistantApp.version, which is VoiceAssistantCore.version, in $core_file"
fi
string_pattern='^"([^"]*)"$'
if [[ ! "$source_version" =~ $string_pattern ]]; then
  fail "Can't read the app's version ($where): it's $source_version, not a string."
fi
source_version="${BASH_REMATCH[1]}"
if [[ "$version" != "$source_version" ]]; then
  fail "The app's version is $source_version, not $version ($where)."
fi
echo "Version $version: the app's ($where)."

notes="docs/release-notes/v$version.md"
if [[ ! -s "$notes" ]]; then
  fail "There are no release notes for $version: $notes is missing or empty."
fi
echo "Release notes: $notes."

ref="${GITHUB_REF:-}"
if [[ "$ref" == refs/heads/main ]]; then
  echo "Started on main."
elif [[ -z "$ref" ]]; then
  refuse "Releases come from main only, by the Release workflow, and GITHUB_REF isn't set."
else
  refuse "Releases come from main only, but this run was started on $ref."
fi

# thumbfree-mac's dependency in Package.swift, read without comments and as one line.
dependencies="$(sed -E 's#(^|[[:space:]])//.*$##' Package.swift | tr -s '[:space:]' ' ' |
  grep -oE '\.package\([^()]*thumbfree-mac[^()]*\)' || true)"
pin_pattern='revision: *"([0-9a-fA-F]{40})"'
pin_example='.package(url: "https://github.com/shivam098/thumbfree-mac.git", revision: "<its 40-character SHA>")'
if [[ -z "$dependencies" ]]; then
  refuse "Package.swift has no thumbfree-mac dependency this script can read. A release pins it with $pin_example."
elif [[ "$dependencies" == *$'\n'* ]]; then
  refuse "Package.swift has more than one thumbfree-mac dependency: $(tr '\n' ' ' <<<"$dependencies")"
elif [[ "$dependencies" =~ $pin_pattern ]]; then
  echo "thumbfree-mac: pinned to ${BASH_REMATCH[1]}."
else
  refuse "Package.swift doesn't pin thumbfree-mac to a commit ($dependencies), so building this release again could" \
    "use a different thumbfree-mac. Pin it with $pin_example."
fi

tag="v$version"
status=0
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || status=$?
case "$status" in
  0) refuse "The tag $tag exists already, and a release never replaces one." ;;
  2) echo "Tag $tag: not on origin yet." ;;
  *) fail "Couldn't list origin's tags: git ls-remote exited with $status." ;;
esac

query=".[] | select(.tagName == \"$tag\") | .tagName"
if ! releases="$(gh release list --limit 1000 --json tagName --jq "$query")"; then
  fail "Couldn't list the releases with gh."
fi
if [[ -n "$releases" ]]; then
  refuse "A release with the tag $tag exists already, and a release never replaces one."
else
  echo "Release $tag: none yet."
fi

if ((refusals > 0)); then
  fail "$version can't be released: see above."
fi
if [[ "$dry_run" == true ]]; then
  echo "A dry run of $version can go ahead."
else
  echo "$version can be released."
fi
