#!/usr/bin/env bash
#
# smoke-test.sh — prove the plugin actually obfuscates *and* that obfuscated code
# still behaves. Runs headless, so CI can gate every release on it.
#
# Checks
#   1. opt (LLVM 22) loads libHikari.so and the pass pipeline runs.
#   2. Host: for each pass set, the obfuscated binary prints exactly what the
#      plain binary prints, and its .text is substantially larger.
#   3. Android: samples compile to aarch64 ELF objects/executables that still
#      contain the virtualized `vmp_ch_*` handlers (enable-vmp).
#   4. Seeded sweep: the same sample is re-obfuscated across fixed PRNG seeds.
#      The obfuscator seeds itself from the wall clock, so a miscompilation can
#      hide behind a lucky draw; pinning -aesSeed makes it reproduce.
#   5. Debug build: -g survives the LLVM 21 -> 22 -> 21 hand-off and the result
#      still carries DWARF.  This is the one check that would have caught the
#      "error: Invalid record" failure, which only appears once debug metadata
#      is in the module.
#
# Usage:
#   HIKARI_NDK=/path/ndk HIKARI_CC=/usr/lib/llvm-22/bin/clang \
#   HIKARI_OPT=/usr/lib/llvm-22/bin/opt HIKARI_PLUGIN=build/obfuscation/libHikari.so \
#   ./smoke-test.sh
#
# Skips the Android section (with a warning) when no NDK is configured.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
W="$SELF_DIR/hikari-clang"

HIKARI_OPT="${HIKARI_OPT:-${LLVM_PREFIX:-/usr/lib/llvm-22}/bin/opt}"
HIKARI_CC="${HIKARI_CC:-${LLVM_PREFIX:-/usr/lib/llvm-22}/bin/clang}"
PLUGIN="${HIKARI_PLUGIN:-$HIKARI_ROOT/build/obfuscation/libHikari.so}"

PASS=0
FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  - $*"; }

