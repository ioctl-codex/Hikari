#!/usr/bin/env bash
#
# build.sh — build the Hikari plugin inside Termux, against Termux's own LLVM.
#
# Termux's `libllvm` package carries the headers as well as the shared library
# (`$PREFIX/include/llvm`, `$PREFIX/lib/libLLVM.so`), so the plugin can be built
# where it will run, against the exact libLLVM that will load it.  That matters
# more here than anywhere else: LLVM has no stable plugin ABI, so a plugin built
# against a different build of LLVM 21 is a guess, while this is not.
#
# Note that Termux ships LLVM 21.1.8, not 22 (see tools/termux/README.md), so
# this builds a plugin for LLVM 21.  `opt` comes from Termux's `llvm` package.
#
# Usage:
#   ./tools/termux/build.sh              build into build-termux/
#   ./tools/termux/build.sh --install    ...and install it under $PREFIX
#   ./tools/termux/package-deb.sh        ...or wrap the result in a .deb
#
# Env:
#   PREFIX            Termux prefix (default: /data/data/com.termux/files/usr)
#   HIKARI_BUILD_DIR  build directory (default: <repo>/build-termux)

set -euo pipefail

die() { printf 'termux-build: %s\n' "$*" >&2; exit 1; }
note() { printf 'termux-build: %s\n' "$*" >&2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BUILD_DIR="${HIKARI_BUILD_DIR:-$HIKARI_ROOT/build-termux}"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument '$arg' (expected --install)" ;;
    esac
done

[[ -d "$PREFIX" ]] || die "no prefix at $PREFIX — run this inside Termux, or set PREFIX"

# Everything this needs comes from `pkg install llvm libllvm clang cmake ninja`.
# libllvm is the one with the headers; there is no separate -dev package.
missing=()
for f in "$PREFIX/bin/clang" \
         "$PREFIX/bin/opt" \
         "$PREFIX/lib/libLLVM.so" \
         "$PREFIX/include/llvm/Passes/PassPlugin.h" \
         "$PREFIX/lib/cmake/llvm/LLVMConfig.cmake"; do
    [[ -e "$f" ]] || missing+=("$f")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'termux-build: missing: %s\n' "${missing[*]}" >&2
    die "run: pkg install llvm libllvm clang cmake ninja"
fi
command -v cmake >/dev/null 2>&1 || die "cmake not on PATH (pkg install cmake ninja)"

note "prefix:   $PREFIX"
note "llvm:     $("$PREFIX/bin/llvm-config" --version 2>/dev/null || echo unknown)"
note "plugin for LLVM $("$PREFIX/bin/llvm-config" --version 2>/dev/null | cut -d. -f1)"

# LT_LLVM_INSTALL_DIR is the prefix holding lib/cmake/llvm, which on Termux is
# simply $PREFIX.  The `opt` this plugin will run under is $PREFIX/bin/opt, and
# the driver finds it there without any configuration.
cmake -G Ninja -S "$HIKARI_ROOT" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLT_LLVM_INSTALL_DIR="$PREFIX"
cmake --build "$BUILD_DIR" -j"$(nproc)"

PLUGIN="$BUILD_DIR/obfuscation/libHikari.so"
[[ -f "$PLUGIN" ]] || die "the build produced no plugin at $PLUGIN"
note "built $PLUGIN"

# The driver finds its plugin, its opt and its runtime relative to itself, so a
# tree at $PREFIX/lib/hikari works from any path -- including the $PREFIX/bin
# symlink below, which it follows.
if [[ "$INSTALL" == "1" ]]; then
    DEST="$PREFIX/lib/hikari"
    mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/examples"
    cp "$PLUGIN" "$DEST/lib/libHikari.so"
    cp "$HIKARI_ROOT/tools/android-toolchain/hikari-clang" "$DEST/bin/hikari-clang"
    chmod 755 "$DEST/bin/hikari-clang"
    cp "$HIKARI_ROOT"/samples/c/*.c "$DEST/examples/" 2>/dev/null || true
    ln -sf "../lib/hikari/bin/hikari-clang" "$PREFIX/bin/hikari-clang"
    note "installed under $DEST; hikari-clang is on PATH"

    # A build nobody invokes is a build nobody has tested.
    if printf 'int main(void){return 0;}\n' > "$BUILD_DIR/smoke.c"; then
        if HIKARI_CC="$PREFIX/bin/clang" "$PREFIX/bin/hikari-clang" -O0 -c "$BUILD_DIR/smoke.c" \
                -o "$BUILD_DIR/smoke.o" >/dev/null 2>&1; then
            note "smoke: hikari-clang produced an obfuscated object"
        else
            note "warning: hikari-clang failed to compile a trivial file"
        fi
    fi
fi

note "done"
