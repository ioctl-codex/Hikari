# Hikari Android Toolchain

Drop-in Android NDK toolchain that runs every C/C++ translation unit through the
Hikari LLVM 22 pass pipeline (BCF, CFF, substitution, split, string/constant
encryption, indirect branch, FCO, anti-debug, anti-hook, VMP).

```bash
# --full archive: nothing else to install, not even an NDK
export PATH=/path/to/hikari-android-toolchain/bin:$PATH

aarch64-linux-android24-clang -O0 -c foo.c -o foo.o          # obfuscated
aarch64-linux-android24-clang -O0 foo.c -o foo.arm64

# --slim archive: point at your own NDK first
export HIKARI_NDK=/path/to/android-ndk-r29
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

* **--full archive:** a Linux x86_64 host, and nothing else — clang, lld, the
  clang resource directory and the Android sysroot travel inside the archive.
  (`HIKARI_NDK` is ignored when one is bundled; set it only to override.)
* **--slim archive:** an Android NDK (r26+; r29 tested) at `HIKARI_NDK`. Only
  `toolchains/llvm/prebuilt/*` is used.
* The packaged `llvm/bin/opt` (LLVM 22), or set `HIKARI_OPT` to any LLVM 22 `opt`.
* macOS/Windows hosts can drive the slim archive with their own NDK; the bundled
  clang in `--full` is a Linux x86_64 build.

## Layout

```
hikari-android-toolchain-full/
  bin/hikari-clang                     # the 3-stage driver
  bin/aarch64-linux-android24-clang    # generated: NDK-named target wrappers
  bin/aarch64-linux-android24-clang++  # (plus armv7a / i686 / x86_64, all API levels)
  lib/libHikari.so                     # the pass plugin (LLVM 22)
  llvm/bin/opt                         # LLVM 22 opt that loads the plugin
  llvm/lib/libLLVM.so.22*              # its runtime — nothing to install
  ndk/toolchains/llvm/prebuilt/*/      # (--full only) clang 21, lld, resource
                                       # dir, libc++, sysroot for the 4 ABIs
  examples/                            # C samples
  BUILD-INFO.txt                       # shape, versions, sysroot ABIs
```

## Environment

| Variable | Meaning |
|---|---|
| `HIKARI_NDK` | Android NDK directory. Optional in a `--full` package (its own NDK is used), optional if `HIKARI_CC` is set; otherwise required. |
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

Then the differential stress gate, which is where most bugs in this fork were
found — it runs the cross product of every sample, every pass on its own, the
shipped pipelines and several PRNG seeds, and compares stdout, stderr and exit
status against the clean build:

```bash
LLVM_PREFIX=/usr/lib/llvm-22 HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/stress/stress-test.sh
# HIKARI_STRESS_SEEDS="1 2 3"        seeds to sweep (default 1 2 3 4)
# HIKARI_STRESS_SAMPLES="memory"     restrict the samples
# HIKARI_STRESS_SETS="vmp=enable-vmp" restrict the pass sets
# HIKARI_STRESS_JOBS=2               parallelism — keep it small on a low-RAM host,
#                                    one virtualization cell can want a gigabyte
```

Package a relocatable toolchain — `--full` carries an NDK, `--slim` does not:

```bash
HIKARI_NDK=$NDK LLVM_PREFIX=/usr/lib/llvm-22 \
HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/android-toolchain/package-toolchain.sh --full
  # -> dist/hikari-android-toolchain-full.tar.xz

HIKARI_NDK=$NDK LLVM_PREFIX=/usr/lib/llvm-22 \
HIKARI_PLUGIN=build/obfuscation/libHikari.so \
  ./tools/android-toolchain/package-toolchain.sh --slim
  # -> dist/hikari-android-toolchain-slim.tar.xz
