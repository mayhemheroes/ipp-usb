#!/usr/bin/env bash
#
# ipp-usb/mayhem/build.sh — build OpenPrinting/ipp-usb's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's projects/ipp-usb/build.sh (which delegates to
# OpenPrinting/fuzzing's oss_fuzz_build.sh):
#
#   compile_native_go_fuzzer ./fuzzer FuzzUSBLayer         fuzz_usb_layer
#   compile_native_go_fuzzer ./fuzzer FuzzHTTPClient       fuzz_http_client
#   compile_native_go_fuzzer ./fuzzer FuzzDaemonIntegration fuzz_daemon_integration
#
# All three are NATIVE Go fuzz harnesses `func FuzzX(f *testing.F)` (package `fuzzer`, vendored
# in from the separate OpenPrinting/fuzzing repo — NOT part of ipp-usb itself) built with
# go-118-fuzz-build under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE — exactly
# compile_native_go_fuzzer -> build_native_go_fuzzer_legacy's non-coverage path:
#   go-118-fuzz-build -tags gofuzz -o <fuzzer>.a -func <Func> <abs_pkg_dir>
#   $CXX $CXXFLAGS $LIB_FUZZING_ENGINE <fuzzer>.a -o $OUT/<fuzzer>
#
# Fuzzed surfaces:
#   fuzz_usb_layer          — a mock USBIP server/client roundtrip (net.Listen loopback), fuzzing
#                              ipp-usb's own USB-over-IP handling indirectly via crafted bytes.
#   fuzz_http_client        — ipp-usb's tolerance of malformed HTTP/IPP responses from a mock printer.
#   fuzz_daemon_integration — spawns the REAL built ./ipp-usb binary in `standalone` mode and pokes
#                             it with fuzzed HTTP/IPP requests (needs the ipp-usb binary built first).
#
# We produce one /mayhem/<fuzzer> per target, plus /mayhem/ipp-usb (the daemon binary
# fuzz_daemon_integration execs via a relative "./ipp-usb" — cwd is /mayhem, per the Dockerfile's
# WORKDIR, so this resolves).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge for libusb/avahi) are
# forced to DWARF3. The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the
# FIRST CU (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"
export CGO_ENABLED=1

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

: "${SRC:=/mayhem}"
cd "$SRC"
go version

# The fuzzer harnesses live in OpenPrinting/fuzzing upstream (a SEPARATE repo from ipp-usb), so
# OSS-Fuzz's own build.sh vendors them into ipp-usb/fuzzer/ at build time. We carry the same three
# files under mayhem/fuzzer/ (confined to the mayhem/ layer per §6.4) and copy them into place here
# — this keeps the additive git diff clean (no files added outside mayhem/) while reproducing
# OSS-Fuzz's actual build shape exactly.
mkdir -p "$SRC/fuzzer"
cp "$SRC/mayhem/fuzzer/fuzz_usb_layer.go" "$SRC/mayhem/fuzzer/fuzz_http_client.go" \
   "$SRC/mayhem/fuzzer/fuzz_daemon_integration.go" "$SRC/fuzzer/"

# go-118-fuzz-build rewrites the native harness onto its own testing shim, which must be a
# module dep. Order matters: tidy first, THEN `go get` the shim (tidy would otherwise prune it,
# since nothing imports it until the builder generates the entrypoint). PINNED pseudo-version
# (not @latest) so the offline PATCH re-run resolves the SAME version from the module cache.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@v0.0.0-20250520111509-a70c2aa677fa 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# Build the real ipp-usb daemon binary FIRST — fuzz_daemon_integration.go execs it (as a
# relative "./ipp-usb", cwd /mayhem). Needs cgo (libusb-1.0 + avahi-client via pkg-config,
# installed in the Dockerfile).
echo "=== building /mayhem/ipp-usb (the daemon binary under test) ==="
go build -o "$SRC/ipp-usb" .
echo "built $SRC/ipp-usb"

# build_one <abs_pkg_dir> <FuzzFunc> <out_name>
build_one() {
  local dir="$1" func="$2" name="$3"
  echo "=== building $name ($func via go-118-fuzz-build -tags gofuzz, $dir) ==="
  go-118-fuzz-build -tags gofuzz -o "$SRC/mayhem-build/$name.a" -func "$func" "$dir"
  # Pass $GO_DEBUG_FLAGS on the final clang++ link so the C-shim CU carries DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$name.a" -o "/mayhem/$name"
  echo "built /mayhem/$name"
}

build_one "$SRC/fuzzer" FuzzUSBLayer         fuzz_usb_layer
build_one "$SRC/fuzzer" FuzzHTTPClient       fuzz_http_client
build_one "$SRC/fuzzer" FuzzDaemonIntegration fuzz_daemon_integration

# Oracle support: a dynamically-linked C shim that exec()s `go test -json -count=1` over ipp-usb's
# OWN package (SPEC §6.3 anti-reward-hack). Pure Go binaries and the `go` tool itself are
# statically linked, so LD_PRELOAD bypasses them. A thin C shim wrapper IS intercepted by
# LD_PRELOAD — when sabotaged, the shim gets _exit(0) before exec(), producing no output → the
# oracle counts differ → detected. The shim hard-codes the go binary path; argv[1..] passed through.
cat > "$SRC/mayhem-build/test-runner.c" << 'CEOF'
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define GOBIN   "/opt/toolchains/go/bin/go"
/* ipp-usb's own package (root, package main) carries its real assertion-based test suite:
 * glob/inifile/ipp/paper/quirks/tcpuid/usbcommon/uuid/addpdl — known-input -> known-output. */
static const char *GOPKGS[] = {
    ".",
    NULL
};
int main(int argc, char **argv) {
    int npkgs = 0;
    while (GOPKGS[npkgs]) npkgs++;
    int nfixed = 4 + npkgs; /* go, test, -json, -count=1, pkgs... */
    int extra   = argc - 1;
    char **args = (char **)malloc((nfixed + extra + 1) * sizeof(char *));
    if (!args) return 1;
    int i = 0;
    args[i++] = (char *)GOBIN;
    args[i++] = (char *)"test";
    args[i++] = (char *)"-json";
    args[i++] = (char *)"-count=1";
    for (int p = 0; p < npkgs; p++) args[i++] = (char *)GOPKGS[p];
    for (int j = 1; j <= extra; j++) args[i++] = argv[j];
    args[i] = NULL;
    execv(GOBIN, args);
    perror("execv " GOBIN);
    return 127;
}
CEOF
$CC $GO_DEBUG_FLAGS -o "$SRC/mayhem-build/test-runner" "$SRC/mayhem-build/test-runner.c"
echo "built $SRC/mayhem-build/test-runner (go test shim)"

echo "build.sh complete:"
ls -la /mayhem/fuzz_usb_layer /mayhem/fuzz_http_client /mayhem/fuzz_daemon_integration /mayhem/ipp-usb 2>&1 || true
