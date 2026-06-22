#!/usr/bin/env bash
# Build the named packages inside a Debian container with libFuzzer enabled,
# then run their fuzz-all campaigns (per-fuzzer libFuzzer with bounded budget).
#
# Usage: ./container-fuzz.sh [<pkg> ...]
#   (no arguments)   fuzz every package that defines fuzzers
#   <pkg> ...        fuzz the named packages; names may be 'avb' or
#                    'statusbar-avb'. Packages without fuzzers are skipped
#                    with a warning.
#
# Each package's runtime + dev .debs for transitive deps must already be in
# DEB_OUTPUT (default <root>/deb-output) — run container-build.sh first. Per
# fuzzer, libFuzzer is given FUZZ_DURATION seconds (default 30); the corpus
# is kept under FUZZ_OUTPUT/<pkg>/corpus/<fuzzer-name>/ so a second run
# resumes from where the first left off. Any crash-triggering input lands as
# FUZZ_OUTPUT/<pkg>/<crash-id> on the host.
#
# Environment knobs (all optional):
#   FUZZ_DURATION    seconds per fuzzer       (default 30)
#   FUZZ_MAX_LEN     max input size in bytes  (default 4096)
#   FUZZ_COUNT       ignored on Linux         (used by macOS standalone path)
#   FUZZ_OUTPUT      host dir for corpus + crash artifacts
#                    (default <root>/fuzz-output)
#   DEBIAN_VERSION   container base image tag (default trixie)
#   TARGET_PLATFORM  container platform       (default linux/arm64)
#   CONTAINER_ENGINE podman | docker          (default podman)
#   DEB_OUTPUT       where to find the dep .debs (default <root>/deb-output)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_OUTPUT="${DEB_OUTPUT:-$ROOT/deb-output}"
FUZZ_OUTPUT="${FUZZ_OUTPUT:-$ROOT/fuzz-output}"
FUZZ_DURATION="${FUZZ_DURATION:-30}"
FUZZ_MAX_LEN="${FUZZ_MAX_LEN:-4096}"
FUZZ_COUNT="${FUZZ_COUNT:-1000}"
DEBIAN_VERSION="${DEBIAN_VERSION:-trixie}"
TARGET_PLATFORM="${TARGET_PLATFORM:-linux/arm64}"
ENGINE="${CONTAINER_ENGINE:-podman}"
TARGET_ARCH="${TARGET_PLATFORM##*/}"

# Packages that have at least one *_fuzzer.cpp under them. Keep in sync with
# the actual sources (find . -name '*_fuzzer.cpp').
FUZZ_PKGS="crypto avb"

# Transitive runtime+dev deps for each package — must mirror container-build.sh.
tdeps() {
  case "$1" in
    crypto) echo "core" ;;
    avb) echo "core crypto audio" ;;
    *) echo "" ;;
  esac
}

has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac ; }

# ---- pick targets -----------------------------------------------------------

WANT=""
if [ "$#" -eq 0 ]; then
  WANT=" $FUZZ_PKGS "
else
  for arg in "$@"; do
    p="${arg#statusbar-}"
    if ! has "$FUZZ_PKGS" "$p"; then
      echo "warning: '$arg' has no fuzzers — skipping" >&2
      continue
    fi
    WANT="$WANT $p"
  done
fi
if [ -z "$(echo "$WANT" | tr -d ' ')" ]; then
  echo "error: no fuzzable packages selected" >&2
  exit 1
fi

# ---- cross-arch sanity (mirrors container-build.sh) -------------------------

case "$TARGET_ARCH" in
  arm64) KERNEL_ARCH="aarch64" ;;
  amd64) KERNEL_ARCH="x86_64" ;;
  *)     KERNEL_ARCH="$TARGET_ARCH" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH="aarch64" ;;
  amd64|x86_64)  HOST_ARCH="x86_64" ;;
  *)             HOST_ARCH="$(uname -m)" ;;
esac
if [ "$HOST_ARCH" != "$KERNEL_ARCH" ] \
   && ! ls /proc/sys/fs/binfmt_misc/qemu-"$KERNEL_ARCH"* >/dev/null 2>&1; then
  echo "error: host $(uname -m) cannot run $TARGET_PLATFORM containers." >&2
  echo "       qemu-user-static binfmt_misc handler is not registered." >&2
  exit 1
