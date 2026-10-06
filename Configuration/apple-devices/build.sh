#!/bin/sh
# Usage: Configuration/apple-devices/build.sh — builds notch-appledevices against Homebrew's libimobiledevice (`brew install libimobiledevice`) and bundles it with its libraries into AppleDevicesTools/, which ships inside the XPC helper.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/AppleDevicesTools"
prefix="$(brew --prefix)"

rm -rf "$out"
mkdir -p "$out/bin" "$out/lib"

clang -O2 -Wall -arch arm64 -mmacosx-version-min=14.0 \
    -I"$prefix/include" -L"$prefix/lib" \
    -limobiledevice-1.0 -lplist-2.0 \
    -Wl,-rpath,@executable_path/../lib \
    -o "$out/bin/notch-appledevices" "$here/notch-appledevices.c"

# Homebrew libraries the tool needs, followed transitively.
homebrew_deps() {
    otool -L "$1" | awk 'NR > 1 { print $1 }' | grep '^/opt/homebrew/' || true
}

copy_deps() {
    for dep in $(homebrew_deps "$1"); do
        name="$(basename "$dep")"
        if [ ! -f "$out/lib/$name" ]; then
            cp -L "$dep" "$out/lib/$name"
            chmod u+w "$out/lib/$name"
            copy_deps "$out/lib/$name"
        fi
    done
}
copy_deps "$out/bin/notch-appledevices"

# Point everything at the bundled copies instead of /opt/homebrew.
for file in "$out/bin/notch-appledevices" "$out/lib/"*.dylib; do
    for dep in $(homebrew_deps "$file"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null
    done
done
for lib in "$out/lib/"*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
done

# Rewriting load commands invalidates Homebrew's signatures; re-sign ad hoc.
# The helper bundle that ships them is signed (and seals them) at build time.
codesign --force --sign - "$out/lib/"*.dylib "$out/bin/notch-appledevices"

cp "$prefix/opt/libimobiledevice/COPYING" "$out/COPYING.libimobiledevice" 2>/dev/null || true
echo "built $(du -sh "$out" | cut -f1) into $out"
