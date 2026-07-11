#!/usr/bin/env bash
#
# ipp-usb/mayhem/test.sh — RUN OpenPrinting/ipp-usb's OWN Go test suite (`go test .`) and emit a
# CTRF summary. exit 0 iff no test failed.
#
# SCOPE: ipp-usb is a single-package (`package main`) project; ALL its _test.go files (glob_test,
# inifile_test, ipp_test, paper_test, quirks_test, tcpuid_test, usbcommon_test, uuid_test,
# addpdl_test) live at the repo root and are self-contained (no real USB hardware / dnssd
# daemon / network needed — pure logic, known-input -> known-output). These are real
# known-answer suites: e.g. TestNewIppAttrs decodes a fixed goipp.Attributes set and asserts the
# EXACT resulting attribute list; TestGlobMatch asserts glob-pattern match counts against a fixed
# table; TestUsbAddrListDiff asserts the exact added/removed sets from two USB address lists. A
# no-op / `return nil` patch that breaks IPP-attribute filtering, glob matching, or the USB
# address bookkeeping FAILS this oracle.
#
# Anti-reward-hack (SPEC §6.3): ipp-usb is cgo (libusb/avahi) but its TEST BINARY is still built
# by `go test`, which links Go's runtime statically — LD_PRELOAD cannot intercept it directly. We
# run the tests through mayhem-build/test-runner, a thin dynamically-linked C shim (built by
# build.sh). The sabotage check (LD_PRELOAD _exit(0) for non-system binaries) intercepts the C
# shim itself, which then never exec()s `go test` → no output → fewer tests counted → detected.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/mayhem-build/test-runner"

# The C shim (dynamically linked, interceptable by LD_PRELOAD) exec()s `go test -json -count=1 .`
# for ipp-usb's root package. When sabotaged, the shim gets _exit(0) → no output → oracle detects.
# Fall back to calling go test directly if the shim is missing.
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"

if [ -x "$RUNNER" ]; then
  echo "=== running: test-runner (go test -json -count=1 shim, interceptable by LD_PRELOAD) ==="
  "$RUNNER" > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
  grep -v '"Action":"output"' "$JSON" 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try:
        ev = json.loads(line.strip())
        if ev.get("Action") in ("pass","fail","skip") and ev.get("Test"):
            print(ev["Action"].upper(), ev.get("Test",""))
        elif ev.get("Action") in ("pass","fail") and not ev.get("Test"):
            print("Package:", ev.get("Action").upper())
    except: pass
' 2>/dev/null | tail -40 || true
  [ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -5 "$SRC/mayhem-build/gotest.err"; }
elif command -v go >/dev/null 2>&1; then
  echo "=== running: go test -json (fallback — not LD_PRELOAD-interceptable) ==="
  go test -count=1 -json . > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
  go test -count=1 . 2>&1 | tail -40 || true
  [ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -5 "$SRC/mayhem-build/gotest.err"; }
else
  echo "neither test-runner nor go available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — they
# are real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
