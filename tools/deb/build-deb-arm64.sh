#!/usr/bin/env bash
#
# build-deb-arm64.sh — build the arm64 .deb inside an arm64 chroot.
#
# Why a chroot and not a cross-compile: LLVMExports.cmake bakes in absolute
# paths, and the plugin has to link against the same libLLVM the `opt` in the
# package will load.  Inside the chroot both sides are the real thing at the
# real paths, so nothing has to be patched -- and the finished package can be
# installed and *run* there, under emulation, which is the only way to exercise
# an arm64 build on an x86_64 machine.
#
# Needs root: debootstrap, chroot and the bind mounts below all do.  CI runs it
# with sudo.  Expect ten to twenty minutes, most of it qemu.
#
# Usage:
#   sudo ./tools/deb/build-deb-arm64.sh
#   sudo ARCHROOT=/opt/arm64 ./tools/deb/build-deb-arm64.sh
#
# Env:
#   ARCHROOT     the chroot's location (default: /opt/hikari-arm64-chroot)
#   DISTRO       the Ubuntu suite to bootstrap (default: jammy)
#   LLVM_SUITE   the apt.llvm.org suite (default: llvm-toolchain-jammy-22)
#   OUT_DIR      where the .deb is written (default: <repo>/dist)
#   VERSION      package version (default: 1.0.0)
#   REBUILD      set to 1 to rebuild the plugin even if one is already there

set -euo pipefail

# The chroot inherits this, and so does everything built inside it.  A packaging
# script that leaves the umask to the caller is one dpkg-deb rejection away from
# failing on a machine it was never run on.
umask 022

die() { printf 'arm64-deb: %s\n' "$*" >&2; exit 1; }
note() { printf 'arm64-deb: %s\n' "$*" >&2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIKARI_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

ARCHROOT="${ARCHROOT:-/opt/hikari-arm64-chroot}"
DISTRO="${DISTRO:-jammy}"
LLVM_SUITE="${LLVM_SUITE:-llvm-toolchain-jammy-22}"
LLVM_VER="${LLVM_VER:-22}"
OUT_DIR="${OUT_DIR:-$HIKARI_ROOT/dist}"
VERSION="${VERSION:-1.0.0}"
REBUILD="${REBUILD:-0}"
LLVM_PREFIX_INSIDE="/usr/lib/llvm-$LLVM_VER"

[[ "$(id -u)" == "0" ]] || die "run this as root (debootstrap, chroot, mount)"
[[ -f "$SELF_DIR/build-deb.sh" ]] || die "build-deb.sh not next to this script"

REV="$(git -C "$HIKARI_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
# The plugin only depends on the sources and the top-level CMakeLists, so keying
# the rebuild decision on those means a docs or tools commit does not cost
# another qemu build.
SRC_KEY="$(
    cd "$HIKARI_ROOT"
    { find obfuscation -type f -print0; printf 'CMakeLists.txt\0'; } |
        sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
)"
note "revision: $REV"
note "source key: ${SRC_KEY:0:16}..."

export DEBIAN_FRONTEND=noninteractive

echo "===== [1/7] host tooling ====="
apt-get install -y --no-install-recommends \
    qemu-user-static debootstrap binfmt-support ca-certificates curl gnupg file

echo "===== [2/7] arm64 $DISTRO (first stage) ====="
if [[ ! -d "$ARCHROOT/etc" ]]; then
    debootstrap --arch=arm64 --foreign "$DISTRO" "$ARCHROOT" \
        http://ports.ubuntu.com/ubuntu-ports
fi
cp -f /usr/bin/qemu-aarch64-static "$ARCHROOT/usr/bin/" 2>/dev/null || true

echo "===== [3/7] arm64 $DISTRO (second stage, under qemu) ====="
if [[ -x "$ARCHROOT/debootstrap/debootstrap" ]]; then
    chroot "$ARCHROOT" /debootstrap/debootstrap --second-stage
fi

echo "===== [4/7] /dev, /proc and /sys inside the chroot ====="
# A debootstrap chroot has /dev/fd as an empty directory, so the kernel's
# /dev/fd/N aliases do not resolve and any process substitution -- `cmd < <(...)`
# -- dies with "/dev/fd/63: No such file or directory".  dpkg and build-deb.sh
# both use it.  Bind-mounting the host's /dev fixes that; dpkg and the postinst
# also expect /proc and /sys.
for m in dev proc sys; do
    if ! mountpoint -q "$ARCHROOT/$m"; then
        mount --rbind "/$m" "$ARCHROOT/$m"
        mount --make-rslave "$ARCHROOT/$m"
    fi
done
chroot "$ARCHROOT" bash -c 'exec 9< <(echo process substitution works); cat <&9'

echo "===== [5/7] apt sources and LLVM $LLVM_VER in the chroot ====="
cat > "$ARCHROOT/etc/apt/sources.list" <<EOF
deb http://ports.ubuntu.com/ubuntu-ports $DISTRO main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $DISTRO-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $DISTRO-security main restricted universe multiverse
EOF
printf '#!/bin/sh\nexit 101\n' > "$ARCHROOT/usr/sbin/policy-rc.d"
chmod +x "$ARCHROOT/usr/sbin/policy-rc.d"

# Dearmor on the host: a debootstrap chroot has no gnupg, and that is the only
# reason this is not done inside it.  --batch --yes because there is no tty here
# and gpg otherwise refuses to overwrite, or waits for an answer it cannot get.
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /tmp/arm64-llvm.key
mkdir -p "$ARCHROOT/etc/apt/trusted.gpg.d"
rm -f "$ARCHROOT/etc/apt/trusted.gpg.d/apt.llvm.org.gpg"
gpg --batch --yes --dearmor \
    -o "$ARCHROOT/etc/apt/trusted.gpg.d/apt.llvm.org.gpg" < /tmp/arm64-llvm.key
