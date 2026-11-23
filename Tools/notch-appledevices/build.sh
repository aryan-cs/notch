#!/bin/sh
# Usage: Tools/notch-appledevices/build.sh
#
# Builds notch-appledevices and the libraries it needs (libimobiledevice and
# what it uses) from source, for Apple Silicon and Intel and macOS 14 or
# later, into Vendor/AppleDevicesTools/, which ships inside NotchHelper.
# Homebrew's copies only run on the macOS version they were built on, so
# they can't be bundled. Needs pkgconf (`brew install pkgconf`).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/Vendor/AppleDevicesTools"
# A fixed path: OpenSSL keeps its build folder's path in the library, and a
# per-user temporary folder's name would identify whoever built it.
work=/private/tmp/notch-appledevices-build
min=14.0
archs="arm64 x86_64"
jobs="$(sysctl -n hw.ncpu)"

# name, URL, SHA-256
sources="
openssl-3.5.9.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
libplist-2.8.1.tar.bz2 https://github.com/libimobiledevice/libplist/releases/download/2.8.1/libplist-2.8.1.tar.bz2 2a1792e5820e1657c173735fde75baeebd6dd967d2ac47be1e3891ddc64ebefa
libimobiledevice-glue-1.3.3.tar.bz2 https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.3/libimobiledevice-glue-1.3.3.tar.bz2 920ce01382a32695f49b23292b4979a03f0afd16c58e8755d8b7f41804acc1a9
libusbmuxd-2.1.1.tar.bz2 https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2 5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce
libimobiledevice-1.4.0.tar.bz2 https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2 23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d
"

command -v pkgconf >/dev/null || { echo "Needs pkgconf: brew install pkgconf" >&2; exit 1; }
export PKG_CONFIG=pkgconf

rm -rf "$work/build" "$work/prefix"
mkdir -p "$work/downloads"
echo "$sources" | while read -r name url sum; do
    [ -n "$name" ] || continue
    file="$work/downloads/$name"
    [ -f "$file" ] || curl -fsSL -o "$file" "$url"
    echo "$sum  $file" | shasum -a 256 -c - >/dev/null
done

# Unpacks a source archive for one architecture and prints where.
unpack() {
    dir="$work/build/$2"
    mkdir -p "$dir"
    tar -xf "$work/downloads/$1" -C "$dir"
    echo "$dir/$(basename "$1" | sed -E 's/\.tar\.(gz|bz2)$//')"
}

for arch in $archs; do
    echo "Building for $arch…"
    prefix="$work/prefix/$arch"
    [ "$arch" = arm64 ] && host=aarch64-apple-darwin || host=x86_64-apple-darwin
    flags="-arch $arch -mmacosx-version-min=$min -ffile-prefix-map=$work=."
    export CFLAGS="-O2 $flags" CXXFLAGS="-O2 $flags" LDFLAGS="$flags"
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""

    # Nothing to load from OPENSSLDIR: libimobiledevice brings its own
    # certificates, so it points at a folder that doesn't exist.
    src="$(unpack openssl-3.5.9.tar.gz "$arch")"
    (cd "$src" && ./Configure "darwin64-$arch-cc" --prefix="$prefix" --libdir=lib \
        --openssldir=/var/empty/ssl shared no-tests no-docs no-apps no-module \
        -mmacosx-version-min=$min "-ffile-prefix-map=$work=." >/dev/null && make -j"$jobs" build_libs >/dev/null && make install_dev >/dev/null)

    for lib in libplist-2.8.1 libimobiledevice-glue-1.3.3 libusbmuxd-2.1.1; do
        src="$(unpack "$lib.tar.bz2" "$arch")"
        (cd "$src" && ./configure --quiet --host="$host" --prefix="$prefix" --disable-static \
            --without-cython >/dev/null && make -j"$jobs" >/dev/null && make install >/dev/null)
    done

    # Only the library: libtatsu is just for one of its command-line tools.
    src="$(unpack libimobiledevice-1.4.0.tar.bz2 "$arch")"
    (cd "$src" && libtatsu_CFLAGS=" " libtatsu_LIBS=" " ./configure --quiet --host="$host" \
        --prefix="$prefix" --disable-static --without-cython >/dev/null \
        && for dir in 3rd_party common src; do make -j"$jobs" -C "$dir" >/dev/null || exit 1; done \
        && make -C src install >/dev/null && make -C include install >/dev/null)

    clang -O2 -Wall $flags -I"$prefix/include" -L"$prefix/lib" \
        -limobiledevice-1.0 -lplist-2.0 \
        -Wl,-rpath,@executable_path/../lib \
        -o "$work/build/$arch/notch-appledevices" "$here/notch-appledevices.c"
done

rm -rf "$out"
mkdir -p "$out/bin" "$out/lib"
first="${archs%% *}"
lipo -create $(for arch in $archs; do echo "$work/build/$arch/notch-appledevices"; done) \
    -output "$out/bin/notch-appledevices"

# Libraries the tool needs, followed transitively, each made universal.
built_deps() {
    otool -arch "$first" -L "$1" | awk 'NR > 1 { print $1 }' | grep "^$work/prefix/$first/" || true
}
copy_deps() {
    for dep in $(built_deps "$1"); do
        name="$(basename "$dep")"
        if [ ! -f "$out/lib/$name" ]; then
            lipo -create $(for arch in $archs; do echo "$work/prefix/$arch/lib/$name"; done) \
                -output "$out/lib/$name"
            copy_deps "$out/lib/$name"
        fi
    done
}
copy_deps "$out/bin/notch-appledevices"

# Point everything at the bundled copies.
for file in "$out/bin/notch-appledevices" "$out/lib/"*.dylib; do
    for dep in $(built_deps "$file"); do
        name="$(basename "$dep")"
        for arch in $archs; do
            install_name_tool -change "$work/prefix/$arch/lib/$name" "@rpath/$name" "$file" 2>/dev/null
        done
    done
done
for lib in "$out/lib/"*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
done

# Rewriting load commands invalidates the linker's signatures; re-sign ad hoc.
# The helper bundle that ships them is signed (and seals them) at build time.
codesign --force --sign - "$out/lib/"*.dylib "$out/bin/notch-appledevices"

# Their licenses go along with them.
for src in "$work/build/$first/"*/; do
    name="$(basename "$src" | sed -E 's/-[0-9][0-9.]*$//')"
    for license in LICENSE.txt COPYING.LESSER COPYING; do
        [ -f "$src$license" ] && cp "$src$license" "$out/COPYING.$name" && break
    done
done
echo "built $(du -sh "$out" | cut -f1) into $out"
