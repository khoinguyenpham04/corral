#!/bin/bash
# Builds Corral with swiftc directly: Command Line Tools are enough (no Xcode), and it works in
# shells where SwiftPM can't use its own sandbox or caches. `swift build` works too.
#
#   scripts/build.sh                  debug build of every target into build/debug
#   scripts/build.sh --release        optimized build into build/release
#   scripts/build.sh --app            also assemble Corral.app next to the binaries
#   scripts/build.sh --test           build and run the tests
#   scripts/build.sh --previews       render the panel to PNGs in build/previews
#   scripts/build.sh --universal      arm64 + x86_64 binaries
#   scripts/build.sh --core           only CorralCore, the CLI and tests (no UI)
#   scripts/build.sh --release --universal --package   Corral-<version>.dmg and .zip
#   CORRAL_SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh --release --app
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config=debug app=0 run_tests=0 previews=0 universal=0 core_only=0 package=0
for arg in "$@"; do
  case "$arg" in
    --release) config=release ;;
    --app) app=1 ;;
    --test) run_tests=1 ;;
    --previews) previews=1 ;;
    --universal) universal=1 ;;
    --core) core_only=1 ;;
    --package) package=1 app=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

if [ "$run_tests" = 1 ] && [ "$config" = release ]; then
  echo "build.sh: tests need a debug build (drop --release)" >&2
  exit 2
fi

out="$root/build/$config"
mkdir -p "$out"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$root/build/ModuleCache}"
sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -d "$sdk" ] || sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
developer="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
if [[ "$developer" == *CommandLineTools* ]]; then
  test_frameworks="$developer/Library/Developer/Frameworks"
  test_plugins="$developer/usr/lib/swift/host/plugins/testing"
else
  test_frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
  test_plugins="$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
fi

if [ "$config" = release ]; then
  optimize=(-O -whole-module-optimization)
else
  optimize=(-Onone -g -enable-testing)
fi
archs=(arm64)
[ "$universal" = 1 ] && archs=(arm64 x86_64)

sources() { find "$root/$1" -name '*.swift' | sort; }

# swiftc wrapper: quiet about the xcrun cache warning sandboxes cause, loud about everything else.
compile() {
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/corral-build.XXXXXX")"
  if ! xcrun swiftc "$@" >"$log" 2>&1; then
    grep -v "couldn't create cache file" "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  grep -v "couldn't create cache file" "$log" | grep -E 'warning:' >&2 || true
  rm -f "$log"
}

