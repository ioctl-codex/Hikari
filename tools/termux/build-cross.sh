#!/usr/bin/env bash
#
# build-cross.sh — build the Termux (aarch64, Android) plugin without a device,
# cross-compiling with the NDK against Termux's own LLVM.
#
# This is the scripted form of what tools/termux/README.md describes, and it is
# what CI runs.  `tools/termux/build.sh` remains the supported route for a real
# device; this one exists so that the package can also be produced (and checked)
# on a Linux box.
#
# The trick, and the only non-obvious thing here: Termux's LLVM cmake files bake
# in absolute paths.  LLVMConfig.cmake says LLVM_INCLUDE_DIRS is
# /data/data/com.termux/files/usr/include, and LLVMExports.cmake names every
# library by its on-device path.  There is no such directory on a build machine,
# so rather than patch those files or paper over them with -I flags, the Termux
# packages are unpacked *at that path*.  dpkg-deb -x unpacks a Termux package
# into exactly the prefix it declares, so extracting to / is all it takes, and
# everything LLVM says resolves with nothing patched.
#
# That means this script writes under /data/data/com.termux/files/usr and needs
# permission to do so (root, or sudo in CI).  It is a build-machine script, not
# something to run on a phone.
#
# Usage:
#   sudo ./tools/termux/build-cross.sh                  build + verify the plugin
#   sudo ./tools/termux/build-cross.sh --package        ...and write the .deb
#   sudo ./tools/termux/build-cross.sh --clean          remove the unpacked prefix
#
# Env:
#   HIKARI_NDK        the NDK to compile with (default: $ANDROID_NDK_ROOT, then
#                     android-ndk* in /opt and /usr/local)
#   PREFIX            where the Termux tree is unpacked (default: the Termux one)
#   WORK_DIR          cache for the downloaded packages and the build tree
#   OUT_DIR           where the .deb goes (default: <repo>/dist)
#   VERSION           package version (default: 1.0.0)
#   DEB_ARCH          package architecture (default: aarch64)
#   TERMUX_INDEX      Packages index to resolve the packages from

set -euo pipefail

die() { printf 'termux-cross: %s\n' "$*" >&2; exit 1; }
note() { printf 'termux-cross: %s\n' "$*" >&2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
WORK_DIR="${WORK_DIR:-$HIKARI_ROOT/build-termux-cross}"
OUT_DIR="${OUT_DIR:-$HIKARI_ROOT/dist}"
VERSION="${VERSION:-1.0.0}"
DEB_ARCH="${DEB_ARCH:-aarch64}"
# The index exists gzip-compressed and plain; the .xz name is a 404.  Guessing
# one filename and hoping is a way for a build to break on a Tuesday, so the
# candidates are tried in order and an explicit TERMUX_INDEX wins outright.
TERMUX_INDEX_BASE="${TERMUX_INDEX_BASE:-https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64}"
TERMUX_INDEX_CANDIDATES=(
    "${TERMUX_INDEX:-}"
    "$TERMUX_INDEX_BASE/Packages.gz"
    "$TERMUX_INDEX_BASE/Packages"
    "$TERMUX_INDEX_BASE/Packages.xz"
)

# Everything an on-device `pkg install llvm libllvm clang cmake ninja` brings,
# plus the pieces LLVMExports.cmake insists on existing.  libllvm carries the
# headers as well as the shared library -- there is no separate -dev package.
TERMUX_PACKAGES=(
    libllvm
    libllvm-static
    llvm
    llvm-tools
    libcompiler-rt
    libpolly
)

DO_PACKAGE=0
DO_CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --package) DO_PACKAGE=1 ;;
        --clean)   DO_CLEAN=1 ;;
        -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument '$arg' (expected --package, --clean)" ;;
    esac
done

