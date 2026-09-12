#!/usr/bin/env bash
#
# stress-test.sh — differential test of the pass pipeline.
#
# smoke-test.sh compiles a handful of *groups* of passes, once each.  That is a
# coverage problem, not an effort problem: every pass draws its transformations
# from a PRNG, and a group hides which pass broke.  Three of the bugs found in
# this fork (unsigned operands sign-extended, `sext` reading the wrong width, a
# zero-extended GEP displacement) were draw-dependent, so they passed a single
# group run and only appeared when the seed changed.
#
# This script therefore runs the full cross product
#
#     samples × pass sets × seeds
#
# and for every cell builds the clean binary, obfuscates the same translation
# unit, links it, runs it and compares stdout, stderr and exit status.  It also
# reports cells where obfuscation was a no-op (byte-identical bitcode), because a
# pass that silently declines to run is a bug that no output comparison can see.
#
# Usage:
#   HIKARI_CC=/usr/lib/llvm-22/bin/clang HIKARI_OPT=/usr/lib/llvm-22/bin/opt \
#   HIKARI_PLUGIN=build/obfuscation/libHikari.so ./tools/stress/stress-test.sh
#
# Env:
#   HIKARI_STRESS_SEEDS    seeds to sweep            (default: 1 2 3 4)
#   HIKARI_STRESS_SAMPLES  sample basenames          (default: all of samples/c)
#   HIKARI_STRESS_JOBS     parallel jobs             (default: nproc)
#   HIKARI_STRESS_SETS     pass sets, "name=passes"  (default: every pass alone,
#                          plus the documented groups)
#   HIKARI_STRESS_TIMEOUT  seconds per program run   (default: 20)
#   HIKARI_STRESS_JOBS should stay small on a low-memory host: a single
#                        virtualization-heavy cell can want a gigabyte.
#   HIKARI_STRESS_KEEP     keep the work directory for inspection
#   HIKARI_STRESS_QUIET    only print the summary

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

HIKARI_CC="${HIKARI_CC:-${LLVM_PREFIX:-/usr/lib/llvm-22}/bin/clang}"
HIKARI_OPT="${HIKARI_OPT:-${LLVM_PREFIX:-/usr/lib/llvm-22}/bin/opt}"
PLUGIN="${HIKARI_PLUGIN:-$HIKARI_ROOT/build/obfuscation/libHikari.so}"

SEEDS="${HIKARI_STRESS_SEEDS:-1 2 3 4}"
JOBS="${HIKARI_STRESS_JOBS:-$( (nproc 2>/dev/null || echo 2) )}"
TIMEOUT="${HIKARI_STRESS_TIMEOUT:-20}"
QUIET="${HIKARI_STRESS_QUIET:-0}"

for f in "$HIKARI_CC" "$HIKARI_OPT" "$PLUGIN"; do
    [[ -f "$f" ]] || { echo "stress-test: missing $f" >&2; exit 2; }
done

# The pass sets.  Every pass gets a run of its own first: a group that
# miscompiles tells you a group is broken, one pass at a time tells you which.
# `vmp-cff` is the documented hybrid, `default` the shipped pipeline, `allobf`
# the everything-at-once mode.
DEFAULT_SETS=(
    "adb=enable-adb"
    "antihook=enable-antihook"
    "bcf=enable-bcfobf"
    "cff=enable-cffobf"
    "constenc=enable-constenc"
    "fco=enable-fco"
    "funcwra=enable-funcwra"
    "indibran=enable-indibran"
    "split=enable-splitobf"
    "strcry=enable-strcry"
    "sub=enable-subobf"
    "vmp=enable-vmp"
    "default=enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran"
    "vmp-cff=enable-vmp,enable-cffobf"
    "allobf=enable-allobf"
)

if [[ -n "${HIKARI_STRESS_SETS:-}" ]]; then
    read -r -a SETS <<<"$HIKARI_STRESS_SETS"
else
    SETS=("${DEFAULT_SETS[@]}")
fi

if [[ -n "${HIKARI_STRESS_SAMPLES:-}" ]]; then
    read -r -a SAMPLES <<<"$HIKARI_STRESS_SAMPLES"
