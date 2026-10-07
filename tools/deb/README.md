# Hikari Debian package

`build-deb.sh` wraps a built `libHikari.so` and the LLVM 22 host that loads it in
a `.deb`, so the obfuscator can be installed instead of assembled by hand.

```bash
LLVM_PREFIX=/usr/lib/llvm-22 \
HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/deb/build-deb.sh
# -> dist/hikari_1.0.0_amd64.deb
```

## What lands where

| Path | What it is |
|---|---|
| `/usr/lib/hikari/bin/hikari-clang` | the 3-stage driver (see `tools/android-toolchain/README.md`) |
| `/usr/lib/hikari/lib/libHikari.so` | the pass plugin, LLVM 22 |
| `/usr/lib/hikari/llvm/bin/opt` | the LLVM 22 `opt` that loads the plugin |
| `/usr/lib/hikari/llvm/lib/libLLVM.so.22*` | its runtime, found through `LD_LIBRARY_PATH` set by the driver |
| `/usr/lib/hikari/examples/*.c` | the sample programs, ready to compile |
| `/usr/bin/hikari-clang` | symlink to the driver |
| `/usr/share/doc/hikari/` | README, VMP.md, deb.md, copyright, changelog |

## Use

```bash
hikari-clang -O0 -c hello.c -o hello.o          # obfuscated object
hikari-clang -O0 hello.c -o hello                # compile and link in one go
HIKARI_OBF=0 hikari-clang -O0 hello.c -o clean   # one unobfuscated build
```

`hikari-clang` picks its own plugin, `opt` and runtime from `../` relative to
itself, so no environment variable is needed when it is called through
`/usr/bin/hikari-clang`. The environment knobs in
`tools/android-toolchain/README.md` all still apply (`HIKARI_PASSES`,
`HIKARI_SEED`, `HIKARI_OPT_LEVEL`, `HIKARI_VERBOSE`, `HIKARI_OBF`).

For the equivalent without the driver:

```bash
opt-22 -load-pass-plugin=/usr/lib/hikari/lib/libHikari.so \
       --passes='hikari(enable-bcfobf,enable-cffobf)' in.ll -o out.ll
```

## Why the package carries its own opt and libLLVM

LLVM has no stable plugin ABI, and this is not a dependency that can be
declared loosely: a plugin built for LLVM 22 loaded by an LLVM 21 host aborts
with *"Option registered more than once"*, and a host one major out of step
with the plugin is a build that fails at load time rather than at compile time.
Bundling `opt` and the matching `libLLVM` is what makes the package work on a
machine that has no LLVM at all — the same trade the Android toolchain archives
make. Everything else is declared in `Depends`, where the distribution keeps
the sonames current:

```
libc6 (>= 2.35), libstdc++6, libgcc-s1, libffi8, libedit2,
zlib1g, libzstd1, libxml2, libz3-4
```

`libLLVM` links `libz3` and `libxml2` for its own optional features; `libxml2`
in turn pulls `libicu`, which is why it is named rather than assumed. The
package is built on glibc 2.35 (Ubuntu 22.04), so it installs on Ubuntu 22.04
and newer and on Debian 12 and newer.

## Verifying a package

```bash
sudo ./tools/deb/verify-deb.sh dist/hikari_1.0.0_amd64.deb
```

Installs the package, drives the samples through `/usr/bin/hikari-clang` and
compares each obfuscated program's output against a clean build, then removes
the package and fails if anything was left behind. It is the same check CI runs,
and the reason to run it is that a package nobody has unpacked is a package
nobody has tested.

## Architectures

The package architecture is whatever architecture the LLVM it wraps is, so it is
built once per target. The release ships `amd64` and `arm64`; `amd64` is built
natively, and arm64 by `build-deb-arm64.sh`, which does the whole thing:

```bash
sudo ./tools/deb/build-deb-arm64.sh      # -> dist/hikari_1.0.0_arm64.deb
```

It bootstraps an arm64 Ubuntu chroot under `qemu-user-static`, installs LLVM 22
inside it, builds the plugin, packages it, and then installs and *runs* the
result in the chroot — which is the only way to exercise an arm64 build on an
x86_64 machine. A chroot rather than a cross-compile because an installed
`LLVMExports.cmake` bakes in absolute paths, and the plugin has to link against
the same `libLLVM` the host `opt` loads; inside the chroot both sides are the
real thing at the real paths, so nothing has to be patched.

It needs root (debootstrap, chroot, and the `/dev` bind mount that process
substitution needs inside a chroot) and takes ten to twenty minutes, most of it
qemu. Re-running is cheap: the emulated plugin build is keyed on a hash of the
sources it compiles, so a change to the docs or to these scripts does not cost
another one.

Termux is a third shape and has its own tooling — see
[`tools/termux/README.md`](../termux/README.md). It is **not** the arm64 package
above: its packages install under `$PREFIX`
(`/data/data/com.termux/files/usr`), and its `llvm` package is **LLVM 21.1.8**,
not 22, so a plugin built for LLVM 22 cannot be loaded by Termux's `opt` at all.

## Dependencies at build time

The packager needs `dpkg-deb`, `readelf`, `ldd` and optionally `llvm-strip`
(from `llvm-22-tools`); `STRIP=none` keeps the symbols in `opt` and `libLLVM`
at the cost of roughly 40 MB per archive.
