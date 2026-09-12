#!/usr/bin/env bash
#
# verify-package.sh — prove a packaged toolchain really works on a bare machine.
#
# The smoke test checks the *plugin*; this checks the *package*.  It extracts the
# archive under a different name (so an absolute path baked in at packaging time
# would show up), then runs the wrappers with a scrubbed environment — no NDK
# variables, no repo, plain PATH — and compiles samples for the Android ABIs.
#
# For each ABI it requires:
#   * a compile through bin/<abi>-clang that produces that ABI's ELF object,
#   * Hikari's VMP handlers (vmp_ch_*) in the obfuscated object,
#   * a passthrough (HIKARI_OBF=0) object without them, so a package that
#     silently ignored the plugin cannot pass as working.
#
# The clang that gets used is asserted to live inside the package when the
# archive ships one (--full), which is what "self-contained" has to mean.
#
# Usage:
#   ./verify-package.sh dist/hikari-android-toolchain-full.tar.xz
#   HIKARI_NDK=/path/to/ndk ./verify-package.sh dist/hikari-android-toolchain-slim.tar.xz
#
# A --full archive is verified with no HIKARI_NDK on purpose; if one happens to
# be exported it is removed for the duration of the run.

set -uo pipefail

die() { printf 'verify-package: %s\n' "$*" >&2; exit 2; }

[[ $# -ge 1 ]] || die "usage: verify-package.sh <archive|directory>"
PKG="$1"
[[ -e "$PKG" ]] || die "no such file or directory: $PKG"
PKG="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hikari-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------- unpacking -----
if [[ -d "$PKG" ]]; then
    ROOT="$PKG"
    ARCHIVE=""
else
    case "$PKG" in
        *.tar.xz) tar -xJf "$PKG" -C "$WORK" || die "could not extract $PKG" ;;
        *.tar.gz|*.tgz) tar -xzf "$PKG" -C "$WORK" || die "could not extract $PKG" ;;
        *) die "unsupported archive type: $PKG" ;;
    esac
    ROOT=""
    for d in "$WORK"/*/; do
        [[ -f "$d/bin/hikari-clang" ]] && { ROOT="${d%/}"; break; }
    done
    [[ -n "$ROOT" ]] || die "archive has no bin/hikari-clang"
    ARCHIVE="$PKG"
fi

# Relocate: a toolkit that only works from its build path is not relocatable.
# A directory argument is hard-linked rather than moved, so verifying an
# unpacked tree never consumes it.
RELOCATED="$WORK/moved-toolchain"
if [[ -n "$ARCHIVE" ]]; then
    mv "$ROOT" "$RELOCATED" || die "could not relocate the package"
else
    cp -al "$ROOT" "$RELOCATED" 2>/dev/null || cp -a "$ROOT" "$RELOCATED" ||
        die "could not copy the package for relocation"
fi
ROOT="$RELOCATED"

[[ -f "$ROOT/BUILD-INFO.txt" ]] && sed 's/^/  /' "$ROOT/BUILD-INFO.txt"

SHAPE="slim"
grep -q '^shape: full' "$ROOT/BUILD-INFO.txt" 2>/dev/null && SHAPE="full"
SELF_CONTAINED=0
[[ -d "$ROOT/ndk" ]] && SELF_CONTAINED=1

echo
echo "== package: $([[ -n "$ARCHIVE" ]] && basename "$ARCHIVE" || echo "$ROOT") (shape=$SHAPE) =="
echo "  extracted to: $ROOT"
du -sh "$ROOT" 2>/dev/null | awk '{print "  size: " $1}'

if [[ "$SHAPE" == "full" ]] && [[ "$SELF_CONTAINED" != "1" ]]; then
    bad "shape is 'full' but no ndk/ directory was bundled"
fi
[[ "$SHAPE" == "full" && "$SELF_CONTAINED" == "1" ]] &&
    ok "bundles its own NDK (ndk/toolchains/llvm/prebuilt/*)"

# ------------------------------------------------------------------ tools ----
# Everything below runs without HIKARI_NDK and with a minimal PATH: that is the
# claim being tested.  (For a slim package the caller's HIKARI_NDK is kept.)
SCRUBBED_ENV=(
    env -i
    HOME="$HOME"
    PATH="/usr/bin:/bin"
    TMPDIR="$WORK"
    LANG=C
)
[[ "$SHAPE" == "slim" && -n "${HIKARI_NDK:-}" ]] &&
    SCRUBBED_ENV+=(HIKARI_NDK="$HIKARI_NDK")

run_pkg() { ( cd "$WORK" && "${SCRUBBED_ENV[@]}" "$@" ); }

echo
echo "== 1. the package runs with no NDK/LLVM environment =="
if run_pkg "$ROOT/bin/hikari-clang" --version >"$WORK/ver.txt" 2>&1; then
    ok "hikari-clang --version works in a scrubbed environment"
else
    bad "hikari-clang --version failed: $(head -2 "$WORK/ver.txt" | tr '\n' ' ')"
fi

# Which clang did it pick, and is it the packaged one?
if run_pkg env HIKARI_VERBOSE=1 "$ROOT/bin/hikari-clang" -c "$ROOT/examples/hello.c" \
        -o "$WORK/probe.o" >"$WORK/probe.log" 2>&1; then
    used="$(awk '/^hikari-clang: clang:/ {print $3}' "$WORK/probe.log" | tail -1)"
    echo "  clang: $used"
    case "$used" in
        "$ROOT"/*)
            ok "used the clang inside the package" ;;
        "")
            bad "hikari-clang did not report which clang it used" ;;
        *)
            if [[ "$SHAPE" == "full" ]]; then
                bad "used '$used' instead of the bundled clang"
            else
                ok "slim package used the supplied NDK clang"
            fi ;;
    esac
else
    bad "could not compile examples/hello.c: $(tail -3 "$WORK/probe.log" | tr '\n' ' ')"
fi

# --------------------------------------------------------------- per ABI -----
# Lowest API level installed for each ABI, mirroring how the NDK names its
# wrappers.  armv7a's triple differs from its sysroot directory name.
declare -A ABI_WRAPPER=(
    [aarch64]="aarch64-linux-android"
    [armv7a]="armv7a-linux-androideabi"
    [x86_64]="x86_64-linux-android"
    [i686]="i686-linux-android"
)
declare -A ABI_MACHINE=(
    [aarch64]="AArch64"
    [armv7a]="ARM"
    [x86_64]="X86-64"
    [i686]="Intel 80386"
)

pick_wrapper() { # <triple-prefix> -> path
    local want="$1" cand best="" bestapi=""
    for cand in "$ROOT"/bin/"$want"[0-9]*-clang; do
        [[ -x "$cand" ]] || continue
        local api="${cand##*"$want"}"; api="${api%%-clang}"
        [[ "$api" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$bestapi" || "$api" -lt "$bestapi" ]]; then
            best="$cand"; bestapi="$api"
        fi
    done
    [[ -n "$best" ]] && printf '%s' "$best"
}

readelf="$(command -v llvm-readelf || command -v readelf || true)"
nm="$(command -v llvm-nm || command -v nm || true)"
for cand in "$ROOT"/ndk/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
    [[ -x "$cand" ]] && { readelf="$cand"; break; }
done
for cand in "$ROOT"/ndk/toolchains/llvm/prebuilt/*/bin/llvm-nm; do
    [[ -x "$cand" ]] && { nm="$cand"; break; }
