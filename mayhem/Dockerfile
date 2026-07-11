# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. OpenPrinting/ipp-usb is a Go project that uses cgo
# to bind libusb (device I/O) and avahi-client (DNS-SD/mDNS advertisement), so on top of the
# Go toolchain + OSS-Fuzz Go fuzzing tooling (go-118-fuzz-build, native `func FuzzX(f
# *testing.F)` harnesses) we also need libusb-1.0/avahi-client dev headers for cgo to link.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t ipp-usb-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: the OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); the Go fuzz
# binary is built with ASan and links the libFuzzer engine. build.sh handles the Go specifics.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain. ipp-usb's go.mod only requires `go 1.11`, but go-118-fuzz-build (the
# OSS-Fuzz native-Go-fuzz builder) needs a modern toolchain; pin the same recent stable used
# fleet-wide for other Go repos.
ARG GO_VERSION=1.24.4
ARG GO_SHA256=77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ──────────────────────────────────
# SPEC §6.2 item 8 + §6.5: commit build and PATCH re-run run under different $HOMEs.
# Pinning GOROOT/GOPATH/GOMODCACHE/GOCACHE under /opt/toolchains ensures the module cache
# populated during the first (online) image build is found again when build.sh re-runs offline.
ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    CGO_ENABLED=1 \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

# ── Install Go + cgo library deps (libusb/avahi) + the OSS-Fuzz Go fuzzing build tool ──────────
# The base image is C/C++-only; replicate OSS-Fuzz base-builder-go's install_go.sh, plus the
# apt packages ipp-usb's own OSS-Fuzz Dockerfile installs for its cgo bindings:
#   * official go tarball -> /opt/toolchains/go (PATH'd)
#   * libusb-1.0-0-dev / libudev-dev / pkg-config  — usbio_libusb.go: `#cgo pkg-config: libusb-1.0`
#   * libavahi-client-dev                          — dnssd_avahi.go: `#cgo pkg-config: avahi-client`
#   * go-118-fuzz-build (PINNED pseudo-version, not @latest)  — builds the native
#     `func FuzzX(f *testing.F)` harnesses (all 3 ipp-usb targets use this path)
USER root
RUN repro-sources-list.sh 2>/dev/null || true; \
    apt-get update && apt-get install -yq --no-install-recommends \
      wget ca-certificates git pkg-config \
      libusb-1.0-0-dev libudev-dev \
      libavahi-client-dev \
    && rm -rf /var/lib/apt/lists/* \
    && install -d /opt/toolchains/go-path \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && go version \
    && go install github.com/AdamKorcz/go-118-fuzz-build@v0.0.0-20250520111509-a70c2aa677fa \
    && ls -la "$(go env GOPATH)/bin" \
    && chmod -R a+rX /opt/toolchains/go \
    && chown -R 2000:2000 /opt/toolchains/go-path \
    && go clean -cache 2>/dev/null || true

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run ipp-usb's own Go test suite (pure logic — glob/inifile/ipp/paper/quirks/tcpuid/usbcommon/
# uuid — no hardware/network) at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
