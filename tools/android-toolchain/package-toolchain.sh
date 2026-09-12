#!/usr/bin/env bash
#
# package-toolchain.sh — assemble a relocatable Android obfuscating toolchain
# from a built libHikari.so, an LLVM 22 installation and an Android NDK.
#
# Two shapes, one driver:
#
#   --full (default)  self-contained.  Bundles the NDK's clang/lld, clang's
#                     resource directory, libc++ and the Android sysroot, so an
#                     extracted archive compiles *and* obfuscates on a machine
#                     with no NDK and no LLVM installed.
#   --slim            small.  Plugin, LLVM 22 opt and the target wrappers only;
#                     HIKARI_NDK must point at a local NDK at build time.
#
# Result (default dist/hikari-android-toolchain-full):
#
#   bin/hikari-clang                       the 3-stage driver
#   bin/aarch64-linux-android24-clang      drop-in, target-injecting wrappers
#   bin/aarch64-linux-android24-clang++    (same names the NDK uses)
#   lib/libHikari.so                       the plugin
#   llvm/bin/opt                           LLVM 22 opt that loads the plugin
#   llvm/lib/libLLVM.so.22*                its runtime
#   ndk/toolchains/llvm/prebuilt/*/        (--full) clang, lld, sysroot
#   README.md, BUILD-INFO.txt, examples/
#
# Usage:
#   HIKARI_NDK=/path/to/ndk LLVM_PREFIX=/usr/lib/llvm-22 \
#   HIKARI_PLUGIN=build/obfuscation/libHikari.so ./package-toolchain.sh [--full|--slim]
#
# Env:
#   HIKARI_NDK      Android NDK (required — its target wrappers are enumerated,
#                   and --full copies its clang + sysroot)
#   LLVM_PREFIX     LLVM 22 install prefix containing bin/opt (required)
#   HIKARI_PLUGIN   libHikari.so (required)
#   OUT_DIR         output root (default: <repo>/dist)
#   STRIP           strip(1) used to shrink opt/libLLVM (default: llvm-strip,
#                   then strip; set to "none" to keep the symbols)
#   NDK_ABIS        sysroot ABIs to bundle in --full (default: the four Android
#                   ABIs; riscv64 is left out to keep the archive small)

set -euo pipefail

die() { printf 'package-toolchain: %s\n' "$*" >&2; exit 1; }
note() { printf 'package-toolchain: %s\n' "$*" >&2; }

MODE=full
for arg in "$@"; do
    case "$arg" in
        --full) MODE=full ;;
        --slim) MODE=slim ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument '$arg' (expected --full or --slim)" ;;
    esac
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

HIKARI_NDK="${HIKARI_NDK:-}" || true
LLVM_PREFIX="${LLVM_PREFIX:-}" || true
HIKARI_PLUGIN="${HIKARI_PLUGIN:-}" || true
OUT_DIR="${OUT_DIR:-$HIKARI_ROOT/dist}"
NDK_ABIS="${NDK_ABIS:-aarch64-linux-android arm-linux-androideabi i686-linux-android x86_64-linux-android}"

[[ -n "$HIKARI_NDK" && -d "$HIKARI_NDK" ]] || die "set HIKARI_NDK to an Android NDK directory"
[[ -n "$LLVM_PREFIX" && -d "$LLVM_PREFIX" ]] || die "set LLVM_PREFIX to an LLVM 22 prefix (e.g. /usr/lib/llvm-22)"
[[ -n "$HIKARI_PLUGIN" && -f "$HIKARI_PLUGIN" ]] || die "set HIKARI_PLUGIN to the built libHikari.so"
[[ -x "$LLVM_PREFIX/bin/opt" ]] || die "$LLVM_PREFIX/bin/opt not found"

NAME="hikari-android-toolchain-$MODE"
STAGE="$OUT_DIR/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/llvm/bin" "$STAGE/llvm/lib" "$STAGE/examples"

# --------------------------------------------------------------- binaries ---
cp "$HIKARI_PLUGIN" "$STAGE/lib/"
cp "$SELF_DIR/hikari-clang" "$STAGE/bin/hikari-clang"
chmod +x "$STAGE/bin/hikari-clang"

cp "$LLVM_PREFIX/bin/opt" "$STAGE/llvm/bin/opt"
chmod +x "$STAGE/llvm/bin/opt"

