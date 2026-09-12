# Hikari Android Toolchain

Drop-in Android NDK toolchain that runs every C/C++ translation unit through the
Hikari LLVM 22 pass pipeline (BCF, CFF, substitution, split, string/constant
encryption, indirect branch, FCO, anti-debug, anti-hook, VMP).

```bash
export HIKARI_NDK=/path/to/android-ndk-r29
export PATH=/path/to/hikari-android-toolchain/bin:$PATH

aarch64-linux-android24-clang -O0 -c foo.c -o foo.o          # obfuscated
aarch64-linux-android24-clang -O0 foo.c -o foo.arm64
```

## Why a wrapper instead of `-fpass-plugin`

The plugin is built against **LLVM 22**. Android NDK r29 ships **clang 21**, and
LLVM has no stable plugin ABI: a plugin built for one major version cannot be
loaded by another (the host aborts on duplicate `CommandLine` registration when
two LLVM copies end up in one process). Rebuilding clang for Android just to
match a plugin version is not worth it, so `hikari-clang` splits the compile:

| Stage | Tool | LLVM |
|---|---|---|
| 1 | `<ndk>/bin/clang -emit-llvm -c` | 21 — produces bitcode |
| 2 | `opt-22 -load-pass-plugin=libHikari.so --passes=hikari(…)` | 22 — obfuscates IR |
| 3 | `<ndk>/bin/clang <obf>.bc -o out.o` / link | 21 — codegen + link |

Only **bitcode** crosses the version boundary, and LLVM reads bitcode produced
by older releases. The result is an ordinary NDK artifact — same target triple,
same ABI, same sysroot, same runtime — the IR just ran through Hikari on the way.

`enable-vmp` is applied inside `opt`, so virtualization works for Android
targets exactly as it does for desktop.

## Requirements

* An Android NDK (r26+; r29 tested). Only `toolchains/llvm/prebuilt/*` is used.
* The packaged `llvm/bin/opt` (LLVM 22) — bundled in the release tarball, or set
  `HIKARI_OPT` to any LLVM 22 `opt`.
* Linux x86_64, macOS x86_64/arm64 or Windows (Git Bash) hosts.

## Layout

```
hikari-android-toolchain/
  bin/hikari-clang                     # the 3-stage driver
  bin/aarch64-linux-android24-clang    # generated: NDK-named target wrappers
  bin/aarch64-linux-android24-clang++  # (plus armv7a / i686 / x86_64, all API levels)
  lib/libHikari.so                     # the pass plugin (LLVM 22)
  llvm/bin/opt                         # LLVM 22 opt that loads the plugin
  llvm/lib/libLLVM.so.22*              # its runtime — nothing to install
  examples/                            # C samples
```

## Environment

| Variable | Meaning |
|---|---|
| `HIKARI_NDK` | Android NDK directory. Required by the generated wrappers, optional if `HIKARI_CC` is set. |
| `HIKARI_CC` | Explicit clang to use. Use it to obfuscate non-Android targets too. |
| `HIKARI_PLUGIN` | `libHikari.so`. Defaults to `../lib/`, then the repo's `build/obfuscation/`. |
| `HIKARI_OPT` | LLVM 22 `opt`. Defaults to `../llvm/bin/opt`, then `opt-22`, then `opt`. |
| `HIKARI_PASSES` | Pipeline, default `hikari(enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran,enable-fco)`. |
| `HIKARI_OPT_LEVEL` | Optimization level for the bitcode stage, default `-O0` (Hikari targets `-O0` IR). |
| `HIKARI_SEED` | Integer PRNG seed (`-aesSeed`). Every pass draws from this generator; left unset it is the wall clock, so each build obfuscates differently. Pin it for byte-reproducible output and to replay a failure. |
| `HIKARI_OBF` | `0`/`off` → pass through to plain clang (useful for one clean build). |
| `HIKARI_VERBOSE` | `1` → print every stage command. |

Stage 1 also injects `-Xclang -disable-O0-optnone`, without which LLVM skips
passes on `-O0` functions and nothing gets obfuscated.

## CMake / Gradle