for f in "$W" "$HIKARI_CC" "$HIKARI_OPT" "$PLUGIN"; do
    [[ -f "$f" ]] || { echo "smoke-test: missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hikari-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

export HIKARI_PLUGIN="$PLUGIN" HIKARI_OPT="$HIKARI_OPT"

echo "== tools =="
echo "  opt:    $HIKARI_OPT ($("$HIKARI_OPT" --version 2>/dev/null | head -2 | tail -1))"
echo "  clang:  $HIKARI_CC ($("$HIKARI_CC" --version | head -1))"
echo "  plugin: $PLUGIN"

echo
echo "== 1. plugin loads into opt =="
echo 'target triple = "x86_64-unknown-linux-gnu"
define i32 @f(i32 %a) { %r = add i32 %a, 1
  ret i32 %r }' > t.ll
for p in "hikari(enable-splitobf)" "hikari(enable-bcfobf,enable-cffobf)" \
         "hikari(enable-subobf)" "hikari(enable-indibran)" "hikari(enable-constenc)" \
         "hikari(enable-strcry)"; do
    if "$HIKARI_OPT" -load-pass-plugin="$PLUGIN" --passes="$p" t.ll -o /dev/null >/dev/null 2>&1; then
        ok "$p"
    else
        bad "$p failed to run"
    fi
done

# ---------------------------------------------------------------- host run ---
echo
echo "== 2. host behaviour (clean vs obfuscated output) =="

run_set() { # <name> <passes> <sample>
    local name="$1" passes="$2" src="$HIKARI_ROOT/samples/c/$3" label="$3/$1"
    local clean obf
    if ! HIKARI_OBF=0 HIKARI_CC="$HIKARI_CC" "$W" -O0 "$src" -o clean.bin >/dev/null 2>&1; then
        bad "$label: clean build failed"; return
    fi
    if ! HIKARI_PASSES="$passes" HIKARI_CC="$HIKARI_CC" "$W" -O0 "$src" -o obf.bin >/dev/null 2>&1; then
        bad "$label: obfuscated build failed"; return
    fi
    clean="$(./clean.bin 2>&1)"; obf="$(./obf.bin 2>&1)"
    if [[ -z "$clean" ]]; then
        bad "$label: clean binary produced no output (cannot compare)"; return
    fi
    if [[ "$clean" != "$obf" ]]; then
        bad "$label: output differs"
        echo "    clean: $clean" >&2
        echo "    obf:   $obf" >&2
        return
    fi
    local cs os
    cs="$(stat -c %s clean.bin 2>/dev/null || stat -f %z clean.bin)"
    os="$(stat -c %s obf.bin 2>/dev/null || stat -f %z obf.bin)"
    if (( os <= cs )); then
        bad "$label: obfuscated binary not larger ($cs -> $os bytes)"
        return
    fi
    ok "$label: identical output, ${cs} -> ${os} bytes"
}

run_set default  'hikari(enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran)' vmp_add.c
run_set vmp      'hikari(enable-vmp,enable-cffobf)' vmp_add.c
run_set allobf   'hikari(enable-allobf)'            hello.c
run_set constenc 'hikari(enable-constenc,enable-subobf,enable-splitobf)' vmp_complex.c
# Signed pointer arithmetic: negative, run-time GEP indices (`p[i - 1]`) go
# through `sext i32 -> i64` and a signed GEP displacement in the VM.
run_set signedidx     'hikari(enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf)' neg_idx.c
run_set signedidx_vmp 'hikari(enable-vmp,enable-cffobf,enable-subobf)'                   neg_idx.c

# ------------------------------------------------------------ android part ---
echo
echo "== 3. android aarch64 output =="
if [[ -z "${HIKARI_NDK:-}" ]]; then
    skip "HIKARI_NDK not set — Android checks skipped"
else
    ndk_bin=""
    for d in "$HIKARI_NDK"/toolchains/llvm/prebuilt/*/bin; do
        [[ -x "$d/clang" ]] && { ndk_bin="$d"; break; }
    done
    if [[ -z "$ndk_bin" ]]; then
        bad "no toolchains/llvm/prebuilt/*/bin/clang under HIKARI_NDK"
    else
        cc="$ndk_bin/aarch64-linux-android24-clang"
        [[ -x "$cc" ]] || cc="$ndk_bin/clang"
        readelf="$ndk_bin/llvm-readelf"; nm="$ndk_bin/llvm-nm"
        [[ -x "$readelf" ]] || readelf=readelf
        [[ -x "$nm" ]] || nm=nm

        for s in vmp_add.c hello.c vmp_complex.c neg_idx.c arith.c control.c memory.c; do
            if ! HIKARI_PASSES='hikari(enable-vmp,enable-cffobf)' HIKARI_CC="$cc" \
                 "$W" -c "$HIKARI_ROOT/samples/c/$s" -o "$WORK/${s%.c}.o" >/dev/null 2>&1; then
                bad "$s: android compile failed"; continue
            fi
            arch="$("$readelf" -h "$WORK/${s%.c}.o" 2>/dev/null | awk '/Machine:/ {print $2, $3}')"
            [[ "$arch" == *AArch64* ]] || { bad "$s: expected AArch64 object, got '$arch'"; continue; }
            # Count the whole stream, do not grep -q for it.  With `set -o
            # pipefail`, `grep -q` exiting on its first match SIGPIPEs nm, and
            # the pipeline then reports failure even though the symbols are
            # there — which made this line pass or fail depending on how much
            # nm had already written.
            vmp_hits="$("$nm" "$WORK/${s%.c}.o" 2>/dev/null | grep -c 'vmp_ch_' || true)"
            if [[ "$vmp_hits" -gt 0 ]]; then
                ok "$s: AArch64 object with virtualized handlers"
            else
                bad "$s: AArch64 object but no vmp_ch_* handlers"
            fi
        done

        # Same source, two pass sets, must not be byte-identical.
        HIKARI_PASSES='hikari(enable-bcfobf)' HIKARI_CC="$cc" \
            "$W" -c "$HIKARI_ROOT/samples/c/hello.c" -o a.o >/dev/null 2>&1
        HIKARI_PASSES='hikari(enable-vmp)' HIKARI_CC="$cc" \
            "$W" -c "$HIKARI_ROOT/samples/c/hello.c" -o b.o >/dev/null 2>&1
        if [[ -f a.o && -f b.o ]] && ! cmp -s a.o b.o; then
            ok "different pass sets produce different objects"
        else
            bad "different pass sets produced identical objects"
        fi

        # Bitcode crossed the version boundary in the wrong direction.  Stage 2
        # is LLVM 22 and stage 3 is the NDK's LLVM 21, and bitcode only reads
        # downwards: a *plain* -O0 module happens to use records LLVM 21 still
        # knows, but add debug metadata and every -g build died in stage 3 with
        # "error: Invalid record".  Guards the hand-off *and* the debug info:
        # dropping -g inside the wrapper would also silence the failure, so the
        # DWARF check is the part that matters.
        if ! HIKARI_PASSES='hikari(enable-bcfobf,enable-cffobf,enable-splitobf)' HIKARI_CC="$cc" \
             "$W" --target=aarch64-linux-android24 -static -O0 -g \
             "$HIKARI_ROOT/samples/c/vmp_add.c" -o "$WORK/dbg.bin" >/dev/null 2>&1; then
            bad "-g build failed (IR hand-off across the LLVM 21/22 boundary)"
        else
            dwarfdump="$ndk_bin/llvm-dwarfdump"
            [[ -x "$dwarfdump" ]] || dwarfdump=dwarfdump
            cu="$("$dwarfdump" --debug-info "$WORK/dbg.bin" 2>/dev/null | grep -c 'DW_TAG_compile_unit' || true)"
            if [[ "$cu" -gt 0 ]]; then
                ok "-g build succeeds and keeps its DWARF ($cu compile units)"
            else
                bad "-g build produced no debug info"
            fi
        fi
    fi
fi

echo
echo "== 4. seeded sweep (miscompilation gate) =="
# Every pass draws from a PRNG seeded with the wall clock, so the pass sets in
# section 2 exercise exactly one random draw per run.  A bug that only shows up
# for some draws (e.g. an unsigned binop whose operands must not be
# sign-extended) then passes by luck.  Re-run one sample over fixed seeds so CI
# fails on the bug rather than on the calendar.
SWEEP_SEEDS="${HIKARI_SWEEP_SEEDS:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16}"
SWEEP_PASSES="${HIKARI_SWEEP_PASSES:-hikari(enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran)}"
SWEEP_SRC="$HIKARI_ROOT/samples/c/vmp_add.c"
if [[ ! -f "$SWEEP_SRC" ]]; then
    skip "samples/c/vmp_add.c missing — sweep skipped"
elif ! "$HIKARI_CC" -O0 -Xclang -disable-O0-optnone -emit-llvm -c "$SWEEP_SRC" \
        -o "$WORK/sweep.bc" >/dev/null 2>&1; then
    bad "sweep: could not lower $SWEEP_SRC to bitcode"
else
    "$HIKARI_CC" -O0 "$SWEEP_SRC" -o "$WORK/sweep.clean" >/dev/null 2>&1
    want="$("$WORK/sweep.clean" 2>&1)"
    ran=0
    broke=0
    for s in $SWEEP_SEEDS; do
        if ! "$HIKARI_OPT" -load-pass-plugin="$PLUGIN" --passes="$SWEEP_PASSES" \
             -aesSeed="$s" "$WORK/sweep.bc" -o "$WORK/sweep.obf.bc" >/dev/null 2>&1; then
            bad "seed $s: obfuscation failed"
            broke=$((broke + 1))
            continue
        fi
        if ! "$HIKARI_CC" "$WORK/sweep.obf.bc" -o "$WORK/sweep.obf" >/dev/null 2>&1; then
            bad "seed $s: obfuscated bitcode does not compile"
            broke=$((broke + 1))
            continue
        fi
        got="$("$WORK/sweep.obf" 2>&1)"
        if [[ "$got" != "$want" ]]; then
            bad "seed $s: output differs — replay with -aesSeed=$s"
            echo "    want: $want" >&2
            echo "    got:  $got" >&2
            broke=$((broke + 1))
            continue
        fi
        ran=$((ran + 1))
    done
    if [[ "$broke" -eq 0 ]]; then
        ok "$ran seeds all reproduce the clean output"
    fi
fi

echo
echo "== result: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
