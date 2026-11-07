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
| `scripts/check-x86_64-install.sh` | **new** (optional) | Simulates `customize.sh`'s install-time gates against a built zip, plus a CRLF byte-check of every shipped script |

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

## 7. Debugging a blank Action screen (action.sh)

The manager shows only an action script's stdout and **discards stderr**, so
any prelude failure used to leave the Action screen black with nothing to go
on — that is exactly what an x86_64 install hit. `action.sh` now has three
layers against it:

1. **Trace file (always on).** Every prelude step appends a timestamped line
   to `/data/adb/tricky_store/alwaysstrong/tmp/action.trace`. The file is
   truncated at the start of each tap (by the first, unlocked process only —
   the lock helper's inner run and any fallback append) and survives a shell
   dying mid-way. Read it with:
   `adb shell cat /data/adb/tricky_store/alwaysstrong/tmp/action.trace`
   or tap `action.sh logs` — `collect_logs.sh` includes the trace as
   `--- action.trace (prelude debug ...)`.
2. **No silent exits.** `as_store.sh` missing/unloadable and the
   required-function check now print to **stdout** (the visible channel) and
   exit non-zero.
3. **Lock helper preflight + unlocked fallback.** Before the action is handed
   to `asfetch lock-run`, a probe runs `asfetch lock-run <probe.flock> 0 true`
   and checks the exit code. Anything other than 0/75 (wrong-arch ELF, blocked
   exec, stale install — rc 126/127 style) prints three warning rows and runs
   the action **unlocked** instead of exiting silently. The same fallback
   covers a lock-run that fails after the probe (the inner run writes an
   `action.started` stamp; no stamp + non-zero rc = retry unlocked).

On a healthy device the visible Action output is byte-identical to upstream;
the trace file is the only addition.

CI note: the required-function error moved from stderr to stdout, so
`tests/test_action_shell.py` asserts `result.stdout` now — apply the updated
test together with the updated `action.sh`, or the unittest step fails.

### 7.1 The one failure no script can self-diagnose: CRLF line endings

Every failure above happens *inside* the running script, so the trace and
stdout rows can report it. One failure happens **before any code runs**: if
`action.sh` carries Windows CRLF (`\r\n`) line endings, the shell dies at
parse time and even line 2 never executes — no output, no trace file, black
Action screen. The manager log (KernelSU app) shows the fingerprint:

```
/data/adb/modules/tricky_store/action.sh: line 4:
: not found
/data/adb/modules/tricky_store/action.sh: line 5: syntax error: unexpected word (expecting "in")
```

Line 4 of `action.sh` is a blank line — with CRLF it becomes a lone `\r`,
which the shell tries to *execute* as a command name (invisible, hence the
empty `: not found`). Line 5 is `case "$0" in` — with CRLF the keyword
becomes `in\r`, which ash no longer recognizes, hence `expecting "in"`.
Any two errors of that shape (`: not found` on a blank line + `unexpected
word (expecting "in")` on a `case`/`for` line) are CRLF, regardless of the
exact line numbers.

The repo, CI builds and shipped zips are LF-clean (`.gitattributes` forces
LF checkouts, `build.sh` step 6 strips CR at staging,
`check-x86_64-install.sh` byte-checks the zip). This failure therefore comes
from **editing scripts on the device** with an editor or clipboard round-trip
that saves CRLF.

Fix in place (root shell, no reflash needed):

```sh
cd /data/adb/modules/tricky_store
cp action.sh action.sh.bak
sed -i 's/\r$//' action.sh          # strip CR from every line
tr -cd '\r' < action.sh | wc -c     # must print 0
/data/adb/ksu/bin/busybox sh -n action.sh && echo SYNTAX_OK
```

Then tap Action again. To confirm the diagnosis before fixing:
`od -c action.sh | head` — CRLF shows as `\r  \n` pairs; a clean file shows
only `\n`. The same fix applies to any module script (`service.sh`, …).

Prevention when hand-tuning on device:

- Prefer `adb push` of a repo file over on-device editing — the repo is
  LF-enforced, the device is not.
- Pasting through a root shell heredoc (`cat > action.sh <<'EOF' … EOF`) is
  safe: an interactive terminal translates CR to NL on input.
- Editors like MT Manager preserve a file's existing endings; Windows
  editors (Notepad, some IDE defaults) do not — never round-trip module
  scripts through one.
- For a durable fix, commit the updated `module/action.sh` from this folder
  and rebuild: the always-on trace (`…/alwaysstrong/tmp/action.trace`) then
  covers every future prelude failure without hand edits.