if [[ "$DO_CLEAN" == "1" ]]; then
    [[ "$PREFIX" == /data/data/com.termux/* ]] ||
        die "refusing to clean '$PREFIX': not the Termux prefix"
    rm -rf "$PREFIX"
    note "removed $PREFIX"
    exit 0
fi

# ------------------------------------------------------------------ the NDK ---
if [[ -z "${HIKARI_NDK:-}" ]]; then
    if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
        HIKARI_NDK="$ANDROID_NDK_ROOT"
    else
        for d in /opt/android-ndk-* /opt/panxcz/ndk/android-ndk-* \
                 /usr/local/android-ndk-* "$HOME"/android-ndk-*; do
            [[ -x "$d/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++" ]] || continue
            HIKARI_NDK="$d"
            break
        done
    fi
fi
[[ -n "${HIKARI_NDK:-}" && -f "$HIKARI_NDK/build/cmake/android.toolchain.cmake" ]] ||
    die "no NDK found; set HIKARI_NDK (e.g. /opt/android-ndk-r29)"
NDK_CLANGXX="$HIKARI_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
[[ -x "$NDK_CLANGXX" ]] || die "no clang++ under $HIKARI_NDK"
note "ndk:    $HIKARI_NDK"
note "prefix: $PREFIX"

# ----------------------------------------------------------------- the index ---
# The version Termux ships moves; its index does not.  Resolving name -> version
# -> filename -> sha256 from the index means this script keeps working when
# 21.1.8 becomes 21.1.9, and that what gets downloaded is what Termux publishes
# for that version rather than whatever a URL happened to serve today.
mkdir -p "$WORK_DIR/debs"
python3 - "$WORK_DIR/debs/Packages" "${TERMUX_INDEX_CANDIDATES[@]}" <<'PY'
import gzip, lzma, sys, urllib.request

dest = sys.argv[1]
problems = []
for url in [u for u in sys.argv[2:] if u]:
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            raw = response.read()
    except Exception as exc:
        problems.append('%s (%s)' % (url, exc))
        continue
    for decode in (gzip.decompress, lzma.decompress, lambda b: b):
        try:
            raw = decode(raw)
            break
        except Exception:
            continue
    if not raw.lstrip().startswith(b'Package: '):
        problems.append('%s (not a Packages file)' % url)
        continue
    with open(dest, 'wb') as fh:
        fh.write(raw)
    print('index: %s -> %s (%d bytes)' % (url, dest, len(raw)))
    break
else:
    sys.exit('could not fetch a package index:\n  ' + '\n  '.join(problems))
PY

# ------------------------------------------------------------------ the tree ---
need_root() {
    [[ -w "$(dirname "$PREFIX")" || -w "$PREFIX" || "$(id -u)" == "0" ]]
}
need_root || die "cannot write $PREFIX; run this as root (it unpacks the Termux packages at their real paths)"
mkdir -p "$(dirname "$PREFIX")"

for pkg in "${TERMUX_PACKAGES[@]}"; do
    read -r version filename sha < <(python3 - "$WORK_DIR/debs/Packages" "$pkg" <<'PY'
import sys

path, want = sys.argv[1], sys.argv[2]
fields, in_stanza = {}, False
for line in open(path, encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    if line == '':
        if in_stanza and fields.get('Package') == want:
            break
        fields, in_stanza = {}, False
        continue
    in_stanza = True
    if ': ' in line:
        k, v = line.split(': ', 1)
        fields[k] = v
if fields.get('Package') != want:
    sys.exit('package %r not in the index' % want)
print(fields['Version'], fields['Filename'], fields['SHA256'])
PY
)
    [[ -n "$version" && -n "$filename" && -n "$sha" ]] ||
        die "could not resolve '$pkg' from the index (need a version, a filename and a sha256)"
    deb="$WORK_DIR/debs/$(basename "$filename")"
    if [[ ! -s "$deb" ]]; then
        note "fetch:  $pkg $version"
        curl -fSL --retry 5 --retry-delay 3 -o "$deb" \
            "https://packages.termux.dev/apt/termux-main/$filename"
    fi
    got="$(sha256sum "$deb" | cut -d' ' -f1)"
    [[ "$got" == "$sha" ]] ||
        die "$pkg: sha256 mismatch
      want $sha
      got  $got (delete $deb and retry)"
    note "ok:     $pkg $version  sha256 ${sha:0:16}..."
    # -x into / because the package's own paths already are /data/data/...
    dpkg-deb -x "$deb" /
done

# ------------------------------------------------- what CMake will insist on ---
# LLVMExports.cmake checks that every path it bakes in exists, and aborts the
# configure over any that does not -- even for targets this plugin never links.
# Checking them here says which file is missing, once, instead of leaving it to
# a five-hundred-line CMake error.
cd "$PREFIX/lib/cmake/llvm"
grep -ohE '\$\{_IMPORT_PREFIX\}/[^"]*' LLVMExports*.cmake |
    sed "s|\${_IMPORT_PREFIX}|$PREFIX|" | sort -u > "$WORK_DIR/expected.txt"
: > "$WORK_DIR/missing.txt"
while read -r p; do [[ -e "$p" ]] || printf '%s\n' "$p" >> "$WORK_DIR/missing.txt"; done \
    < "$WORK_DIR/expected.txt"
note "cmake expects $(wc -l < "$WORK_DIR/expected.txt") files; missing $(wc -l < "$WORK_DIR/missing.txt")"

# libomp.a is the one path no Termux package provides: OpenMP is simply not
# built for Termux, yet the exported `omp` target still points at it.  An empty
# placeholder is the least-bad answer for a target nothing links, and the symbol
# check at the end proves the plugin did not actually pull OpenMP in.
if [[ "$(wc -l < "$WORK_DIR/missing.txt")" == "1" ]] &&
   grep -q "^$PREFIX/lib/libomp\.a$" "$WORK_DIR/missing.txt"; then
    : > "$PREFIX/lib/libomp.a"
    : > "$WORK_DIR/missing.txt"
    note "note:   Termux ships no libomp.a; placeholder created for the unused 'omp' target"
fi
[[ ! -s "$WORK_DIR/missing.txt" ]] ||
    { echo "still missing:" >&2; cat "$WORK_DIR/missing.txt" >&2; exit 1; }

readelf -d "$PREFIX/lib/libLLVM.so" | sed -n 's/.*SONAME.*\[\(.*\)\].*/termux-cross: libLLVM soname \1/p'

# ------------------------------------------------------------------ the build ---
BUILD_DIR="$WORK_DIR/build"
rm -rf "$BUILD_DIR"
cmake -G Ninja -S "$HIKARI_ROOT" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$HIKARI_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLT_LLVM_INSTALL_DIR="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
cmake --build "$BUILD_DIR" -j"$(nproc)"

PLUGIN="$BUILD_DIR/obfuscation/libHikari.so"
[[ -s "$PLUGIN" ]] || die "the build produced no plugin at $PLUGIN"
note "built:  $PLUGIN ($(stat -c%s "$PLUGIN") bytes)"

# ------------------------------------------------------- the checks that matter ---
# A plugin is loadable only if the host library exports everything it needs.
file "$PLUGIN"
readelf -h "$PLUGIN" | sed -n 's/.*Machine: */termux-cross: machine /p'
readelf -d "$PLUGIN" | sed -n 's/.*Shared library: \[\(.*\)\]/termux-cross: needs \1/p'

# These three are matched on the captured output rather than through
# `... | grep -q x`, because a pipeline whose reader exits early leaves the
# writer with SIGPIPE -- and under `set -o pipefail` that non-zero status has
# nothing to do with whether the symbol was found.
needed="$(readelf -d "$PLUGIN" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')"
dynsyms="$(readelf --dyn-syms -W "$PLUGIN")"

case "$needed" in
    *libLLVM*)
        note "ok:     declares libLLVM" ;;
    *)
        die "the plugin declares no libLLVM dependency -- was it built against Termux's libLLVM.so?" ;;
