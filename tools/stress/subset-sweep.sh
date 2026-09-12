#!/usr/bin/env bash
# Enumerate every non-empty subset of the shipped pass set for one sample, and
# report which combinations time out or miscompare.  Used to pin a
# pass-interaction bug to the smallest set that reproduces it.
#
# A timeout is reported as a timeout, not a hang, and it is not a verdict:
# obfuscation can slow a recursive function down by three orders of magnitude,
# so a subset that overruns --timeout may be perfectly correct.  Re-run the
# smallest such subset with a much larger --timeout before calling it a bug.
#
# Usage: subset-sweep.sh <src.c> [--runs N] [--timeout S]
#
# Note: the hit here isolates a candidate.  subsets that only *contain* the
# culprit will also time out, so read the list from the smallest set upwards.
set -uo pipefail

SRC="${1:?usage: subset-sweep.sh <src.c> [--runs N] [--timeout S]}"
shift || true
RUNS=1
TOUT=120
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs) RUNS="$2"; shift 2 ;;
        --timeout) TOUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

D=/home/panxcz/Documents/kont/Hikari/dist/hikari-android-toolchain
export LD_LIBRARY_PATH="$D/llvm/lib"
OPT="$D/llvm/bin/opt"
PLUG=/home/panxcz/Documents/kont/Hikari/build/obfuscation/libHikari.so
NDKB="$(ls -d /tmp/ndk29full/android-ndk-r29/toolchains/llvm/prebuilt/*/bin)"
CLANG="$NDKB/aarch64-linux-android24-clang"

WORK="$(mktemp -d /tmp/subset.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
NAME="$(basename "${SRC%.c}")"
SEED="${SEED:-2}"

PASSES=(enable-bcfobf enable-cffobf enable-subobf enable-splitobf enable-strcry enable-indibran)

"$CLANG" -O0 -Xclang -disable-O0-optnone -emit-llvm -c "$SRC" -o "$WORK/in.bc" || exit 2
"$CLANG" -static -O0 "$WORK/in.bc" -o "$WORK/clean" -lm || exit 2
EXPECT="$(timeout $((TOUT * 2)) qemu-aarch64-static "$WORK/clean" 2>&1)"
echo "== $NAME: expected output: $(tr '\n' '|' <<<"$EXPECT")"    slow=0
wrong=0
total=0
for mask in $(seq 1 $(((1 << ${#PASSES[@]}) - 1))); do
    set_passes=()
    for i in "${!PASSES[@]}"; do
        ((mask & (1 << i))) && set_passes+=("${PASSES[$i]}")
    done
    set_str="$(IFS=,; echo "${set_passes[*]}")"
    total=$((total + 1))

    if ! "$OPT" -load-pass-plugin="$PLUG" --passes="hikari($set_str)" -aesSeed="$SEED" \
         "$WORK/in.bc" -o "$WORK/t.bc" >"$WORK/opt.log" 2>&1; then
        echo "  [$set_str] OPT FAILED"
        continue
    fi
    if ! "$CLANG" -static -O0 "$WORK/t.bc" -o "$WORK/t.bin" -lm >"$WORK/cc.log" 2>&1; then
        echo "  [$set_str] CODEGEN FAILED"
        continue
    fi

    outcome=ok
    for _ in $(seq 1 "$RUNS"); do
        got="$(timeout "$TOUT" qemu-aarch64-static "$WORK/t.bin" 2>&1)"
        rc=$?
        if [[ $rc -eq 124 ]]; then outcome=timeout; break; fi
        if [[ "$got" != "$EXPECT" ]]; then outcome=wrong; break; fi
    done
    case "$outcome" in
        timeout) echo "  [$set_str] TIMEOUT after ${TOUT}s (may be slow, not broken)"; slow=$((slow + 1)) ;;
        wrong)   echo "  [$set_str] *** WRONG *** got=$(tr '\n' '|' <<<"$got")"; wrong=$((wrong + 1)) ;;
    esac
done

echo "== $NAME: $total subsets, $slow timeout, $wrong wrong"
