#!/bin/sh
# Builds a release of Notch and packs it into build/release/Notch.dmg.
#
# Usage: Scripts/release.sh [extra xcodebuild arguments]
#
# The app is built for both Apple silicon and Intel and signed ad hoc, the
# same way every published release is. It does not publish anything; see
# "Making a release" in CONTRIBUTING.md for the rest.
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/build/release"
# Outside the checkout, so the path remapping below doesn't touch it.
derived="${TMPDIR:-/tmp}/notch-release"
app="$derived/Build/Products/Release/Notch.app"

rm -rf "$out" "$derived"
mkdir -p "$out"

# - ONLY_ACTIVE_ARCH=NO builds every architecture, not just this Mac's: Apple
#   silicon and Intel for the app, plus arm64e for the sudo module, which
#   sudo itself is built as.
# - Ad hoc signing ("-") keeps your Apple ID email out of the signature,
#   which an Apple Development certificate would embed.
# - CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps the debugging entitlement
#   (get-task-allow) out of the release.
# - Code coverage stays off; its counters would embed every source path.
# - The prefix maps replace this checkout's path, and any other path in your
#   home folder (such as a shared package cache), in the compiled binaries.
echo "Building Notch…"
xcodebuild \
    -project "$repo/Notch.xcodeproj" \
    -scheme Notch \
    -configuration Release \
    -derivedDataPath "$derived" \
    -quiet \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_CODE_COVERAGE=NO \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $repo=. -debug-prefix-map $repo=. -file-prefix-map $HOME=~ -debug-prefix-map $HOME=~" \
    "$@" \
    build

echo "Checking the build…"
fail() {
    echo "error: $*" >&2
    exit 1
}
archs="$(lipo -archs "$app/Contents/MacOS/Notch")"
case "$archs" in
    *arm64*x86_64* | *x86_64*arm64*) ;;
    *) fail "expected a universal binary, got: $archs" ;;
esac
module_archs="$(lipo -archs "$app/Contents/Library/PAM/pam_notch.so")"
case "$module_archs" in
    *arm64e*) ;;
    *) fail "the sudo module needs an arm64e slice, got: $module_archs" ;;
esac
codesign --verify --deep --strict "$app" || fail "the signature doesn't verify"
if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q get-task-allow; then
    fail "the app carries the get-task-allow entitlement"
fi
if grep -rlaF "$HOME" "$app" >/dev/null; then
    fail "the app contains your home folder path: $(grep -rlaF "$HOME" "$app" | head -1)"
fi

echo "Making the disk image…"
stage="$out/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/Notch.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Notch -srcfolder "$stage" -ov -format UDZO "$out/Notch.dmg" >/dev/null
rm -rf "$stage"

version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"
build="$(defaults read "$app/Contents/Info.plist" CFBundleVersion)"
echo
echo "Notch $version (build $build)"
echo "$out/Notch.dmg"
shasum -a 256 "$out/Notch.dmg"
