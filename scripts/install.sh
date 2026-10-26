#!/bin/bash
# Installs the newest Corral into /Applications, or updates it, from its GitHub releases.
# Downloaded this way rather than by a browser, macOS doesn't stop Corral the first time it
# opens.
#
# Before anything is replaced, the download is checked against the SHA-256 fingerprint
# published with the release, and the app's signature and version are checked. The old Corral
# is only removed once the new one is in place, so a failed update leaves it as it was.
#
# For a first install, paste this into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/khoinguyenpham04/corral/main/scripts/install.sh | bash
#
# Corral runs it for updates, too (`corral update`, or Install in the panel).
set -euo pipefail

project="https://github.com/khoinguyenpham04/corral"
target="/Applications"
[ -w "$target" ] || target="$HOME/Applications"
step() { printf '\033[38;2;255;82;20m✦\033[0m %s\n' "$1"; }
fail() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }
download() { curl --fail --location --silent --show-error "$project/releases/download/v$version/$1" "${@:2}"; }

# The newest release is where GitHub's "latest" link leads: …/releases/tag/v0.4.0.
version="${CORRAL_VERSION:-$(curl --fail --location --silent --head --output /dev/null --write-out '%{url_effective}' "$project/releases/latest" 2>/dev/null | sed -n 's#.*/releases/tag/v##p' || true)}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "couldn't find the newest release. Are you online? Releases are at $project/releases"

work="$(mktemp -d)"
quit_corral=0
finish() {
  local status=$?
  hdiutil detach -quiet "$work/mount" 2>/dev/null || true
  rm -rf "$work"
  # Corral was quit for the switch-over. If the install failed after that, reopen the copy
  # that's there, so a failed update never leaves you without Corral.
  if [ "$status" != 0 ] && [ "$quit_corral" = 1 ] && [ -d "$target/Corral.app" ]; then open "$target/Corral.app" || true; fi
}
trap finish EXIT

step "Downloading Corral $version"
download "Corral-$version.dmg" -o "$work/Corral.dmg" \
  || fail "couldn't download Corral $version. The release page has it: $project/releases/tag/v$version"

expected="$(download "Corral-$version.dmg.sha256" 2>/dev/null | awk '{ print $1 }' || true)"
actual="$(shasum -a 256 "$work/Corral.dmg" | awk '{ print $1 }')"
if [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  [ "$actual" = "$expected" ] || fail "the download doesn't match the fingerprint published with Corral $version, so nothing was installed. Try again in a minute."
  step "Checked the download: SHA-256 ${actual:0:12}… matches the release"
else
  step "Corral $version was published without a fingerprint; its SHA-256 is ${actual:0:12}…"
fi

mkdir "$work/mount"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$work/mount" "$work/Corral.dmg"
app="$work/mount/Corral.app"
[ -d "$app" ] || fail "the download doesn't contain Corral.app"
codesign --verify --deep --strict "$app" 2>/dev/null || fail "Corral.app in the download is damaged (its signature doesn't verify), so nothing was installed"
inside="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$inside" = "$version" ] || fail "the download holds Corral ${inside:-of no version}, not $version, so nothing was installed"

# Copy the new app next to the old one first, so the switch-over is two renames.
step "Installing into $target"
mkdir -p "$target"
staged="$target/.Corral-$version.app"
previous="$target/.Corral-previous.app"
rm -rf "$staged" "$previous"
ditto "$app" "$staged"
codesign --verify --deep --strict "$staged" 2>/dev/null || { rm -rf "$staged"; fail "copying Corral into $target went wrong, so nothing was changed"; }

# -a: when Corral runs this for an update, Corral is this script's parent, and pgrep and pkill
# skip their own ancestors unless told not to.
if pgrep -a -x Corral >/dev/null; then
  step "Quitting the running Corral"
  quit_corral=1
  pkill -a -x Corral || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -a -x Corral >/dev/null || break; sleep 0.5; done
fi

if [ -e "$target/Corral.app" ] && ! mv "$target/Corral.app" "$previous"; then
  rm -rf "$staged"
  fail "couldn't move the old Corral aside, so it's still installed as it was"
fi
if ! mv "$staged" "$target/Corral.app"; then
  [ ! -e "$previous" ] || mv "$previous" "$target/Corral.app"
  rm -rf "$staged"
  fail "couldn't put the new Corral in place, so the old one is back"
fi
rm -rf "$previous"

step "Opening Corral $version"
open "$target/Corral.app"
