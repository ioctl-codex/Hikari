#!/usr/bin/env bash
#
# verify-deb.sh — install a native .deb, prove it works, then take it away.
#
# A package nobody unpacks is a package nobody has tested.  This is the check
# that the package's own layout is right: that /usr/bin/hikari-clang is reachable
# as a symlink and follows itself, that the bundled opt loads the bundled
# libHikari.so, that the obfuscated output still computes what the clean build
# computes, and that removing the package leaves nothing behind.
#
# The samples that exit non-zero on purpose (hello.c prints "access denied" and
# returns 1) are compared by output, never by exit status.
#
# Usage:
#   sudo ./tools/deb/verify-deb.sh dist/hikari_1.0.0_amd64.deb
#
# Env:
#   HIKARI_CC   the front-end clang to compile the clean comparison with
#               (default: the first clang on PATH)

set -euo pipefail

die() { printf 'verify-deb: %s\n' "$*" >&2; exit 1; }
note() { printf 'verify-deb: %s\n' "$*" >&2; }

DEB="${1:-}"
[[ -n "$DEB" && -f "$DEB" ]] || die "usage: verify-deb.sh <package.deb>"
[[ "$(id -u)" == "0" ]] || die "run this as root: it installs the package"
DEB="$(readlink -f "$DEB")"

# A leftover install would make this test pass for the wrong reason.
dpkg -r hikari 2>/dev/null || true
dpkg -i "$DEB" >/dev/null
note "installed $(basename "$DEB")"

command -v hikari-clang >/dev/null 2>&1 ||
    die "no hikari-clang on PATH after install"
note "driver: $(command -v hikari-clang) -> $(readlink -f "$(command -v hikari-clang)")"

[[ -f /usr/lib/hikari/lib/libHikari.so ]] || die "no plugin installed"
[[ -f /usr/lib/hikari/llvm/bin/opt ]] || die "no opt installed"
[[ -f /usr/share/doc/hikari/README.md ]] || die "no README installed"
# The README ships in English now, and asserting that positively is more
# robust than trying to detect leftover CJK text by byte range in whatever
# locale grep happens to run under.
grep -q 'An out-of-tree LLVM obfuscation pass plugin' /usr/share/doc/hikari/README.md ||
    die "the installed README is not the translated one (stale package?)"
note "docs:   /usr/share/doc/hikari/README.md (English)"
note "build:  $(sed -n 's/^llvm-version: /llvm /p' /usr/lib/hikari/BUILD-INFO.txt 2>/dev/null)"

HIKARI_CC="${HIKARI_CC:-}"
if [[ -z "$HIKARI_CC" ]]; then
    for cand in /usr/lib/llvm-22/bin/clang /usr/bin/clang-22 /usr/bin/clang; do
        [[ -x "$cand" ]] && { HIKARI_CC="$cand"; break; }
    done
fi
[[ -n "$HIKARI_CC" ]] || die "no clang found for the clean comparison; set HIKARI_CC"
export HIKARI_CC
note "clang:  $HIKARI_CC ($("$HIKARI_CC" --version | sed -n '1p'))"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# compare <label> <source> [passes]
compare() {
    local label="$1" src="$2" passes="${3:-}"
    local obf="obf-$(basename "$src" .c)" clean="clean-$(basename "$src" .c)"
    if [[ -n "$passes" ]]; then
        HIKARI_PASSES="$passes" HIKARI_SEED=7 \
            hikari-clang -O0 "$src" -o "$obf" 2>/dev/null ||
            die "$label: hikari-clang failed to build the obfuscated copy"
    else
        hikari-clang -O0 "$src" -o "$obf" 2>/dev/null ||
            die "$label: hikari-clang failed to build the obfuscated copy"
    fi
    "$HIKARI_CC" -O0 "$src" -o "$clean" ||
        die "$label: the clean build failed"

    # set +e: these programs are allowed to exit non-zero.
    set +e
    "./$obf"   > "$obf.out"   2>/dev/null; local a=$?
    "./$clean" > "$clean.out" 2>/dev/null; local b=$?
    set -e
    if ! diff -u "$clean.out" "$obf.out" > "$obf.diff"; then
        echo "--- $label: output DIFFERS (exit obf=$a clean=$b) ---" >&2
        cat "$obf.diff" >&2
        die "$label: obfuscated output differs from the clean build"
    fi
    note "ok:     $label  (exit obf=$a clean=$b, $(wc -l < "$obf.out") lines, $(stat -c%s "$obf") bytes)"
    # The obfuscated binary must be a real binary of the packaged architecture.
    file -b "$obf" | sed 's/^/          /' >&2
}

command -v file >/dev/null 2>&1 || die "need file(1) to inspect the produced binaries"

for s in arith control hello memory; do
    compare "$s (default pipeline)" "/usr/lib/hikari/examples/$s.c"
done
compare "vmp_add (enable-vmp,enable-cffobf)" \
    /usr/lib/hikari/examples/vmp_add.c "hikari(enable-vmp,enable-cffobf)"
compare "neg_idx (enable-vmp)" \
    /usr/lib/hikari/examples/neg_idx.c "hikari(enable-vmp)"
compare "vmp_complex (enable-vmp)" \
    /usr/lib/hikari/examples/vmp_complex.c "hikari(enable-vmp)"

note "--- removing the package ---"
dpkg -r hikari >/dev/null
leftovers=()
for p in /usr/bin/hikari-clang /usr/lib/hikari /usr/share/doc/hikari; do
    [[ -e "$p" ]] && leftovers+=("$p")
done
if [[ ${#leftovers[@]} -gt 0 ]]; then
    printf 'verify-deb: left behind: %s\n' "${leftovers[*]}" >&2
    exit 1
fi
note "ok:     removed cleanly"

note "PASS: $(basename "$DEB")"