# opt's runtime (libLLVM + friends) so the archive works on clean machines.
copied_libs=0
while read -r lib; do
    [[ -f "$lib" ]] || continue
    cp -L "$lib" "$STAGE/llvm/lib/" && copied_libs=$((copied_libs + 1))
done < <(ldd "$LLVM_PREFIX/bin/opt" 2>/dev/null | awk '/=>/ {print $3}' | grep -E 'libLLVM|libz|libzstd|libtinfo' || true)
[[ "$copied_libs" -gt 0 ]] || note "warning: no LLVM runtime libs copied (opt may need system LLVM 22)"

# Also keep the versioned soname the plugin links against, if we saw it.
for so in "$LLVM_PREFIX"/lib/libLLVM.so* /usr/lib/*/libLLVM.so*; do
    [[ -f "$so" ]] || continue
    base="$(basename "$so")"
    [[ -e "$STAGE/llvm/lib/$base" ]] || cp -L "$so" "$STAGE/llvm/lib/$base"
done 2>/dev/null || true

# opt and libLLVM ship with full symbol tables; the archive only needs the
# dynamic ones.  Strip through a temporary so a failed strip cannot leave a
# truncated library behind.
strip_llvm() {
    local strip_bin="${STRIP:-}"
    if [[ "$strip_bin" == "none" ]]; then
        note "STRIP=none — keeping opt/libLLVM symbols"
        return 0
    fi
    if [[ -z "$strip_bin" ]]; then
        strip_bin="$(command -v llvm-strip || command -v strip || true)"
    fi
    [[ -n "$strip_bin" ]] || { note "warning: no strip found, archive stays large"; return 0; }

    local f
    for f in "$STAGE/llvm/bin/opt" "$STAGE"/llvm/lib/libLLVM.so*; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        if "$strip_bin" --strip-unneeded "$f" -o "$f.tmp" 2>/dev/null && [[ -s "$f.tmp" ]] &&
           chmod --reference="$f" "$f.tmp" 2>/dev/null; then
            mv "$f.tmp" "$f"
        else
            rm -f "$f.tmp"
            note "warning: could not strip $(basename "$f")"
        fi
    done
}
strip_llvm

# ------------------------------------------------- per-target NDK wrappers ---
ndk_bin=""
ndk_prebuilt=""
for d in "$HIKARI_NDK"/toolchains/llvm/prebuilt/*/bin; do
    [[ -x "$d/clang" ]] && { ndk_bin="$d"; ndk_prebuilt="$(dirname "$d")"; break; }
done
[[ -n "$ndk_bin" ]] || die "no toolchains/llvm/prebuilt/*/bin/clang under $HIKARI_NDK"

