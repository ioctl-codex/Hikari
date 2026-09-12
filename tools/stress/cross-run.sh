#!/usr/bin/env bash
#
# cross-run.sh — run the obfuscated Android binaries, don't just compile them.
#
# The other gates stop at the object file for non-host targets: smoke-test.sh
# checks that an AArch64 object contains the virtualized handlers, and the
# package verification checks the same for four ABIs.  Neither says whether the
# code *works* on the architecture it was built for, and 32-bit ARM is exactly
# where pointer-size assumptions break — an i64 vs pointer confusion that is
# invisible on x86_64 (the bug class behind the signed-GEP fix).
#
# Android's own dynamic linker is not in the NDK, so these binaries are linked
# statically and executed with qemu-user.  Everything else is the shipping path:
# the same `hikari-clang` driver, the same plugin, the same pipelines.
#
# Usage:
#   HIKARI_NDK=/path/to/ndk HIKARI_PLUGIN=build/obfuscation/libHikari.so \
#   HIKARI_OPT=/usr/lib/llvm-22/bin/opt ./tools/stress/cross-run.sh
#
# Env:
#   HIKARI_NDK        Android NDK (required — it supplies clang and the sysroot)
#   HIKARI_PLUGIN     libHikari.so
#   HIKARI_OPT        LLVM 22 opt
#   HIKARI_CROSS_ABIS     "aarch64 armv7a"      (also: x86_64, i686)
#   HIKARI_CROSS_SETS     "name=passes ..."     (default: the shipped pipeline
#                          and the VMP+CFF hybrid)
#   HIKARI_CROSS_SEEDS    seeds                 (default: 1 2)
#   HIKARI_CROSS_SAMPLES  sample basenames      (default: all of samples/c)
#   HIKARI_CROSS_TIMEOUT  seconds per obfuscated run (default 120)
#   HIKARI_CROSS_WARN_RATIO  slowdown vs the clean build worth mentioning
#                          (default 1000)
#
# On timeouts, and why the ceiling is generous: virtualization plus flattening
# is *legitimately* two to three orders of magnitude slower than the clean build
# on recursive code — a virtualized fib costs ~2400x the cycles of the original,
# and qemu adds its own multiple on top.  A tight ceiling therefore reports
# correct-but-slow binaries as hangs: an earlier 60s default did exactly that
# and was written down as "an ARM-only infinite loop" before the timings were
# measured.  Every case now reports its own clean-vs-obfuscated wall time, a run
# that overruns the ceiling is labelled a timeout rather than a hang, and the
# samples keep their recursion shallow enough that the whole matrix still fits
# in a CI job.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
W="$HIKARI_ROOT/tools/android-toolchain/hikari-clang"

HIKARI_PLUGIN="${HIKARI_PLUGIN:-$HIKARI_ROOT/build/obfuscation/libHikari.so}"
HIKARI_OPT="${HIKARI_OPT:-${LLVM_PREFIX:-/usr/lib/llvm-22}/bin/opt}"
HIKARI_NDK="${HIKARI_NDK:-}"

[[ -n "$HIKARI_NDK" && -d "$HIKARI_NDK" ]] || { echo "cross-run: set HIKARI_NDK to an Android NDK" >&2; exit 2; }
[[ -f "$HIKARI_PLUGIN" ]] || { echo "cross-run: missing $HIKARI_PLUGIN" >&2; exit 2; }
[[ -x "$HIKARI_OPT" ]] || { echo "cross-run: missing $HIKARI_OPT" >&2; exit 2; }

read -r -a ABIS <<<"${HIKARI_CROSS_ABIS:-aarch64 armv7a}"
read -r -a SEEDS <<<"${HIKARI_CROSS_SEEDS:-1 2}"
if [[ -n "${HIKARI_CROSS_SETS:-}" ]]; then
    read -r -a SETS <<<"$HIKARI_CROSS_SETS"
else
    SETS=(
        "default=enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran"
        "vmp-cff=enable-vmp,enable-cffobf"
    )
fi
if [[ -n "${HIKARI_CROSS_SAMPLES:-}" ]]; then
    read -r -a SAMPLES <<<"$HIKARI_CROSS_SAMPLES"
else
    SAMPLES=()
    for s in "$HIKARI_ROOT"/samples/c/*.c; do
        [[ -f "$s" ]] || continue
        SAMPLES+=("$(basename "${s%.c}")")
    done
fi

ndk_bin=""
for d in "$HIKARI_NDK"/toolchains/llvm/prebuilt/*/bin; do
    [[ -x "$d/clang" ]] && { ndk_bin="$d"; break; }
done
[[ -n "$ndk_bin" ]] || { echo "cross-run: no clang under $HIKARI_NDK" >&2; exit 2; }

# target triple suffix, qemu binary, and a human name per ABI
abi_triple() {
    case "$1" in
        aarch64) printf 'aarch64-linux-android24' ;;
        armv7a) printf 'armv7a-linux-androideabi24' ;;
        x86_64) printf 'x86_64-linux-android24' ;;
        i686) printf 'i686-linux-android24' ;;
        *) return 1 ;;
    esac
}
abi_qemu() {
    case "$1" in
        aarch64) printf 'qemu-aarch64-static' ;;
        armv7a) printf 'qemu-arm-static' ;;
        x86_64) printf 'qemu-x86_64-static' ;;
        i686) printf 'qemu-i386-static' ;;
        *) return 1 ;;
    esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hikari-cross.XXXXXX")"