else
    SAMPLES=()
    for s in "$HIKARI_ROOT"/samples/c/*.c; do
        [[ -f "$s" ]] || continue
        SAMPLES+=("$(basename "${s%.c}")")
    done
fi
[[ ${#SAMPLES[@]} -gt 0 ]] || { echo "stress-test: no samples found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hikari-stress.XXXXXX")"
if [[ "${HIKARI_STRESS_KEEP:-0}" == "1" ]]; then
    echo "stress-test: work directory $WORK"
else
    trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK/expect" "$WORK/in" "$WORK/runs" "$WORK/fail" "$WORK/log"

echo "== stress: ${#SAMPLES[@]} samples × ${#SETS[@]} pass sets × $(wc -w <<<"$SEEDS") seeds =="
echo "  clang:  $HIKARI_CC"
echo "  opt:    $HIKARI_OPT ($("$HIKARI_OPT" --version 2>/dev/null | head -2 | tail -1))"
echo "  plugin: $PLUGIN"
echo "  jobs:   $JOBS"

# --------------------------------------------------------- expectations -----
# One clean build per sample: the reference stdout/stderr and exit status.
echo
echo "== reference builds =="
bad_samples=()
for s in "${SAMPLES[@]}"; do
    src="$HIKARI_ROOT/samples/c/$s.c"
    if [[ ! -f "$src" ]]; then
        echo "  ✗ $s: no $src"
        bad_samples+=("$s")
        continue
    fi
    if ! "$HIKARI_CC" -O0 "$src" -o "$WORK/expect/$s.bin" >"$WORK/log/$s.clean.log" 2>&1; then
        echo "  ✗ $s: clean build failed"
        bad_samples+=("$s")
        continue
    fi
    if [[ "$(uname -s)" == "Darwin" ]]; then
        timeout "$TIMEOUT" "$WORK/expect/$s.bin" >"$WORK/expect/$s.out" 2>&1
    else
        timeout "$TIMEOUT" "$WORK/expect/$s.bin" >"$WORK/expect/$s.out" 2>&1
    fi
    echo $? >"$WORK/expect/$s.rc"
    if [[ ! -s "$WORK/expect/$s.out" ]]; then
        echo "  ✗ $s: clean binary printed nothing (nothing to compare)"
        bad_samples+=("$s")
        continue
    fi
    # Bitcode is lowered once per sample; only the seed and the pass set vary.
    if ! "$HIKARI_CC" -O0 -Xclang -disable-O0-optnone -emit-llvm -c "$src" \
         -o "$WORK/in/$s.bc" >"$WORK/log/$s.bc.log" 2>&1; then
        echo "  ✗ $s: could not lower to bitcode"
        bad_samples+=("$s")
        continue
    fi
    printf '  ✓ %s: %s bytes of output, rc=%s\n' "$s" \
        "$(stat -c %s "$WORK/expect/$s.out" 2>/dev/null || stat -f %z "$WORK/expect/$s.out")" \
        "$(cat "$WORK/expect/$s.rc")"
done

keep_samples=()
for s in "${SAMPLES[@]}"; do
    skip=0
    for b in "${bad_samples[@]:-}"; do
        [[ "$b" == "$s" ]] && skip=1
    done
    [[ "$skip" == 0 ]] && keep_samples+=("$s")
done
SAMPLES=("${keep_samples[@]}")
[[ ${#SAMPLES[@]} -gt 0 ]] || { echo "stress-test: no usable samples" >&2; exit 2; }

# ---------------------------------------------------------------- job list ---
: >"$WORK/jobs.txt"
for s in "${SAMPLES[@]}"; do
    for set in "${SETS[@]}"; do
        name="${set%%=*}"
        passes="${set#*=}"
        for seed in $SEEDS; do
            printf '%s|%s|%s|%s\n' "$s" "$name" "$passes" "$seed" >>"$WORK/jobs.txt"
        done
    done
done
total="$(wc -l <"$WORK/jobs.txt")"

# ------------------------------------------------------------------ runner ---
# Kept in its own file because xargs execs it; everything it needs comes from
# the environment so the per-job line can stay a plain string.
cat >"$WORK/job.sh" <<'JOB'
#!/usr/bin/env bash
set -uo pipefail
line="$1"
IFS='|' read -r sample setname passes seed <<<"$line"
id="$sample.$setname.s$seed"
run="$WORK/runs/$id"
mkdir -p "$run"

{
    printf 'sample=%s\npasses=hikari(%s)\nseed=%s\n' "$sample" "$passes" "$seed"
    printf 'replay: opt -load-pass-plugin=%s --passes="hikari(%s)" -aesSeed=%s %s/in/%s.bc -o obf.bc\n' \
        "$PLUGIN" "$passes" "$seed" "$WORK" "$sample"
} >"$run/info"

"$HIKARI_OPT" -load-pass-plugin="$PLUGIN" --passes="hikari($passes)" \
    -aesSeed="$seed" "$WORK/in/$sample.bc" -o "$run/obf.bc" \
    >"$run/opt.log" 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -gt 128 ]]; then
        # A signal death is usually the OOM killer: virtualization of a large
        # function is memory-hungry, and a small host running several cells at
        # once will lose one of them.  Reported separately so a real crash
        # (assert, segfault inside a pass) is not confused with that.
        printf 'stage=opt\nsignal=%s (%s)\n' "$((rc - 128))" "$(kill -l $((rc - 128)) 2>/dev/null || echo signum)" >>"$run/info"
        echo "opt-signal" >>"$run/fail"
    else
        printf 'stage=opt\nexit=%s\n' "$rc" >>"$run/info"
        echo "opt" >>"$run/fail"
    fi
    exit 0
fi
cmp -s "$WORK/in/$sample.bc" "$run/obf.bc" && echo "noop" >>"$run/info"

if ! "$HIKARI_CC" "$run/obf.bc" -o "$run/obf.bin" >"$run/link.log" 2>&1; then
    printf 'stage=link\n' >>"$run/info"
    echo "link" >>"$run/fail"
    exit 0
fi

timeout "$TIMEOUT" "$run/obf.bin" >"$run/out" 2>&1
rc=$?

if [[ "$rc" != "$(cat "$WORK/expect/$sample.rc")" ]]; then
    printf 'stage=run\nexpected rc=%s got rc=%s\n' \
        "$(cat "$WORK/expect/$sample.rc")" "$rc" >>"$run/info"
    echo "rc" >>"$run/fail"
    exit 0
fi
if ! cmp -s "$run/out" "$WORK/expect/$sample.out"; then
    printf 'stage=output\n' >>"$run/info"
    diff -u "$WORK/expect/$sample.out" "$run/out" >"$run/diff" 2>&1 || true
    echo "output" >>"$run/fail"
    exit 0
fi
exit 0
JOB
chmod +x "$WORK/job.sh"

echo
echo "== running $total cells ($JOBS in parallel) =="
export WORK PLUGIN HIKARI_OPT HIKARI_CC TIMEOUT
xargs -d '\n' -I{} -P "$JOBS" "$WORK/job.sh" {} <"$WORK/jobs.txt"

# ----------------------------------------------------------------- report ----
fails=0
noops=0
opt_fail=0
opt_signal=0
link_fail=0
rc_fail=0
out_fail=0
for d in "$WORK"/runs/*/; do
    [[ -f "$d/fail" ]] || continue
    fails=$((fails + 1))
    case "$(cat "$d/fail")" in
        opt) opt_fail=$((opt_fail + 1)) ;;
        opt-signal) opt_signal=$((opt_signal + 1)) ;;
        link) link_fail=$((link_fail + 1)) ;;
        rc) rc_fail=$((rc_fail + 1)) ;;
        output) out_fail=$((out_fail + 1)) ;;
    esac
