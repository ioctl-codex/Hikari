#!/usr/bin/env bash
#
# build-deb.sh — wrap a built libHikari.so and its LLVM 22 runtime in a Debian
# package that installs under /usr/lib/hikari.
#
# Layout inside the package:
#
#   /usr/lib/hikari/bin/hikari-clang         the 3-stage driver
#   /usr/lib/hikari/lib/libHikari.so         the pass plugin
#   /usr/lib/hikari/llvm/bin/opt             the LLVM 22 opt that loads it
#   /usr/lib/hikari/llvm/lib/libLLVM.so.22*  opt's runtime
#   /usr/lib/hikari/examples/*.c             runnable samples
#   /usr/bin/hikari-clang                    symlink into the tree above
#   /usr/share/doc/hikari/                   README, VMP.md, copyright, changelog
#
# Why the package carries its own opt + libLLVM
#   LLVM has no stable plugin ABI.  A plugin built for LLVM 22 loaded by an
#   LLVM 21 host aborts on duplicate CommandLine registration, so "depend on
#   whatever llvm the distribution ships" is not a dependency to declare — it
#   is a version that has to match, and only the package can guarantee it.
#   Carrying opt + libLLVM also makes the .deb work on a machine with no LLVM
#   at all, which is the same reason the Android toolchain archives bundle
#   theirs.  Everything else (libz3, libxml2, the C++ runtime) is declared in
#   Depends against the distribution, where the sonames are stable.
#
# hikari-clang resolves its pieces relative to itself: ../lib for the plugin,
# ../llvm/bin/opt for opt and ../llvm/lib for the runtime.  Installing the tree
# under /usr/lib/hikari is therefore enough to make the driver work from any
# path, with no configuration.
#
# Usage:
#   LLVM_PREFIX=/usr/lib/llvm-22 \
#   HIKARI_PLUGIN=build/obfuscation/libHikari.so \
#     ./tools/deb/build-deb.sh
#
# Env:
#   LLVM_PREFIX      LLVM 22 install prefix holding bin/opt (required)
#   HIKARI_PLUGIN    libHikari.so (required)
#   VERSION          package version (default: 1.0.0)
#   OUT_DIR          where the .deb is written (default: <repo>/dist)
#   DEB_ARCH         package architecture (default: dpkg --print-architecture)
#   MAINTAINER       Maintainer: field (default: the repository's own)
#   STRIP            strip(1) for opt/libLLVM (default: llvm-strip, then strip;
#                    "none" keeps the symbols)

set -euo pipefail

die() { printf 'build-deb: %s\n' "$*" >&2; exit 1; }
note() { printf 'build-deb: %s\n' "$*" >&2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

LLVM_PREFIX="${LLVM_PREFIX:-}"
HIKARI_PLUGIN="${HIKARI_PLUGIN:-}"
VERSION="${VERSION:-1.0.0}"
OUT_DIR="${OUT_DIR:-$HIKARI_ROOT/dist}"
MAINTAINER="${MAINTAINER:-Hikari <noreply@github.com/ioctl-codex/Hikari>}"
STRIP="${STRIP:-}"

[[ -n "$LLVM_PREFIX" && -d "$LLVM_PREFIX" ]] || die "set LLVM_PREFIX to an LLVM 22 prefix (e.g. /usr/lib/llvm-22)"
[[ -x "$LLVM_PREFIX/bin/opt" ]] || die "$LLVM_PREFIX/bin/opt not found"
[[ -n "$HIKARI_PLUGIN" && -f "$HIKARI_PLUGIN" ]] || die "set HIKARI_PLUGIN to the built libHikari.so"
[[ -f "$SELF_DIR/../android-toolchain/hikari-clang" ]] ||
    die "tools/android-toolchain/hikari-clang not found next to this script"

# ------------------------------------------------------------- architecture ---
# Prefer dpkg's own answer (it is what the package manager will compare
# against); fall back to the ELF machine of the plugin so the script still
# works where dpkg is absent.
if [[ -n "${DEB_ARCH:-}" ]]; then
    ARCH="$DEB_ARCH"
elif command -v dpkg >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture)"
else
    arch=""
    for f in "$HIKARI_PLUGIN" "$LLVM_PREFIX/bin/opt"; do
        [[ -z "$arch" ]] || break
        case "$(readelf -h "$f" 2>/dev/null | sed -n 's/.*Machine: *//p')" in
            *X86-64*)  arch=amd64 ;;
            *AArch64*) arch=arm64 ;;
            *ARM*)     arch=armhf ;;
            *386*)     arch=i386 ;;
        esac
    done
    [[ -n "$arch" ]] || die "could not determine the architecture; set DEB_ARCH"
    ARCH="$arch"
