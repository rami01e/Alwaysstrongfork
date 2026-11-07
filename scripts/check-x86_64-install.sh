#!/usr/bin/env bash
# Simulate the install-time ABI decision path of module/customize.sh +
# attest/tee.sh against a built module zip, for ARCH=x64 (x86_64 device).
# Usage: bash check-x86_64-install.sh <module.zip> <expect-zygisk:yes|no>
set -euo pipefail
ZIP="$1"
EXPECT_ZYGISK="$2"
ABI_DIR="x86_64"   # customize.sh: x64 -> x86_64

fail=0
LIST="$(unzip -l "$ZIP" 2>/dev/null || true)"   # capture once: grep -q on a pipe
                                                # SIGPIPEs unzip under pipefail
check() { # <desc> <pattern> <expect-present:yes|no>
    local desc="$1" pat="$2" want="$3"
    if grep -q "$pat" <<< "$LIST"; then got=yes; else got=no; fi
    if [ "$got" = "$want" ]; then
        echo "  PASS  $desc"
    else
        echo "  FAIL  $desc (got $got, want $want)"; fail=1
    fi
}

echo "== install-time checks for $(basename "$ZIP") (ARCH=x64) =="
# customize.sh asfetch gate: aborts when bin/$ABI_DIR/asfetch is absent
check "asfetch present for $ABI_DIR (customize.sh abort gate)" "bin/$ABI_DIR/asfetch" yes
check "aswatcher present for $ABI_DIR" "bin/$ABI_DIR/aswatcher" yes
# attest/tee.sh attest_install: lib/$ABI_DIR payloads
check "TEESimulator lib for $ABI_DIR"      "lib/$ABI_DIR/libTEESimulator.so" yes
check "inject payload for $ABI_DIR"        "lib/$ABI_DIR/libinject.so"       yes
check "supervisor payload for $ABI_DIR"    "lib/$ABI_DIR/libsupervisor.so"   yes
# PIF zygisk per-ABI extraction loop
if [ "$EXPECT_ZYGISK" = yes ]; then
    check "PIF zygisk x86_64.so (spoof works)" "zygisk/x86_64.so" yes
else
    check "PIF zygisk x86_64.so (upstream arm-only)" "zygisk/x86_64.so" no
fi
check "classes.dex present" "classes.dex" yes
check "tee_classes.dex present" "tee_classes.dex" yes

# CRLF byte-check. Android's sh treats \r as a real character: one CRLF line
# in action.sh kills the whole file at parse time — the Action button goes
# black with "line N: : not found" plus "syntax error: unexpected word
# (expecting \"in\")", and NO script code runs (not even line 2, so the
# action.trace never appears). The build strips CR at staging (build.sh
# step 6) and .gitattributes forces LF checkouts; this is the last line of
# defense against a hand-edited or hand-re-zipped artifact.
echo "== CRLF check (shipped scripts must be LF-only) =="
while IFS= read -r f; do
    n=$(unzip -p "$ZIP" "$f" | tr -cd '\r' | wc -c)
    if [ "$n" -eq 0 ]; then
        echo "  PASS  LF-only  $f"
    else
        echo "  FAIL  $f has $n CR byte(s) — rebuild the zip; never hand-edit it"; fail=1
    fi
done < <(unzip -Z1 "$ZIP" '*.sh' 'META-INF/*/update-binary' 'META-INF/*/updater-script' 'daemon' 2>/dev/null)

echo ""
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "CHECKS FAILED"; exit 1; fi