done

echo
echo "== 2. compile + obfuscate for every Android ABI =="
for abi in aarch64 armv7a x86_64 i686; do
    wrapper="$(pick_wrapper "${ABI_WRAPPER[$abi]}")"
    if [[ -z "$wrapper" ]]; then
        echo "  - $abi: no wrapper in this package, skipped"
        continue
    fi
    obj="$WORK/$abi.o"
    log="$WORK/$abi.log"
    if ! run_pkg env HIKARI_PASSES='hikari(enable-vmp,enable-cffobf)' \
            "$wrapper" -c "$ROOT/examples/neg_idx.c" -o "$obj" >"$log" 2>&1; then
        bad "$abi: obfuscated compile failed ($(tail -2 "$log" | tr '\n' ' '))"
        continue
    fi
    machine="$("$readelf" -h "$obj" 2>/dev/null | awk '/Machine:/ {$1=""; sub(/^ +/, ""); print}')"
    if [[ "$machine" != *"${ABI_MACHINE[$abi]}"* ]]; then
        bad "$abi: expected ${ABI_MACHINE[$abi]} object, got '$machine'"
        continue
    fi

    vmp="$("$nm" "$obj" 2>/dev/null | grep -c 'vmp_ch_')"
    plain="$WORK/$abi.plain.o"
    run_pkg env HIKARI_OBF=0 "$wrapper" -c "$ROOT/examples/neg_idx.c" -o "$plain" \
        >"$WORK/$abi.plain.log" 2>&1 || true
    plain_vmp="$("$nm" "$plain" 2>/dev/null | grep -c 'vmp_ch_')"

    if [[ "$vmp" -gt 0 ]]; then
        ok "$abi: ${ABI_MACHINE[$abi]} object, $vmp vmp_ch_* handlers"
    else
        bad "$abi: no vmp_ch_* handlers — the plugin did not run"
    fi
    if [[ -s "$plain" && "$plain_vmp" -eq 0 ]]; then
        ok "$abi: HIKARI_OBF=0 passthrough stays unobfuscated ($(stat -c %s "$plain") vs $(stat -c %s "$obj") bytes)"
    else
        bad "$abi: passthrough control produced vmp handlers (or no object)"
    fi

    # Cross-ABI: a package that ignored --target would emit host objects and this
    # would already have failed above; the size check catches truncated output.
    [[ "$(stat -c %s "$obj")" -gt 1024 ]] || bad "$abi: obfuscated object looks truncated"
done

echo
echo "== result: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