Point the compiler at the generated wrappers; no other build change is needed:

```bash
# CMake
cmake -DCMAKE_C_COMPILER=/path/hikari-android-toolchain/bin/aarch64-linux-android24-clang \
      -DCMAKE_CXX_COMPILER=/path/hikari-android-toolchain/bin/aarch64-linux-android24-clang++ \
      -DCMAKE_TOOLCHAIN_FILE=$HIKARI_NDK/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 ..
```

```groovy
// build.gradle — per-ABI compiler selection
android {
  defaultConfig {
    externalNativeBuild {
      cmake {
        arguments "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-24"
      }
    }
  }
  externalNativeBuild { cmake { path "CMakeLists.txt" } }
}
```

```make
# Android.mk
NDK_TOOLCHAIN_DIR := /path/hikari-android-toolchain/bin
LOCAL_CC := $(NDK_TOOLCHAIN_DIR)/aarch64-linux-android24-clang
LOCAL_CXX := $(NDK_TOOLCHAIN_DIR)/aarch64-linux-android24-clang++
```

CI verifies every release by compiling `samples/c/*.c` for `aarch64-linux-android24`,
checking the output is an AArch64 ELF containing the virtualized `vmp_ch_*`
handlers, and by running the obfuscated vs clean host build and diffing stdout.

## What the wrapper does and does not touch

Handled: `-c` compiles, compile+link in one command, multiple sources, `-x`,
dependency flags (`-MD/-MMD/-MF/-MT/-MQ`) which stay on the source stage, and
`.bc`/`.ll` inputs (obfuscated directly).

Passed through untouched: preprocess/syntax-only (`-E`, `-M`, `-fsyntax-only`,
`-print-*`), pure link lines (`.o`/`.a`/`.so`/`.s`), and `HIKARI_OBF=0`.

Rejected with a warning: `-flto`, which moves codegen into the linker and would
silently skip the IR pipeline. Build those units without the wrapper.

## Rebuilding the plugin

```bash
cmake -G Ninja -S . -B build \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
      -DLT_LLVM_INSTALL_DIR=/usr/lib/llvm-22
cmake --build build -j

# local smoke test
HIKARI_NDK=$NDK HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/android-toolchain/hikari-clang -c samples/c/hello.c -o /tmp/hello.o
```

On Debian/Ubuntu the LLVM 22 packages needed are `llvm-22-dev`, `libclang-cpp22-dev`
and `libclang-common-22-dev` — the last one carries `stddef.h` and the rest of
clang's builtin headers, without which the host `-emit-llvm` stage of the smoke
test cannot include `<stdio.h>`.

Run the full gate (host round-trip, Android AArch64 output, seeded sweep):

```bash
HIKARI_NDK=$NDK LLVM_PREFIX=/usr/lib/llvm-22 \
HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/android-toolchain/smoke-test.sh
```

Package a relocatable toolchain:

```bash
HIKARI_NDK=$NDK LLVM_PREFIX=/usr/lib/llvm-22 \
HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/android-toolchain/package-toolchain.sh
# -> dist/hikari-android-toolchain.tar.gz
```

## Provenance

The plugin is upstream [PPKunOfficial/Hikari-fix](https://github.com/PPKunOfficial/Hikari-fix)
(Hikari-LLVM22) with these changes:

* `-lwinpthread` no longer leaks out of the Windows branch.
* The plugin links `libLLVM.so` instead of the static component archives, so the
  host does not abort with *"Option registered more than once"*.
* The VMP interpreter evaluates unsigned opcodes with zero-extended operands.
  It used to sign-extend both operands of every binary op, which made
  `udiv`/`urem`/`lshr` — and every shift count — observe the operand's high bit
  as data (`udiv i32 0x80000000, 4` was computed as
  `udiv i64 0xFFFFFFFF80000000, 4`). Obfuscated functions therefore disagreed
  with their originals whenever a pass drew such an operand, which for BCF's
  opaque predicates was most of the time: the virtualized recursion never
  terminated. `smoke-test.sh` section 4 sweeps fixed seeds so this cannot come
  back unnoticed.