if [[ "${HIKARI_CROSS_KEEP:-0}" == "1" ]]; then
    echo "cross-run: work directory $WORK"
else
    trap 'rm -rf "$WORK"' EXIT
fi

TIMEOUT_S="${HIKARI_CROSS_TIMEOUT:-120}"
# 1000x, not 100x: flattening alone costs ~100x on ordinary code and warning on
# that is noise.  The cases worth naming are the ones close enough to the
# timeout to be mistaken for a hang.
WARN_RATIO="${HIKARI_CROSS_WARN_RATIO:-1000}"

now_ms() { date +%s%3N; }

PASS=0
FAIL=0
SLOW=0
ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); }
warn() { echo "  ! $*" >&2; SLOW=$((SLOW + 1)); }

echo "== cross-run: ${#ABIS[@]} ABIs × ${#SAMPLES[@]} samples × ${#SETS[@]} pass sets × $(wc -w <<<"${SEEDS[*]}") seeds =="
echo "  ndk:    $HIKARI_NDK ($("$ndk_bin/clang" --version | head -1))"
echo "  plugin: $HIKARI_PLUGIN"

export HIKARI_NDK HIKARI_PLUGIN HIKARI_OPT HIKARI_CC="$ndk_bin/clang"

for abi in "${ABIS[@]}"; do
    triple="$(abi_triple "$abi")" || { bad "$abi: unknown ABI"; continue; }
    qemu="$(abi_qemu "$abi")"
    if ! command -v "$qemu" >/dev/null 2>&1; then
        echo "  - $abi: $qemu not installed, skipped"
        continue
    fi

    echo
    echo "== $abi ($triple, qemu: $qemu) =="
    for s in "${SAMPLES[@]}"; do
        src="$HIKARI_ROOT/samples/c/$s.c"
        [[ -f "$src" ]] || { bad "$s: no $src"; continue; }

        # Reference: the same toolchain, no obfuscation, run the same way.
        if ! HIKARI_OBF=0 "$W" --target="$triple" -static -O0 "$src" \
             -o "$WORK/$s.$abi.clean" >"$WORK/$s.$abi.clean.log" 2>&1; then
            bad "$s/$abi: clean build failed ($(tail -2 "$WORK/$s.$abi.clean.log" | tr '\n' ' '))"
            continue
        fi
        t0="$(now_ms)"
        timeout "$TIMEOUT_S" "$qemu" "$WORK/$s.$abi.clean" >"$WORK/$s.$abi.expect" 2>&1
        rc=$?
        clean_ms=$(( $(now_ms) - t0 ))
        if [[ ! -s "$WORK/$s.$abi.expect" ]]; then
            bad "$s/$abi: clean binary printed nothing under qemu (rc=$rc)"
            continue
        fi

        for set in "${SETS[@]}"; do
            name="${set%%=*}"
            passes="${set#*=}"
            for seed in "${SEEDS[@]}"; do
                label="$s/$abi/$name/seed $seed"
                if ! HIKARI_PASSES="hikari($passes)" HIKARI_SEED="$seed" \
                     "$W" --target="$triple" -static -O0 "$src" \
                     -o "$WORK/$s.$abi.obf" >"$WORK/$s.$abi.obf.log" 2>&1; then
                    bad "$label: obfuscated build failed ($(tail -2 "$WORK/$s.$abi.obf.log" | tr '\n' ' '))"
                    continue
                fi
                t0="$(now_ms)"
                timeout "$TIMEOUT_S" "$qemu" "$WORK/$s.$abi.obf" >"$WORK/$s.$abi.got" 2>&1
                got_rc=$?
                obf_ms=$(( $(now_ms) - t0 ))
                if [[ "$got_rc" -eq 124 ]]; then
                    # Not proof of a hang: obfuscation is legitimately very slow
                    # here.  Say which it is so the next reader does not have to
                    # re-measure what this comment already answers.
                    bad "$label: no result after ${TIMEOUT_S}s (timeout, not necessarily a hang)"
                    echo "    clean ran in ${clean_ms}ms; raise HIKARI_CROSS_TIMEOUT to tell a slow binary from a looping one" >&2
                    continue
                fi
                if [[ "$got_rc" != "$rc" ]]; then
                    bad "$label: exit status differs (clean $rc, obfuscated $got_rc)"
                    continue
                fi
                if ! cmp -s "$WORK/$s.$abi.expect" "$WORK/$s.$abi.got"; then
                    bad "$label: output differs under qemu"
                    diff -u "$WORK/$s.$abi.expect" "$WORK/$s.$abi.got" | head -10 | sed 's/^/    /' >&2
                    echo "    replay: HIKARI_PASSES='hikari($passes)' HIKARI_SEED=$seed \\" >&2
                    echo "            $W --target=$triple -static -O0 $src -o obf && $qemu obf" >&2
                    continue
                fi
                size_clean="$(stat -c %s "$WORK/$s.$abi.clean")"
                size_obf="$(stat -c %s "$WORK/$s.$abi.obf")"
                ratio=$(( obf_ms / (clean_ms > 0 ? clean_ms : 1) ))
                if (( ratio >= WARN_RATIO )); then
                    warn "$label: identical output, ${clean_ms}ms -> ${obf_ms}ms (${ratio}x slower; obfuscation cost, not a hang)"
                else
                    ok "$label: identical output under qemu, $size_clean -> $size_obf bytes (${clean_ms}ms -> ${obf_ms}ms)"
                fi
            done
        done
    done
done

echo
echo "== cross-run result: $PASS passed, $SLOW slow (still correct), $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
