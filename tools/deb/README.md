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

## Architectures

The package architecture is whatever architecture the LLVM it wraps is, so it is
built once per target:

| Target | `DEB_ARCH` | Notes |
|---|---|---|
| Ubuntu / Debian x86_64 | `amd64` | the CI artifact |
| Ubuntu / Debian arm64 | `arm64` | needs an aarch64 `llvm-22` + `opt` to wrap |
| Termux (Android, aarch64) | `aarch64` | Termux packages are a different shape — see below |

### Termux

Termux is not a second name for arm64 Debian: its packages install under
`$PREFIX` (`/data/data/com.termux/files/usr`) and its `llvm` package is **LLVM
21.1.8**, not 22. A plugin built for LLVM 22 cannot be loaded by Termux's `opt`,
so a Termux package has to be built against Termux's own LLVM — which in turn
means building the plugin against LLVM 21 (`-DLT_LLVM_INSTALL_DIR` pointing at a
21 install passes the gates; the CMake version check allows 21 on purpose) and
driving it from `$PREFIX/bin/opt`. On a Termux device that is a local build,
because Termux ships no LLVM development headers to cross-compile against.

## Dependencies at build time

The packager needs `dpkg-deb`, `readelf`, `ldd` and optionally `llvm-strip`
(from `llvm-22-tools`); `STRIP=none` keeps the symbols in `opt` and `libLLVM`
at the cost of roughly 40 MB per archive.