esac
case "$needed" in
    *omp*) die "the plugin links libomp, which does not exist on Termux" ;;
esac
case "$dynsyms" in
    *__kmpc_*|*omp_get_*) die "the plugin pulled in OpenMP symbols" ;;
esac

# The host registers the LLVM command-line options; a static LLVM inside the
# plugin would make opt abort with "Option registered more than once".
n_cmdline="$(nm -D --defined-only "$PLUGIN" | awk '{print $NF}' |
             grep -c '^_ZN4llvm.*\(cl::opt\|CommandLine\)' || true)"
[[ "$n_cmdline" == "0" ]] ||
    die "a static LLVM leaked into the plugin ($n_cmdline CommandLine definitions)"
note "ok:     no OpenMP, no static LLVM"

nm -D --undefined-only "$PLUGIN" | awk '{print $NF}' | sed 's/@.*//' | sort -u \
    > "$WORK_DIR/plugin-undef.txt"
nm -D --defined-only "$PREFIX/lib/libLLVM.so" | awk '{print $NF}' | sed 's/@.*//' | sort -u \
    > "$WORK_DIR/llvm-defined.txt"
comm -23 "$WORK_DIR/plugin-undef.txt" "$WORK_DIR/llvm-defined.txt" \
    > "$WORK_DIR/plugin-missing.txt" || true
missing_llvm="$(grep -c '^_ZN4llvm\|^_ZNK4llvm\|^_ZTVN4llvm\|^_ZTI4llvm\|^_ZTSN4llvm\|^llvm' \
    "$WORK_DIR/plugin-missing.txt" || true)"
note "symbols: $(wc -l < "$WORK_DIR/plugin-undef.txt") undefined, $missing_llvm unresolved by libLLVM.so"
if [[ "$missing_llvm" != "0" ]]; then
    grep '^_ZN4llvm\|^_ZNK4llvm\|^_ZTVN4llvm\|^_ZTI4llvm\|^_ZTSN4llvm\|^llvm' \
        "$WORK_DIR/plugin-missing.txt" >&2
    die "the plugin needs LLVM symbols Termux's libLLVM.so does not export"
fi

if [[ "$DO_PACKAGE" == "1" ]]; then
    HIKARI_PLUGIN="$PLUGIN" \
    VERSION="$VERSION" \
    DEB_ARCH="$DEB_ARCH" \
    OUT_DIR="$OUT_DIR" \
        "$SELF_DIR/package-deb.sh"
    note "package: $OUT_DIR/hikari_${VERSION}_${DEB_ARCH}.deb"
fi

note "done -- this plugin was cross-compiled, so it has not run on a device;"
note "      tools/termux/build.sh is the on-device build"