chmod 644 "$ARCHROOT/etc/apt/trusted.gpg.d/apt.llvm.org.gpg"
echo "deb [signed-by=/etc/apt/trusted.gpg.d/apt.llvm.org.gpg] \
http://apt.llvm.org/$DISTRO/ $LLVM_SUITE main" \
    > "$ARCHROOT/etc/apt/sources.list.d/llvm.list"

# The chroot inherits the host's resolver so this container-level DNS works.
cp -f /etc/resolv.conf "$ARCHROOT/etc/resolv.conf" 2>/dev/null || true

chroot "$ARCHROOT" apt-get update -qq
chroot "$ARCHROOT" apt-get install -y --no-install-recommends \
    "llvm-$LLVM_VER-dev" "libclang-common-$LLVM_VER-dev" "clang-$LLVM_VER" \
    "libclang-cpp$LLVM_VER-dev" cmake ninja-build ca-certificates file
chroot "$ARCHROOT" "$LLVM_PREFIX_INSIDE/bin/opt" --version > /tmp/arm64-opt.txt
head -2 /tmp/arm64-opt.txt

echo "===== [6/7] build the plugin inside the chroot ====="
BUILT_KEY="$(cat "$ARCHROOT/hikari/.built-key" 2>/dev/null || true)"
if [[ -s "$ARCHROOT/hikari/build/obfuscation/libHikari.so" &&
      "$BUILT_KEY" == "$SRC_KEY" && "$REBUILD" != "1" ]]; then
    note "plugin already built from these sources; keeping it (REBUILD=1 to force)"
else
    rm -rf "$ARCHROOT/hikari"
    mkdir -p "$ARCHROOT/hikari"
    tar -C "$HIKARI_ROOT" --exclude=.git --exclude=build --exclude=dist \
        --exclude=build-termux --exclude=build-termux-cross --exclude='samples/out' \
        -cf - . | tar -C "$ARCHROOT/hikari" -xf -
    chroot "$ARCHROOT" bash -c "
set -euxo pipefail
cd /hikari
export PATH=$LLVM_PREFIX_INSIDE/bin:\$PATH
cmake -G Ninja -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
      -DLT_LLVM_INSTALL_DIR=$LLVM_PREFIX_INSIDE
cmake --build build -j\$(nproc)
ls -la build/obfuscation/libHikari.so
file build/obfuscation/libHikari.so
"
    printf '%s\n' "$SRC_KEY" > "$ARCHROOT/hikari/.built-key"
fi

echo "===== [7/7] package it, then install and run it ====="
chroot "$ARCHROOT" bash -c "
set -euxo pipefail
cd /hikari
export PATH=$LLVM_PREFIX_INSIDE/bin:\$PATH
export LLVM_PREFIX=$LLVM_PREFIX_INSIDE
export HIKARI_PLUGIN=\$PWD/build/obfuscation/libHikari.so
export VERSION=$VERSION
export DEB_ARCH=arm64
export OUT_DIR=\$PWD/dist
export GIT_COMMIT_HASH=$REV
./tools/deb/build-deb.sh
ls -la dist/*.deb
dpkg-deb -I dist/hikari_${VERSION}_arm64.deb > /tmp/control.txt
head -10 /tmp/control.txt

echo '--- install it in the chroot ---'
dpkg -r hikari 2>/dev/null || true
dpkg -i dist/hikari_${VERSION}_arm64.deb
ls -la /usr/bin/hikari-clang

echo '--- and run it, under emulation ---'
export HIKARI_CC=$LLVM_PREFIX_INSIDE/bin/clang
rm -rf /tmp/smoke && mkdir -p /tmp/smoke && cd /tmp/smoke
cp /usr/lib/hikari/examples/hello.c .
hikari-clang -O0 hello.c -o hello-obf 2>/dev/null
$LLVM_PREFIX_INSIDE/bin/clang -O0 hello.c -o hello-clean
# hello.c exits non-zero on purpose (it prints 'access denied'), so the samples'
# exit status must not be allowed to end this script under set -e.  The outputs
# are what is compared.
set +e
./hello-obf > obt.txt 2>/dev/null; a=\$?
./hello-clean > cln.txt 2>/dev/null; b=\$?
set -e
echo \"exit codes: obf=\$a clean=\$b\"
diff obt.txt cln.txt && echo 'IDENTICAL OK'

HIKARI_PASSES='hikari(enable-vmp,enable-cffobf)' HIKARI_SEED=7 \\
    hikari-clang -O0 /usr/lib/hikari/examples/vmp_add.c -o v-obf 2>/dev/null
$LLVM_PREFIX_INSIDE/bin/clang -O0 /usr/lib/hikari/examples/vmp_add.c -o v-clean
set +e
./v-obf > vo.txt 2>/dev/null; va=\$?
./v-clean > vc.txt 2>/dev/null; vb=\$?
set -e
echo \"exit codes: obf=\$va clean=\$vb\"
diff vo.txt vc.txt && echo 'VMP IDENTICAL OK'
cat vo.txt

echo '--- the produced binaries really are arm64 ---'
file hello-obf hello-clean v-obf

echo '--- remove, and check nothing is left behind ---'
dpkg -r hikari
"

mkdir -p "$OUT_DIR"
deb="$ARCHROOT/hikari/dist/hikari_${VERSION}_arm64.deb"
[[ -s "$deb" ]] || die "no package at $deb"
cp -f "$deb" "$OUT_DIR/"
note "wrote $OUT_DIR/$(basename "$deb")"
sha256sum "$OUT_DIR/$(basename "$deb")"

for m in sys proc dev; do umount -R "$ARCHROOT/$m" 2>/dev/null || true; done
note "done"
