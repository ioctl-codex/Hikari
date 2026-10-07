#!/usr/bin/env bash
#
# package-deb.sh — wrap a built libHikari.so in a Termux package (.deb).
#
# Structure, like every Termux package:
#
#   data/data/com.termux/files/usr/bin/hikari-clang          symlink
#   data/data/com.termux/files/usr/lib/hikari/bin/hikari-clang
#   data/data/com.termux/files/usr/lib/hikari/lib/libHikari.so
#   data/data/com.termux/files/usr/lib/hikari/examples/*.c
#   data/data/com.termux/files/usr/share/doc/hikari/...
#
# What this package deliberately does *not* carry, unlike the Debian/Ubuntu one:
# an `opt` and a `libLLVM`.  On Termux they are already installed from the
# distribution, at the version this plugin was built against, and shipping a
# second copy would be the fastest way to get two LLVMs into one process — the
# failure mode that makes the plugin refuse to load at all.  So it depends on
# `llvm` and `libllvm` instead.
#
# Usage:
#   ./tools/termux/package-deb.sh
#   HIKARI_PLUGIN=/path/to/libHikari.so VERSION=1.0.0 ./tools/termux/package-deb.sh
#
# Env:
#   HIKARI_PLUGIN  the aarch64 libHikari.so (default: <repo>/build-termux/obfuscation/libHikari.so)
#   PREFIX         install prefix *inside* the package (default: the Termux one)
#   VERSION        package version (default: 1.0.0)
#   OUT_DIR        where the .deb is written (default: <repo>/dist)
#   DEB_ARCH       package architecture (default: aarch64)

set -euo pipefail

die() { printf 'termux-deb: %s\n' "$*" >&2; exit 1; }
note() { printf 'termux-deb: %s\n' "$*" >&2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

HIKARI_PLUGIN="${HIKARI_PLUGIN:-$HIKARI_ROOT/build-termux/obfuscation/libHikari.so}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="${OUT_DIR:-$HIKARI_ROOT/dist}"
DEB_ARCH="${DEB_ARCH:-aarch64}"

[[ -f "$HIKARI_PLUGIN" ]] || die "no plugin at $HIKARI_PLUGIN (build it first: ./tools/termux/build.sh)"
[[ -f "$SELF_DIR/../android-toolchain/hikari-clang" ]] || die "hikari-clang not found next to this script"

# The plugin has to declare the same libLLVM Termux's opt loads, or it will
# never be callable: LLVM's plugin ABI is per-major-version and there is no
# negotiation.  A NEEDED of libLLVM.so is what `-lLLVM` against Termux's
# libLLVM.so gives, and it is what this checks for.
needed="$(readelf -d "$HIKARI_PLUGIN" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(libLLVM[^]]*\)\].*/\1/p' | head -1)"
if [[ -z "$needed" ]]; then
    die "$HIKARI_PLUGIN declares no libLLVM dependency — was it built against Termux's libLLVM.so?"
fi
note "plugin links against $needed"

NAME=hikari
STAGE="$OUT_DIR/${NAME}_${VERSION}_${DEB_ARCH}"
ROOT="$STAGE/${PREFIX#/}"          # data/data/com.termux/files/usr
rm -rf "$STAGE"
mkdir -p "$ROOT/bin" \
         "$ROOT/lib/hikari/bin" \
         "$ROOT/lib/hikari/lib" \
         "$ROOT/lib/hikari/examples" \
         "$ROOT/share/doc/$NAME" \
         "$STAGE/DEBIAN"

cp "$HIKARI_PLUGIN" "$ROOT/lib/hikari/lib/libHikari.so"
cp "$SELF_DIR/../android-toolchain/hikari-clang" "$ROOT/lib/hikari/bin/hikari-clang"
chmod 755 "$ROOT/lib/hikari/bin/hikari-clang"
cp "$HIKARI_ROOT"/samples/c/*.c "$ROOT/lib/hikari/examples/" 2>/dev/null || true
ln -sf "../lib/hikari/bin/hikari-clang" "$ROOT/bin/hikari-clang"

cp "$SELF_DIR/README.md" "$ROOT/share/doc/$NAME/termux.md"
cp "$HIKARI_ROOT/README.md" "$ROOT/share/doc/$NAME/README.md"
[[ -f "$HIKARI_ROOT/docs/VMP.md" ]] && cp "$HIKARI_ROOT/docs/VMP.md" "$ROOT/share/doc/$NAME/VMP.md"
[[ -f "$HIKARI_ROOT/LICENSE" ]] && cp "$HIKARI_ROOT/LICENSE" "$ROOT/share/doc/$NAME/copyright"

# Termux builds are stripped by the build system; a plugin is stripped by
# dropping its static symbol table, which leaves the dynamic one the loader uses.
strip_bin="$(command -v llvm-strip || command -v strip || true)"
if [[ -n "$strip_bin" ]]; then
    "$strip_bin" --strip-unneeded "$ROOT/lib/hikari/lib/libHikari.so" -o "$ROOT/lib/hikari/lib/libHikari.so.tmp" 2>/dev/null &&
        mv "$ROOT/lib/hikari/lib/libHikari.so.tmp" "$ROOT/lib/hikari/lib/libHikari.so" ||
        rm -f "$ROOT/lib/hikari/lib/libHikari.so.tmp"
fi

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Hikari <noreply@github.com/ioctl-codex/Hikari>
Section: devel
Priority: optional
Homepage: https://github.com/ioctl-codex/Hikari
Depends: clang, llvm, libllvm, libc++
Description: LLVM obfuscation pass plugin for opt (Termux, aarch64)
 Hikari is an out-of-tree LLVM pass plugin: bogus control flow, control-flow
 flattening, instruction substitution, basic-block splitting, string and
 constant encryption, indirect branches, function-call obfuscation,
 anti-debugging, anti-hooking and full IR virtualization.
 .
 This is the Termux build.  Termux ships LLVM 21.1.8, so the plugin is built
 against LLVM 21 with Termux's own headers and links against Termux's own
 libLLVM -- the only way to be sure it can be loaded by \$PREFIX/bin/opt.  That
 is why this package depends on llvm and libllvm instead of carrying them, and
 why it is a per-LLVM-version artifact.
EOF

{
    printf '%s (%s) unstable; urgency=medium\n\n' "$NAME" "$VERSION"
    printf '  * Termux (aarch64) build of the LLVM 21 obfuscation plugin.\n\n'
    printf ' -- Hikari <noreply@github.com/ioctl-codex/Hikari>  %s\n' "$(date -R)"
} > "$ROOT/share/doc/$NAME/changelog.Debian"
gzip -9n "$ROOT/share/doc/$NAME/changelog.Debian"

(
    cd "$STAGE"
    find . -path ./DEBIAN -prune -o -type f ! -name 'changelog.Debian.gz' -print0 |
        sort -z | xargs -0 md5sum | sed 's| \./| |' > DEBIAN/md5sums
)

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    configure)
        if ! command -v opt >/dev/null 2>&1; then
            echo "hikari: 'opt' not on PATH -- install llvm: pkg install llvm" >&2
        fi
        if ! command -v clang >/dev/null 2>&1; then
            echo "hikari: 'clang' not on PATH -- install it: pkg install clang" >&2
        fi
        ;;
esac
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found (pkg install dpkg)"
deb="$OUT_DIR/${NAME}_${VERSION}_${DEB_ARCH}.deb"
rm -f "$deb"
dpkg-deb --build --root-owner-group "$STAGE" "$deb" || die "dpkg-deb --build failed"

printf 'termux-deb: wrote %s\n' "$deb"
du -sh "$STAGE" "$deb" >&2