targets=0
for tc in "$ndk_bin"/*-linux-android*-clang; do
    [[ -e "$tc" ]] || continue
    base="$(basename "$tc")"                  # e.g. aarch64-linux-android24-clang
    targ="${base%-clang}"                     # aarch64-linux-android24
    for suffix in "" "++"; do
        gen="$STAGE/bin/${base}${suffix}"
        cat > "$gen" <<EOF
#!/usr/bin/env bash
# Generated by Hikari package-toolchain.sh — NDK target wrapper with obfuscation.
exec "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/hikari-clang" --target=$targ "\$@"
EOF
        chmod +x "$gen"
        targets=$((targets + 1))
    done
done
[[ "$targets" -gt 0 ]] || die "no *-linux-android*-clang wrappers found in $ndk_bin"

# ------------------------------------------------------------ bundled NDK ---
# clang-21, lld and the resource directory are statically linked LLVM builds
# (confirmed via readelf: no libclang-cpp/libLLVM dependency), so the bundle is
# clang + lld + headers + sysroot — not the whole 2 GB prebuilt tree.
bundle_ndk() {
    local host dest cver t d f
    host="$(basename "$ndk_prebuilt")"
    dest="$STAGE/ndk/toolchains/llvm/prebuilt/$host"
    mkdir -p "$dest/bin" "$dest/lib" "$dest/sysroot/usr"

    for b in clang clang++ clang-[0-9]* lld ld.lld llvm-ar llvm-ranlib llvm-nm \
             llvm-objcopy llvm-strip llvm-readelf llvm-objdump llvm-size llvm-cxxfilt; do
        for f in "$ndk_bin"/$b; do
            [[ -e "$f" || -L "$f" ]] || continue
            cp -a "$f" "$dest/bin/"
        done
    done
    [[ -x "$dest/bin/clang" ]] || die "no clang copied from $ndk_bin"

    # clang's resource directory: builtin headers + the runtime libraries it
    # links into Android binaries.
    cver=""
    for d in "$ndk_prebuilt"/lib/clang/*/; do
        [[ -d "$d" ]] && { cver="$(basename "$d")"; break; }
    done
    [[ -n "$cver" ]] || die "no lib/clang/<version> under $ndk_prebuilt"
    mkdir -p "$dest/lib/clang/$cver/lib/linux"
    cp -a "$ndk_prebuilt/lib/clang/$cver/include" "$dest/lib/clang/$cver/"
    # riscv64 runtime libraries are ~80 MB and Android does not ship that ABI;
    # everything else at this level (builtins, sanitizers per arch) is kept.
    find "$ndk_prebuilt/lib/clang/$cver/lib/linux" -maxdepth 1 -type f \
        ! -name '*riscv64*' \
        -exec cp -a {} "$dest/lib/clang/$cver/lib/linux/" \;
    local arch
    for arch in aarch64 arm i386 x86_64; do
        [[ -d "$ndk_prebuilt/lib/clang/$cver/lib/linux/$arch" ]] &&
            cp -a "$ndk_prebuilt/lib/clang/$cver/lib/linux/$arch" "$dest/lib/clang/$cver/lib/linux/"
    done

    # libc++/libunwind for the host triple the driver defaults to (a few MB;
    # simpleperf's 33 MB readelf archive is deliberately left out).
    for d in "$ndk_prebuilt"/lib/*-unknown-linux-gnu; do
        [[ -d "$d" ]] || continue
        mkdir -p "$dest/lib/$(basename "$d")"
        for f in "$d"/libc++* "$d"/libunwind* "$d"/libc++abi*; do
            [[ -e "$f" ]] && cp -a "$f" "$dest/lib/$(basename "$d")/"
        done
    done

    # Sysroot: headers plus the link stubs for the ABIs we ship.
    cp -a "$ndk_prebuilt/sysroot/usr/include" "$dest/sysroot/usr/"
    mkdir -p "$dest/sysroot/usr/lib"
    local abi found=0
    for abi in $NDK_ABIS; do
        [[ -d "$ndk_prebuilt/sysroot/usr/lib/$abi" ]] || continue
        cp -a "$ndk_prebuilt/sysroot/usr/lib/$abi" "$dest/sysroot/usr/lib/"
        found=$((found + 1))
    done
    [[ "$found" -gt 0 ]] || die "no sysroot ABI directories copied (NDK_ABIS='$NDK_ABIS')"
    note "bundled NDK prebuilt: $host, clang resource dir $cver, $found sysroot ABIs"
}

if [[ "$MODE" == "full" ]]; then
    bundle_ndk
fi

# ---------------------------------------------------------------- extras ----
cp "$SELF_DIR/README.md" "$STAGE/README.md"
for s in "$HIKARI_ROOT"/samples/c/*.c; do
    [[ -f "$s" ]] && cp "$s" "$STAGE/examples/"
done
{
    echo "shape: $MODE"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "llvm-prefix: $LLVM_PREFIX"
    echo "llvm-version: $("$LLVM_PREFIX/bin/opt" --version 2>/dev/null | head -2 | tail -1)"
    echo "ndk: $HIKARI_NDK"
    [[ "$MODE" == "full" ]] && echo "bundled-sysroot-abis: $NDK_ABIS"
    echo "plugin: $(basename "$HIKARI_PLUGIN")"
} > "$STAGE/BUILD-INFO.txt"

# ------------------------------------------------------------------ tar -----
# xz over the bundled sysroot/clang, gzip as the fallback where xz is absent.
# The full shape is ~1 GB of mostly small files, and single-threaded xz needs
# ten minutes on it, so hand the compressor every core unless the caller says
# otherwise (XZ_OPT=-T1 -0 to trade size for a faster run).
archive="$OUT_DIR/$NAME.tar.gz"
tar_opt=(-czf)
if command -v xz >/dev/null 2>&1; then
    archive="$OUT_DIR/$NAME.tar.xz"
    tar_opt=(-cJf)
    export XZ_OPT="${XZ_OPT:--T0 -6}"
fi
rm -f "$OUT_DIR/$NAME.tar.gz" "$OUT_DIR/$NAME.tar.xz"
tar "${tar_opt[@]}" "$archive" -C "$OUT_DIR" "$NAME"
note "$MODE: wrote $archive"
du -sh "$STAGE" "$archive"