build_arch() {
  local arch="$1" dir="$out/$1"
  local mods="$dir/modules"
  mkdir -p "$mods"
  local flags=(-swift-version 6 -target "$arch-apple-macosx14.0" -sdk "$sdk" -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${optimize[@]}")

  library() {
    local name="$1"; shift
    compile "${flags[@]}" -parse-as-library -emit-library -static -emit-module -module-name "$name" \
      -emit-module-path "$mods/$name.swiftmodule" -I "$mods" "$@" $(sources "Sources/$name") -o "$dir/lib$name.a"
  }
  executable() {
    local name="$1" product="$2"; shift 2
    compile "${flags[@]}" -module-name "$name" -I "$mods" -L "$dir" "$@" $(sources "Sources/$name") -o "$dir/$product"
  }

  echo "• $arch: CorralCore"; library CorralCore
  echo "• $arch: corral";   executable CorralCLI corral-cli -lCorralCore -lsqlite3
  if [ "$core_only" = 0 ]; then
    echo "• $arch: CorralUI"; library CorralUI
    echo "• $arch: Corral";   executable Corral Corral -lCorralUI -lCorralCore -lsqlite3 -framework Carbon
  fi
  if [ "$previews" = 1 ] && [ "$core_only" = 0 ]; then
    echo "• $arch: previews"; executable CorralPreview corral-preview -lCorralUI -lCorralCore -lsqlite3
  fi
  if [ "$run_tests" = 1 ] && [ "$arch" = arm64 ]; then
    echo "• tests"
    compile "${flags[@]}" -parse-as-library -module-name CorralCoreTests -I "$mods" -L "$dir" -lCorralCore -lsqlite3 \
      -F "$test_frameworks" -framework Testing -plugin-path "$test_plugins" \
      -Xlinker -rpath -Xlinker "$test_frameworks" -Xlinker -rpath -Xlinker "$test_frameworks/../usr/lib" \
      $(sources Tests/CorralCoreTests) "$root/scripts/TestMain.swift" -o "$dir/corral-tests"
  fi
}

for arch in "${archs[@]}"; do build_arch "$arch"; done

products=(corral-cli)
[ "$core_only" = 0 ] && products+=(Corral)
[ "$previews" = 1 ] && [ "$core_only" = 0 ] && products+=(corral-preview)
for product in "${products[@]}"; do
  if [ "${#archs[@]}" -gt 1 ]; then
    lipo -create $(for arch in "${archs[@]}"; do echo "$out/$arch/$product"; done) -output "$out/$product"
  else
    cp "$out/${archs[0]}/$product" "$out/$product"
  fi
done

if [ "$run_tests" = 1 ]; then
  "$out/arm64/corral-tests"
fi

if [ "$previews" = 1 ]; then
  mkdir -p "$root/build/previews"
  "$out/corral-preview" "$root/build/previews"
fi

if [ "$app" = 1 ]; then
  version="$(cat "$root/VERSION" 2>/dev/null || echo 0.1.0)"
  build_number="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
  icon="$root/build/AppIcon.icns"
  if [ ! -f "$icon" ] || [ "$root/scripts/make-icon.swift" -nt "$icon" ]; then
    echo "• icon"
    compile -swift-version 6 -sdk "$sdk" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -O \
      "$root/scripts/make-icon.swift" -o "$root/build/make-icon"
    mkdir -p "$root/build/previews"
    "$root/build/make-icon" "$icon" "$root/build/previews/app-icon.png"
  fi

  bundle="$out/Corral.app"
  echo "• Corral.app $version ($build_number)"
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
  cp "$out/Corral" "$bundle/Contents/MacOS/Corral"
  cp "$out/corral-cli" "$bundle/Contents/Helpers/corral"
  cp "$icon" "$bundle/Contents/Resources/AppIcon.icns"
  cp "$root/scripts/install.sh" "$bundle/Contents/Resources/install.sh"
  sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" "$root/Resources/Info.plist" > "$bundle/Contents/Info.plist"

  identity="${CORRAL_SIGN_IDENTITY:--}"
  sign=(codesign --force --sign "$identity")
  [ "$identity" != "-" ] && sign+=(--options runtime --timestamp)
  "${sign[@]}" "$bundle/Contents/Helpers/corral" >/dev/null
  "${sign[@]}" --entitlements "$root/Resources/Corral.entitlements" "$bundle" >/dev/null
  echo "  $bundle"
fi

if [ "$package" = 1 ]; then
  archive="$out/Corral-$version.zip"
  rm -f "$archive"
  # ditto keeps the code signature and extended attributes intact.
  ditto -c -k --keepParent "$out/Corral.app" "$archive"
  echo "• $archive"
  echo "  sha256 $(shasum -a 256 "$archive" | cut -d' ' -f1)"

  # The download people get: a window with Corral, an arrow and Applications. dmgbuild writes
  # the window's layout itself, without scripting Finder; it lives in a venv under build/.
  image="$out/Corral-$version.dmg"
  rm -f "$image"
  venv="$root/build/dmgenv"
  if [ ! -x "$venv/bin/dmgbuild" ]; then
    echo "• dmgbuild (once)"
    python3 -m venv "$venv" && "$venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild>=1.6" || rm -rf "$venv"
  fi
  # The build mounts the image at /Volumes/Corral to lay out its window. With another Corral
  # image already mounted there, it gets /Volumes/Corral 1 instead. So eject ours first.
  for volume in /Volumes/Corral /Volumes/Corral\ *; do
    if [ -d "$volume/Corral.app" ]; then hdiutil detach -quiet "$volume" || true; fi
  done
  if [ -e /Volumes/Corral ]; then
    echo "build.sh: eject the disk named Corral, then build again" >&2
    exit 1
  fi
  if [ -x "$venv/bin/dmgbuild" ]; then
    "$venv/bin/python3" -I "$root/packaging/dmg/build.py" "$root/packaging/dmg/settings.py" "Corral" "$image" \
      app="$out/Corral.app" icon="$icon" background="$root/packaging/dmg/background.png" >/dev/null
  else
    # No dmgbuild (offline?): the same contents in a plain Finder window.
    echo "build.sh: couldn't install dmgbuild, so the disk image gets Finder's default window" >&2
    staging="$out/dmg"
    rm -rf "$staging" && mkdir -p "$staging"
    ditto "$out/Corral.app" "$staging/Corral.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "Corral" -srcfolder "$staging" -fs HFS+ -format UDZO -ov -quiet "$image"
    rm -rf "$staging"
  fi
  echo "• $image"
  echo "  sha256 $(shasum -a 256 "$image" | cut -d' ' -f1)"
fi