fi

NAME=hikari
STAGE="$OUT_DIR/${NAME}_${VERSION}_${ARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/lib/hikari/bin" \
         "$STAGE/usr/lib/hikari/lib" \
         "$STAGE/usr/lib/hikari/llvm/bin" \
         "$STAGE/usr/lib/hikari/llvm/lib" \
         "$STAGE/usr/lib/hikari/examples" \
         "$STAGE/usr/share/doc/$NAME"

# --------------------------------------------------------------- the files ---
cp "$HIKARI_PLUGIN" "$STAGE/usr/lib/hikari/lib/"
cp "$SELF_DIR/../android-toolchain/hikari-clang" "$STAGE/usr/lib/hikari/bin/hikari-clang"
chmod 755 "$STAGE/usr/lib/hikari/bin/hikari-clang"

cp "$LLVM_PREFIX/bin/opt" "$STAGE/usr/lib/hikari/llvm/bin/opt"
chmod 755 "$STAGE/usr/lib/hikari/llvm/bin/opt"

# opt's runtime: libLLVM and nothing else — its remaining NEEDED entries are
# declared in Depends below, where the distribution keeps them current.
copied_libs=0
while read -r lib; do
    [[ -f "$lib" ]] || continue
    cp -L "$lib" "$STAGE/usr/lib/hikari/llvm/lib/" && copied_libs=$((copied_libs + 1))
done < <(ldd "$LLVM_PREFIX/bin/opt" 2>/dev/null | awk '/=>/ {print $3}' | grep -E 'libLLVM' || true)
[[ "$copied_libs" -gt 0 ]] || die "no libLLVM copied from $LLVM_PREFIX/bin/opt"

# The plugin's own libLLVM must be the *same file* as opt's, or the host loads
# two copies of LLVM and aborts with "Option registered more than once" — the
# exact failure this package exists to avoid.  Fail loudly on a mismatch
# instead of shipping a .deb that cannot work.
soname() { readelf -d "$1" 2>/dev/null | sed -n 's/.*SONAME.*\[\(libLLVM[^]]*\)\].*/\1/p' | head -1; }
plugin_needs="$(sed -n 's/.*NEEDED.*\[\(libLLVM[^]]*\)\].*/\1/p' <<<"$(readelf -d "$HIKARI_PLUGIN" 2>/dev/null || true)" | head -1)"
if [[ -z "$plugin_needs" ]]; then
    note "warning: the plugin declares no libLLVM dependency (statically linked?)"
