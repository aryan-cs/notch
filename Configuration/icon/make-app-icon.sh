#!/bin/sh
# Usage: Configuration/icon/make-app-icon.sh <source-image> [--no-logo] [--threshold 0.5]  — regenerates AppIcon.appiconset (and the logo2 image) from a squircle icon image.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  sed -n '2p' "$0" | sed 's/^# //'
  exit 1
fi

# Compile once (cached until the .swift file changes). Use Xcode's toolchain via xcrun, not whatever
# `swiftc` happens to be first on PATH.
bin_dir="${TMPDIR:-/tmp}/boringnotch-make-app-icon"
bin="$bin_dir/make-app-icon"
mkdir -p "$bin_dir"
if [ ! -x "$bin" ] || [ "$here/make-app-icon.swift" -nt "$bin" ]; then
  echo "compiling make-app-icon.swift..."
  xcrun swiftc -O "$here/make-app-icon.swift" -o "$bin"
fi

exec "$bin" "$@" \
  --iconset "$root/boringNotch/Assets.xcassets/AppIcon.appiconset" \
  --logo "$root/boringNotch/Assets.xcassets/logo2.imageset"