done
noops="$(grep -l '^noop$' "$WORK"/runs/*/info 2>/dev/null | wc -l)"

echo
if [[ "$fails" -gt 0 ]]; then
    echo "== failures ($fails of $total) =="
    shown=0
    for d in "$WORK"/runs/*/; do
        [[ -f "$d/fail" ]] || continue
        shown=$((shown + 1))
        [[ "$shown" -gt 12 ]] && { echo "  ... $((fails - 12)) more"; break; }
        echo
        sed 's/^/  /' "$d/info"
        for extra in diff opt.log link.log; do
            [[ -s "$d/$extra" ]] || continue
            echo "  --- $extra ---"
            head -20 "$d/$extra" | sed 's/^/  /'
        done
    done
fi

echo
echo "== stress result =="
echo "  cells:        $total"
echo "  ok:           $((total - fails))"
echo "  opt crashed:  $opt_fail"
echo "  opt killed:   $opt_signal"
echo "  link failed:  $link_fail"
echo "  exit code:    $rc_fail"
echo "  output:       $out_fail"
[[ "$noops" -eq 0 ]] || echo "  no-op cells:  $noops (obfuscated bitcode was byte-identical to the input)"
if [[ "$opt_signal" -gt 0 ]]; then
    echo
    echo "  NOTE: $opt_signal cell(s) had opt killed by a signal, which is what the"
    echo "        kernel does when a cell does not fit in RAM.  Virtualization of a"
    echo "        large function is hungry; retry with HIKARI_STRESS_JOBS=1 before"
    echo "        treating these as pass bugs."
fi
echo
if [[ "$fails" -eq 0 ]]; then
    echo "== stress: $total/$total cells match the clean build =="
else
    echo "== stress: $fails/$total cells FAILED =="
fi
[[ "$fails" -eq 0 ]]