```

`STRIP=none` keeps the symbols in `opt`/`libLLVM` (bigger archive, readable
backtraces); `NDK_ABIS` picks which sysroot ABIs `--full` bundles.

Both archives are verified before release. The check unpacks the archive **under
a different name** (a path baked in at packaging time would fail), runs with a
scrubbed environment (`env -i`, no `HIKARI_NDK`, no repo) and compiles
`examples/neg_idx.c` for every ABI the package ships, asserting the object is
that ABI's ELF, that `vmp_ch_*` handlers are present, and that a `HIKARI_OBF=0`
build of the same file has none:

```bash
./tools/android-toolchain/verify-package.sh dist/hikari-android-toolchain-full.tar.xz
HIKARI_NDK=$NDK ./tools/android-toolchain/verify-package.sh dist/hikari-android-toolchain-slim.tar.xz
```

## Handing IR from LLVM 22 back to clang 21

Text IR hides most of the version gap, but not all of it, and real C++ findsthe rest. Every item below was measured, not guessed, on a 3700-line C++17
translation unit (exceptions, RTTI, libc++, Android system headers) compiled
for `aarch64-linux-android21` with NDK r29's clang 21.0.0 obfuscating through
LLVM 22.1.8:

* **Bitcode out of stage 2 is not readable by stage 3.** LLVM's bitcode reader
  goes one way, and stage 2 is the newer tool; a module carrying debug info dies
  with `error: Invalid record`, and even without it the writer emits attribute
  kinds the older reader rejects (`Unknown attribute kind (105)`). Both are
  avoided by keeping every hand-off textual — which is why stage 1 emits `.ll`
  too.
* **Two attribute spellings still have to be stripped.** `target_memN: none`
  (a location LLVM 21 has never heard of) and `nocreateundeforpoison` (a name
  added after LLVM 21) both fail the LLVM 21 parser with `unterminated attribute
  group`. Note that attributes inside a group are separated by **spaces**, so a
  pattern anchored on a leading comma misses every token that is not first.
* **`-O2` in stage 3 crashes clang 21.** The obfuscated module can contain IR
  that LLVM 21's own passes do not survive; `sroa<modify-cfg>` died with a null
  deref on an inline `android::detail::String8(char const*)` that had been faked
  out of a system header. Stage 3 therefore always codegens at `-O0` — nothing
  is lost, because stage 1 already ran the requested `-O` level.
* **`enable-indibran` only works for single-translation-unit links.** The pass
  records the address of each function it rewrites in
  `.data..LIndirectBranchingGlobalTable`, including weak/COMDAT inline functions
  from the C++ standard library. Linking two obfuscated objects then fails:
  `ld.lld` discards the duplicate COMDAT (the prevailing copy lives in the other
  object) while the table still relocates into it —
  `relocation refers to a discarded section`. Use `enable-cffobf` instead, or
  obfuscate a single TU, or keep the pass for a final link that only ever sees
  one obfuscated object.

## Provenance

The plugin is upstream [PPKunOfficial/Hikari-fix](https://github.com/PPKunOfficial/Hikari-fix)
(Hikari-LLVM22) with these changes:

* `-lwinpthread` no longer leaks out of the Windows branch.
* The plugin links `libLLVM.so` instead of the static component archives, so the
  host does not abort with *"Option registered more than once"*.
* `ConstantEncryption` no longer encrypts a global whose address escapes. The
  pass encrypts an initializer and inserts the matching XOR at every load and
  store; `ptrtoint @g` — which is how the virtualizer captures a global into its
  data section, but also a plain `int *p = &g` — read the raw bytes and saw the
  encrypted value. `vmp_add`'s `vmp_global` returned `14 * 0x57A4B4E1` instead
  of 42 under `enable-constenc`. Such globals are now left unencrypted instead
  of silently miscompiled.
* The VMP interpreter sign-extends GEP displacements and cast sources from the
  *source* width. It used to zero-extend a GEP's byte offset (`p - 1` became
  `p + 0xFFFFFFFF`) and to read the sign bit of `sext` from the destination
  width, so a virtualized `p[i]` with a negative run-time index produced a wild
  pointer. `samples/c/neg_idx.c` gates it.
* The VMP interpreter evaluates unsigned opcodes with zero-extended operands.
  It used to sign-extend both operands of every binary op, which made
  `udiv`/`urem`/`lshr` — and every shift count — observe the operand's high bit
  as data (`udiv i32 0x80000000, 4` was computed as
  `udiv i64 0xFFFFFFFF80000000, 4`). Obfuscated functions therefore disagreed
  with their originals whenever a pass drew such an operand, which for BCF's
  opaque predicates was most of the time: the virtualized recursion never
  terminated. `smoke-test.sh` section 4 sweeps fixed seeds so this cannot come
  back unnoticed.
