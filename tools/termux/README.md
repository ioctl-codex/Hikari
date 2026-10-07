# Hikari on Termux

Termux is not another name for arm64 Linux. Its packages install under
`$PREFIX` (`/data/data/com.termux/files/usr`) on Bionic, and — the part that
decides everything here — its `llvm` package is **LLVM 21.1.8**, not 22.

LLVM has no stable plugin ABI, so the LLVM that loads the plugin has to be the
LLVM the plugin was built against. There is no version to declare: a plugin
built for LLVM 22 loaded by an LLVM 21 host aborts with *"Option registered more
than once"*. On Termux that means **the plugin has to be built for LLVM 21**,
which the source supports — it builds against 21, and `smoke-test.sh` passes on
it (14/14, seeded sweep included).

## Building it on the device

This is the path to prefer: it links against the exact `libLLVM.so` that will
load it, and against the exact `libc++` it will share a process with.

```bash
pkg install llvm libllvm clang cmake ninja git

git clone https://github.com/ioctl-codex/Hikari ~/Hikari
cd ~/Hikari
./tools/termux/build.sh --install
```

`pkg install libllvm` is what supplies the headers (`$PREFIX/include/llvm`) and
`$PREFIX/lib/libLLVM.so`; there is no separate `-dev` package to install. `opt`
comes from `llvm`.

After `--install`:

```bash
hikari-clang -O0 hello.c -o hello            # obfuscated
HIKARI_OBF=0 hikari-clang -O0 hello.c -o hi  # one clean build, to compare
```

The driver resolves its plugin, its `opt` and its runtime relative to itself, so
the `$PREFIX/bin/hikari-clang` symlink is all that has to be on `PATH`. Every
knob from the main README applies: `HIKARI_PASSES`, `HIKARI_SEED`,
`HIKARI_OPT_LEVEL`, `HIKARI_VERBOSE`, `HIKARI_OBF`.

## Packaging it as a `.deb`

```bash
./tools/termux/build.sh
./tools/termux/package-deb.sh
# -> dist/hikari_1.0.0_aarch64.deb
```

Unlike the Debian/Ubuntu package, this one **does not carry an `opt` or a
`libLLVM`**. On Termux both are already installed at the right version, and
shipping a second copy of `libLLVM` is the fastest way to get two LLVMs into one
process — the one failure mode that makes the plugin refuse to load. It declares
`Depends: clang, llvm, libllvm, libc++` instead.

## The prebuilt `.deb`, and what it is worth

A release also ships `hikari_<version>_aarch64.deb`, cross-compiled against the
headers and the `libLLVM.so` taken straight out of Termux's own
[`libllvm`](https://packages.termux.dev/apt/termux-main/) package for `aarch64`:

* the headers are Termux's, so `llvm/Config/llvm-config.h` states Termux's build
  configuration rather than some other distributor's;
* it links against Termux's `libLLVM.so` (`soname: libLLVM.so`), which is the
  library `$PREFIX/bin/opt` itself loads, so the loader satisfies it from the
  process's own mapping;
* every undefined symbol it leaves is resolved by `libLLVM.so`, `libc++_shared`,
  `libc.so`, `libm.so` and `libdl.so` as Termux ships them.

That is as far as verification goes without a phone. It has **not** been run on
a Termux device, which is why the on-device build above exists and is the
supported route. Treat the prebuilt package as a convenience: if it works, fine;
if it does not, `./tools/termux/build.sh --install` is the answer, and it is a
two-command answer.

## Why not just cross-compile against an Ubuntu LLVM 21?

Because the headers carry the build configuration. `llvm-config.h` and
`abi-breaking.h` decide RTTI, exceptions and ABI-breaking checks, and a plugin
compiled against a build with different answers has a different idea of the
layout of the objects it hands to LLVM. Termux's own headers are the ones that
match Termux's own library.