else
    found=""
    for cand in "$STAGE"/usr/lib/hikari/llvm/lib/*; do
        [[ "$(soname "$cand")" == "$plugin_needs" ]] && { found="$cand"; break; }
    done
    [[ -n "$found" ]] ||
        die "the plugin needs $plugin_needs but opt's runtime does not provide it —
      both must come from the same LLVM build ($LLVM_PREFIX)"
fi

# The loader looks up the SONAME (libLLVM.so.22), not the file's real name
# (libLLVM.so.22.1), so the version chain has to be symlinked explicitly.
for lib in "$STAGE"/usr/lib/hikari/llvm/lib/libLLVM.so.*.*; do
    [[ -f "$lib" ]] || continue
    base="$(basename "$lib")"                 # libLLVM.so.22.1
    major="${base%.*}"                        # libLLVM.so.22
    ln -sf "$base" "$STAGE/usr/lib/hikari/llvm/lib/$major"
done

strip_llvm() {
    local strip_bin="$STRIP"
    if [[ "$strip_bin" == "none" ]]; then
        note "STRIP=none — keeping opt/libLLVM symbols"
        return 0
    fi
    [[ -n "$strip_bin" ]] || strip_bin="$(command -v llvm-strip || command -v strip || true)"
    [[ -n "$strip_bin" ]] || { note "warning: no strip found, package stays large"; return 0; }

    local f
    for f in "$STAGE/usr/lib/hikari/llvm/bin/opt" "$STAGE"/usr/lib/hikari/llvm/lib/libLLVM.so.*.*; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        if "$strip_bin" --strip-unneeded "$f" -o "$f.tmp" 2>/dev/null && [[ -s "$f.tmp" ]] &&
           chmod --reference="$f" "$f.tmp" 2>/dev/null; then
            mv "$f.tmp" "$f"
        else
            rm -f "$f.tmp"
        fi
    done
}
strip_llvm

# Examples and docs travel with the package: the driver's own smoke test uses
# them, and a package nothing can be tried against is a package nobody trusts.
cp "$HIKARI_ROOT"/samples/c/*.c "$STAGE/usr/lib/hikari/examples/" 2>/dev/null || true
cp "$SELF_DIR/README.md" "$STAGE/usr/lib/hikari/README.md"
cp "$HIKARI_ROOT/README.md" "$STAGE/usr/share/doc/$NAME/README.md"
[[ -f "$HIKARI_ROOT/docs/VMP.md" ]] && cp "$HIKARI_ROOT/docs/VMP.md" "$STAGE/usr/share/doc/$NAME/VMP.md"
cp "$SELF_DIR/README.md" "$STAGE/usr/share/doc/$NAME/deb.md"
[[ -f "$HIKARI_ROOT/LICENSE" ]] && cp "$HIKARI_ROOT/LICENSE" "$STAGE/usr/share/doc/$NAME/copyright"

{
    echo "shape: native .deb ($ARCH)"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "llvm-prefix: $LLVM_PREFIX"
    echo "llvm-version: $("$LLVM_PREFIX/bin/opt" --version 2>/dev/null | head -2 | tail -1)"
    echo "plugin: $(basename "$HIKARI_PLUGIN")"
    [[ -n "${GIT_COMMIT_HASH:-}" ]] && echo "commit: $GIT_COMMIT_HASH"
} > "$STAGE/usr/lib/hikari/BUILD-INFO.txt"

ln -sf ../lib/hikari/bin/hikari-clang "$STAGE/usr/bin/hikari-clang"

# ------------------------------------------------------------ debian control ---
# Depends is the runtime half of what is *not* bundled: libLLVM needs libz3,
# libxml2, libffi, libedit, zlib and zstd, and libxml2 in turn pulls libicu.
# All of those have stable names and sonames on Debian and Ubuntu; z3 does not
# (the package name tracks its own version), hence the alternatives.
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Section: devel
Priority: optional
Homepage: https://github.com/ioctl-codex/Hikari
Recommends: clang
Depends: libc6 (>= 2.35), libstdc++6, libgcc-s1, libffi8, libedit2, zlib1g,
 libzstd1, libxml2, libz3-4 | libz3-5 | libz3-4.13 | libz3-4.12 | libz3-dev
Description: LLVM 22 obfuscation pass plugin for opt and rustc nightlies
 Hikari is an out-of-tree LLVM pass plugin that adds bogus control flow,
 control-flow flattening, instruction substitution, basic-block splitting,
 string and constant encryption, indirect branches, function-call obfuscation,
 anti-debugging, anti-hooking and full IR virtualization (a private bytecode
 plus a stack-resident interpreter) to unoptimized IR.
 .
 The plugin loads into an LLVM 22 host -- opt, or rustc nightly -- and needs no
 rebuild of LLVM itself.  This package installs a self-contained copy of that
 host, so it works on a machine with no LLVM installed.
 .
 The hikari-clang driver compiles a source file to IR, runs the pass pipeline
 over it and codegens the result in a separate step: only text IR crosses
 between the stages, which is what lets a plugin built for one LLVM version
 obfuscate code compiled by an older clang.
EOF

# changelog must be gzip and syntactically valid, or lintian and dpkg-genchanges
# both object.
mkdir -p "$STAGE/usr/share/doc/$NAME"
{
    printf '%s (%s) unstable; urgency=medium\n\n' "$NAME" "$VERSION"
    printf '  * Package the LLVM 22 obfuscation plugin with its own opt and\n'
    printf '    libLLVM runtime, plus the hikari-clang driver.\n\n'
    printf ' -- %s  %s\n' "$MAINTAINER" "$(date -R)"
} > "$STAGE/usr/share/doc/$NAME/changelog.Debian"
gzip -9n "$STAGE/usr/share/doc/$NAME/changelog.Debian"

# dpkg refuses a package whose files are not listed here.
(
    cd "$STAGE"
    find usr -type f ! -path 'usr/share/doc/*/changelog.Debian.gz' -print0 |
        sort -z | xargs -0 md5sum > DEBIAN/md5sums
)

# A maintainer script that runs after unpack and says what was installed; the
# alternative (silence) is how a user ends up with a package and no idea how to
# call it.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    configure)
        if ! command -v clang >/dev/null 2>&1; then
            echo "hikari: no 'clang' on PATH -- hikari-clang needs one as its" >&2
            echo "        front end.  Install clang, or set HIKARI_CC=/path/to/clang." >&2
        fi
        ;;
esac
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

# ------------------------------------------------------------------ build -----
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found"

deb="$OUT_DIR/${NAME}_${VERSION}_${ARCH}.deb"
rm -f "$deb"
dpkg-deb --build --root-owner-group "$STAGE" "$deb" || die "dpkg-deb --build failed"

printf 'build-deb: wrote %s\n' "$deb"
du -sh "$STAGE" "$deb" >&2
