#!/bin/bash
# Builds a universal Corral, packages it, and publishes a GitHub release with the disk image
# and its SHA-256 fingerprint.
#
#   scripts/release.sh            release the version in VERSION
#   scripts/release.sh --dry-run  build and package, but publish nothing
#
# Needs gh, signed in to GitHub: `gh auth login`.
# The release notes are this version's section of CHANGELOG.md, plus how to install.
set -euo pipefail

repo="khoinguyenpham04/corral"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(tr -d '[:space:]' < VERSION)"
tag="v$version"
dry_run=0
[ "${1:-}" = "--dry-run" ] && dry_run=1

if [ "$dry_run" = 0 ]; then
  command -v gh >/dev/null || { echo "release.sh: needs gh (brew install gh)" >&2; exit 1; }
  gh auth status --hostname github.com >/dev/null 2>&1 \
    || { echo "release.sh: gh isn't signed in; run: gh auth login" >&2; exit 1; }
  [ -z "$(git status --porcelain)" ] || { echo "release.sh: commit your changes first" >&2; exit 1; }
  git fetch --quiet origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ] || { echo "release.sh: push first, so the tag matches the code" >&2; exit 1; }
  if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
    echo "release.sh: $tag is already released; bump VERSION and add it to CHANGELOG.md" >&2
    exit 1
  fi
fi
grep -qx "## $version" CHANGELOG.md || { echo "release.sh: CHANGELOG.md has no '## $version' section" >&2; exit 1; }

scripts/build.sh --test
scripts/build.sh --release --universal --package
image="build/release/Corral-$version.dmg"
sha256="$(shasum -a 256 "$image" | cut -d' ' -f1)"
printf '%s  Corral-%s.dmg\n' "$sha256" "$version" > "$image.sha256"

notes="build/release/notes-$version.md"
awk -v heading="## $version" '$0 == heading { on = 1; next } /^## / && on { exit } on' CHANGELOG.md > "$notes"
cat >> "$notes" <<EOF

### Install

Paste this into Terminal. macOS won't stop Corral the first time it opens, because no browser downloaded it:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/$repo/main/scripts/install.sh | bash
\`\`\`

Or download **Corral-$version.dmg** below, drag **Corral** onto **Applications** and open it. Corral isn't notarized by Apple, so macOS stops it once: click **Done**, then **System Settings → Privacy & Security → Open Anyway**.

Corral updates itself: new versions show up in the panel with an **Install** button.

**SHA-256:** \`$sha256\`. The Terminal install and Corral's own updates check the download against it before installing anything.
EOF

if [ "$dry_run" = 1 ]; then
  cat "$notes"
  echo
  echo "Dry run: $image is ready. Nothing was published."
  exit 0
fi

# gh uploads to a draft and publishes it once the files are in, so the tag, which running
# copies of Corral look for, never shows up before its download does.
gh release create "$tag" "$image" "$image.sha256" --repo "$repo" --title "Corral $version" --notes-file "$notes" --target "$(git rev-parse HEAD)"

echo
echo "Published $tag. Share this link; it always points at the newest release:"
echo "  https://github.com/$repo/releases/latest"
