# x86_64 build support

This fork builds and runs on **x86_64 Android** (emulators, Chromebooks,
x86_64 phones/boards) alongside the existing arm64/armv7 releases. The two
lines covered are **inject** (fully native on x86_64) and **fork** (everything
except the PIF fingerprint spoof, which upstream does not build for x86_64 —
see [Limitations](#limitations)).

## 1. What upstream already gives x86_64 (verified against the pins)

Checked by downloading the exact zips pinned in `build.sh` and
`module-variants/*/build.conf` and listing their contents:

| Pinned component | Tag | x86_64 payload |
| --- | --- | --- |
| TEESimulator-RS (Enginex0) | `v6.0.1-307` | `lib/x86_64/libTEESimulator.so`, `libinject.so`, `libsupervisor.so` |
| PlayIntegrityFix inject-s (KOWX712) | `v4.9-inject-s` | `zygisk/x86_64.so` |
| PlayIntegrityFork (osm0sis CI #623) | CI build | **none** — `zygisk/arm64-v8a.so` + `zygisk/armeabi-v7a.so` only |
| aswatcher (committed prebuilts) | — | `native/watcher/prebuilt/x86_64/aswatcher` already in git |
| asfetch (committed prebuilts) | — | **none** — arm only by design (see below) |

So the attestation engine (TEESimulator-RS), the inject line's PIF zygisk and
the watcher are x86_64-ready out of the box. Two things blocked x86_64:

1. **`customize.sh` aborted the install.** It hard-requires
   `bin/$ABI_DIR/asfetch` and `abort`s when missing — and asfetch was built
   for arm only. Result: *no x86_64 module could install at all*, regardless
   of variant.
2. **Runtime scripts treated x86_64 as `unsupported`.**
   `repair_runtime.sh` (used by `as_store`, `service`, `post-fs-data`,
   `keybox_validate`, `soter_diagnose` for every locked settings write) and
   `verdict_report.sh` mapped `uname -m` = x86_64 to
   `bin/unsupported/asfetch`, so settings writes were refused and checker
   imports crashed even if the module had installed.

Everything else already handled x86_64: `keybox_fetch.sh`,
`pif_native_fetch.sh`, `beta_pif.sh`, `action.sh` and `collect_logs.sh` map
x86_64 and fall back from asfetch to curl; `service.sh` launches the x86_64
aswatcher; `attest/tee.sh` installs `lib/x86_64/*` payloads.

## 2. What this mod set changes

Designed so future upstream syncs stay conflict-free: **two new files + three
tiny in-file hooks.** Full replacement copies of every touched file are in
this folder; `changes.diff` shows the exact lines.

| File | Status | Change |
| --- | --- | --- |
| `.github/workflows/build-x86_64.yml` | **new** | Separate workflow: syntax check → host asfetch build + cargo tests + module test suite (same as upstream `build.yml` runs before unittest) → build x86_64 asfetch → build `inject` + `fork` with `--build-tag x86_64` → `verify-module-zip.py` → per-zip ABI report → artifact upload |
| `scripts/build-asfetch-x86_64.sh` | **new** | Cross-compiles asfetch for `x86_64-linux-android` (API 29) into `native/asfetch/prebuilt/x86_64/`. Direct cargo + NDK clang (no cargo-ndk), same RUSTFLAGS path-hygiene as `build-asfetch.sh` |
| `build.sh` | 1 line | `ASFETCH_ABIS=(arm64-v8a armeabi-v7a ${ASFETCH_ABIS_EXTRA:-})` — stages an x86_64 asfetch only when the x86_64 workflow asks for it; stock arm behavior untouched |
| `module/repair_runtime.sh` | 2 lines | `x86_64` / `i?86` branches in the `uname -m` case |
| `module/verdict_report.sh` | 2 lines | `x86_64` / `i?86` branches, plus a graceful "no native parser" exit instead of a crash when the parser is absent |
| `scripts/check-x86_64-install.sh` | **new** (optional) | Simulates `customize.sh`'s install-time gates against a built zip |

Nothing else is touched: no `customize.sh` change is needed because the x86_64
zip ships its own `bin/x86_64/asfetch`, so the existing install gate passes as
is. The release workflow (`release.yml`) is untouched — it still publishes
exactly the four arm zips; the x86_64 line uploads its own separately named
artifact (`AlwaysStrongFork-module-zip-x86_64`).

## 3. Using it

### GitHub Actions (the intended path)

Copy the files in this folder into the repo preserving paths, commit, push.
The workflow runs on every push to `main`, on PRs, and on demand from the
Actions tab. Each run publishes a **`AlwaysStrongFork-module-zip-x86_64`**
artifact containing:

- `AlwaysStrong-v<ver>-x86_64-inject.zip` — PlayIntegrityFix inject-s + TEESimulator-RS, fully working on x86_64
- `AlwaysStrong-v<ver>-x86_64.zip` — PlayIntegrityFork line: TEESimulator-RS + keybox + repair stack on x86_64, PIF spoof arm-only (see below)
- `SHA256SUMS-x86_64.txt`

The build tag (`--build-tag x86_64`) lands in `module.prop` as
`version=v<ver> (x86_64)`, so the manager shows which build you run and the
zip names never collide with the arm releases.

To also attach x86_64 zips to a release, download the artifact and:
`gh release upload <tag> AlwaysStrong-*x86_64*.zip --clobber`.

### Locally

```bash
rustup target add x86_64-linux-android
export ANDROID_NDK_HOME=/path/to/ndk
bash scripts/build-asfetch-x86_64.sh
find native -path '*/prebuilt/*' -type f -exec touch {} +
export ASFETCH_ABIS_EXTRA=x86_64
bash build.sh --variant inject --build-tag x86_64
bash build.sh --variant fork   --build-tag x86_64
python3 scripts/verify-module-zip.py out/AlwaysStrong-*x86_64*.zip
```

## 4. Verified results

Validated end-to-end on Linux x86_64 with NDK r27c (the same toolchain the
workflow pins) against the pinned upstream zips:

- `scripts/build-asfetch-x86_64.sh` → ELF 64-bit x86-64 PIE, Android 29,
  NDK r27c, stripped, no host-path leakage, `lock-run`/`run-bounded` present.
- `build.sh --variant inject,fork --build-tag x86_64` → both zips built;
  stock `scripts/verify-module-zip.py` passes on both.
- Install-gate simulation (`check-x86_64-install.sh`, ARCH=x64): all checks
  pass for both zips — asfetch present (no abort), aswatcher, TEESimulator
  `lib/x86_64/*`, inject zygisk `x86_64.so` present in the inject zip.
- Runtime check with `uname -m` = x86_64: `repair_runtime.sh` `as_lock_run`
  and `as_bounded` succeed; `verdict_report.sh` proceeds when the parser
  exists and skips gracefully when it does not.
- Python suite: 86/86 verified end-to-end with the exact CI sequence
  (`cargo build --locked` host asfetch → `cargo test` asfetch/watcher →
  `unittest` with `mksh` on PATH).

## 5. Limitations

- **Fork line on x86_64: no fingerprint spoof.** The pinned
  osm0sis/PlayIntegrityFork CI build ships arm zygisk libraries only. The
  fork x86_64 zip still carries them (Zygisk ignores non-matching ABIs), and
  `customize.sh` prints the standard "no PIF zygisk for x86_64" warning. The
  TEESimulator-RS attestation, keybox fetcher, watcher and repair runtime all
  work. For a spoofing x86_64 module use the **inject** build. If osm0sis
  ever publishes an x86_64 zygisk, the fork line picks it up with no further
  changes (`build.sh` copies whatever ABIs the pinned zip contains).
- **No `update.json` manifest for x86_64.** The manager's update check points
  at the arm zips. x86_64 builds are fetched from the Actions artifacts (or
  manually attached to a release).
- **`--engine teesim` (JingMatrix) stays arm64-only** in release builds; it
  already supports `TEESIM_ABIS="arm64-v8a x86_64"` for a local build.
- **Isolation module** (`scripts/build-isolation.sh`) still compiles
  arm64/armv7 only. Optional one-line addition if ever needed: append
  `'x86_64-linux-android:x86_64'` to the spec list in that script.
- 32-bit `x86` is mapped in the runtime case branches but ships no asfetch
  (32-bit emulators are rare; curl fallback still works there).

## 6. Why ship an x86_64 asfetch at all?

`build-asfetch.sh` documents that x86_64 emulators have working curl, so
stock skips it to save ~1.2 MB. That trade is wrong for an x86_64 *module*:
`customize.sh` aborts the whole install when `bin/$ABI_DIR/asfetch` is
missing, and `repair_runtime.sh` refuses every locked settings write without
it. Shipping the 1.2 MB binary is what turns "installs and half-degrades"
into "installs and fully works" — while stock arm builds keep their current
contents byte-for-byte.