fi

MOUNT_OPT=""
if [ "$(uname -s)" = "Linux" ]; then
  MOUNT_OPT=",z"
fi

mkdir -p "$FUZZ_OUTPUT"

# ---- per-package container invocation ---------------------------------------

fuzz_one() {
  local pkg="$1"
  local tree_dir="$ROOT/$pkg"
  local image="localhost/statusbar-deb-builder:$DEBIAN_VERSION-$TARGET_ARCH"

  if [ ! -d "$tree_dir" ]; then
    echo "error: '$tree_dir' not found" >&2
    return 1
  fi

  # Ensure the deb-builder image is around (use core's Containerfile as the
  # canonical source — every package's Containerfile is the same).
  if ! "$ENGINE" image exists "$image" >/dev/null 2>&1; then
    echo "=== building builder image $image ==="
    "$ENGINE" build -t "$image" \
      --platform "$TARGET_PLATFORM" \
      --build-arg "DEBIAN_VERSION=$DEBIAN_VERSION" \
      -f "$ROOT/core/Containerfile" "$ROOT/core"
  fi

  # Sanity-check deps are already built.
  local missing=""
  for d in $(tdeps "$pkg"); do
    if ! ls "$DEB_OUTPUT"/statusbar-"$d"-dev_*.deb >/dev/null 2>&1; then
      missing="$missing $d"
    fi
  done
  if [ -n "$missing" ]; then
    echo "error: dependencies of '$pkg' are not built:$missing" >&2
    echo "       run ./container-build.sh $pkg to build them first." >&2
    return 1
  fi

  local pkg_out="$FUZZ_OUTPUT/$pkg"
  mkdir -p "$pkg_out/corpus"

  echo
  echo "=============================================================="
  echo "=== fuzzing statusbar-$pkg (Debian $DEBIAN_VERSION, ${FUZZ_DURATION}s/fuzzer)"
  echo "=============================================================="
  "$ENGINE" run --rm \
    --platform "$TARGET_PLATFORM" \
    -v "$tree_dir:/src:ro$MOUNT_OPT" \
    -v "$DEB_OUTPUT:/debs:ro$MOUNT_OPT" \
    -v "$pkg_out:/fuzz-out:rw$MOUNT_OPT" \
    -v "statusbar-deb-ccache-$TARGET_ARCH:/root/.ccache" \
    -e "DEPS=$(tdeps "$pkg")" \
    -e "FUZZ_DURATION=$FUZZ_DURATION" \
    -e "FUZZ_MAX_LEN=$FUZZ_MAX_LEN" \
    -e "FUZZ_COUNT=$FUZZ_COUNT" \
    "$image" bash -euo pipefail -c '
      debs=()
      for d in $DEPS; do
        debs+=(/debs/statusbar-"$d"_*.deb /debs/statusbar-"$d"-dev_*.deb)
      done
      if [ "${#debs[@]}" -gt 0 ]; then
        apt-get update -qq
        apt-get install -y --no-install-recommends "${debs[@]}"
      fi
      cmake -Wno-dev -S /src -B /build -G Ninja \
        --toolchain /src/cmake/toolchain-clang.cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_FUZZING=ON \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      cmake --build /build

      # Run libFuzzer from the fuzz-out dir so any crash artifact that
      # libFuzzer writes (e.g. crash-<sha>, leak-<sha>, oom-<sha>) ends up
      # on the host without an extra copy step.
      cd /fuzz-out
      exec /src/cmake/fuzz-all.sh /build /fuzz-out/corpus \
        "$FUZZ_DURATION" "$FUZZ_MAX_LEN" "$FUZZ_COUNT"
    '
}

failures=""
for pkg in $WANT; do
  if ! fuzz_one "$pkg"; then
    failures="$failures $pkg"
  fi
done

echo
if [ -n "$failures" ]; then
  echo "=== fuzz campaigns FAILED for:$failures ==="
  echo "    crash inputs (if any) are in: $FUZZ_OUTPUT/<pkg>/"
  exit 1
fi
echo "=== done: fuzzed $(echo "$WANT" | wc -w | tr -d ' ') package(s); artifacts in $FUZZ_OUTPUT ==="
