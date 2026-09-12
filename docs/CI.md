# CI

Every gate lives in a script, so a human, a local runner and a hosted runner all
run the same thing — the workflows only decide *where*.

| Gate | Script | What it proves |
|---|---|---|
| Smoke test | `tools/android-toolchain/smoke-test.sh` | The plugin loads, and obfuscated binaries still print what the clean ones print — host, AArch64, a `-g`/DWARF case, and 16 seeded re-runs |
| Differential stress | `tools/stress/stress-test.sh` | Sample × pass × seed matrix, every pass on its own, output compared to the clean build |
| Cross-ABI execution | `tools/stress/cross-run.sh` | The obfuscated Android binaries are *run* under qemu (aarch64, armv7a), not merely compiled |
| Package verification | `tools/android-toolchain/verify-package.sh` | `dist/*.tar.xz` works unpacked on a machine with no NDK and no system LLVM |
| Subset sweep | `tools/stress/subset-sweep.sh` | Diagnostic: bisects a pass-interaction bug to the smallest reproducing pass set |

Env they all read: `HIKARI_PLUGIN`, `HIKARI_OPT` (LLVM 22 `opt`), `HIKARI_CC`
(host clang), `HIKARI_NDK`.

## GitHub

`.github/workflows/ci.yml` runs the full list, including packaging. It is
currently dormant: GitHub returns `422 Actions has been disabled for this user`
for the account, which is account-level, not repository-level, and no email or
notification was sent. Support has to lift it; until then a push produces no run
and pushes missed during the outage do not run retroactively.

## Codeberg

`.forgejo/workflows/ci.yml` mirrors the same gates. Two things to set up:

1. **Enable Actions for the repository.** Repository settings → *Units* → check
   *Enable Actions*. Nothing runs until this is on.
2. **Give it a runner.** The `gates` and `release` jobs ask for `self-hosted`
   (`runs-on: self-hosted`) on purpose — see the limits below. The `lint` job is
   happy on a Codeberg-hosted runner.

### Declaring the toolchain on a self-hosted runner

The `gates` and `package` jobs take the toolchain from the runner's environment
and never install one that is already there. The Forgejo runner reads
`<runner dir>/.env` at startup, which is where to declare it:

```ini
LLVM_PREFIX=<llvm>/lib/cmake/llvm's parent   # for -DLT_LLVM_INSTALL_DIR
HIKARI_OPT=<llvm>/bin/opt                    # the LLVM 22 opt that loads the plugin
LD_LIBRARY_PATH=<dir with libLLVM.so.22.1>   # only if opt has no rpath to it
HIKARI_CC=<ndk>/toolchains/llvm/prebuilt/linux-x86_64/bin/clang
HIKARI_NDK=<ndk>
HIKARI_STRESS_JOBS=1                         # opt is memory-hungry; 1 on a small box
```

`LLVM_PREFIX` must be the tree that has **both** `bin/opt` and `lib/cmake/llvm`:
the jobs build the plugin against it, and a tree made by `package-toolchain.sh`
has the first without the second. The workflow checks for both before it starts,
so a wrong path fails in seconds instead of after a build.

Nothing machine-specific belongs in the workflow's `env:` block. A workflow-level
variable overrides what the runner exports, so declaring the toolchain there would
hide the runner's own and re-download a gigabyte per push.

### Why the heavy jobs ask for `self-hosted`

Codeberg's shared runners cap a job's wall clock and memory:

| Label | CPU | RAM | Runtime |
|---|---|---|---|
| `codeberg-tiny` | 1 | 2 GB | 2 min |
| `codeberg-small` | 2 | 4 GB | 5 min |
| `codeberg-medium` | 4 | 8 GB | 10 min |

The RAM quote counts filesystem writes as well. Installing LLVM 22 and building
the plugin already spends most of a 10-minute budget, before the NDK download,
the seeded sweep or the qemu matrix start — so pointing those jobs at a shared
label would mean a workflow that always times out, which is worse than a workflow
that says so. Register your own runner instead
(<https://docs.codeberg.org/ci/actions/>) on a machine that already has the
toolchain; the jobs skip the LLVM/NDK installs when the tools are present.

### Pushing, and the release job

```bash
git remote add codeberg https://codeberg.org/<you>/Hikari.git
git push codeberg master --tags
```

Releases need a token with `write:repository`:

- **Browser:** Codeberg → *Settings* → *Applications* → create a token.
- **CLI:**
  ```bash
  fj auth add-token --host https://codeberg.org   # paste the token at the prompt
  ```
  `fj auth login` (browser flow) also works. `fj` is `forgejo-cli`; the release
  job uses `fj release create` / `fj release asset create`, so the same token
  can publish `dist/*.tar.xz` and `libHikari.so` by hand:

  ```bash
  fj release create v0.1 --tag v0.1 \
    --attach dist/hikari-android-toolchain-full.tar.xz \
    --attach dist/hikari-android-toolchain-slim.tar.xz \
    --attach build/obfuscation/libHikari.so \
    --host https://codeberg.org --repo <you>/Hikari
  ```

In the workflow the token is the `CODEBERG_TOKEN` repository secret.
