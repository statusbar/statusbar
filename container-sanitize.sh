#!/usr/bin/env bash
# Build every package as one project with a sanitizer on, inside the Debian
# builder container, and run the tests there. This is local-build.sh with
# STATUSBAR_SANITIZER set (local-build-asan.sh, local-build-ubsan.sh) on Linux
# from any host that has a container engine: the same compiler and libraries
# as the packages are built with, and nothing to install on the host.
#
# Usage: ./container-sanitize.sh [asan|ubsan|tsan] [<cmake argument> ...]
#   (no arguments)   AddressSanitizer
#   asan             a read or write outside an object, a use after free, a leak
#   ubsan            signed overflow, misaligned or null access, a bad shift,
#                    an enum or bool with no valid value
#   tsan             a data race between two threads
#   Anything after the sanitizer goes to cmake, as with local-build.sh.
#
# A test that trips the sanitizer fails, with the stack of the fault in its
# output. The script's exit status is the build's and the tests'.
#
# The build tree is kept in a container volume per sanitizer, architecture and
# toolchain, and the compiler cache is the one container-build.sh uses, so a
# second run compiles only what changed. `podman volume rm` the volume named
# at the start of a run for a build from nothing.
#
# Environment knobs (all optional):
#   STATUSBAR_TOOLCHAIN  clang (default) or gcc
#   TARGET_PLATFORM      container platform. Default: the host's own
#                        architecture, because the sanitizer runtimes do not
#                        work under user-mode emulation.
#   STATUSBAR_SKIP_FUNCTIONAL_TESTS
#                        1 (default here): unit tests only. 0 also runs the
#                        functional tests, which need real sockets and so a
#                        container that is allowed them.
#   ASAN_OPTIONS, UBSAN_OPTIONS, TSAN_OPTIONS
#                        passed to the tests when set
#   DEBIAN_VERSION       container base image tag
#   CONTAINER_ENGINE     podman (default) or docker
set -euo pipefail

SANITIZER="${1:-asan}"
[ "$#" -gt 0 ] && shift
case "$SANITIZER" in
  asan | ubsan | tsan) ;;
  *)
    echo "usage: $0 [asan|ubsan|tsan] [<cmake argument> ...]" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSBAR_TOOLCHAIN="${STATUSBAR_TOOLCHAIN:-clang}"
case "$STATUSBAR_TOOLCHAIN" in
  clang) _default_debian="trixie" ;;
  gcc)   _default_debian="forky" ;;
  *)
    echo "error: STATUSBAR_TOOLCHAIN must be 'clang' or 'gcc'" >&2
    exit 1
    ;;
esac
DEBIAN_VERSION="${DEBIAN_VERSION:-$_default_debian}"
case "$(uname -m)" in
  arm64 | aarch64) _native="linux/arm64" ;;
  *)               _native="linux/amd64" ;;
esac
TARGET_PLATFORM="${TARGET_PLATFORM:-$_native}"
TARGET_ARCH="${TARGET_PLATFORM##*/}"
ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="localhost/statusbar-deb-builder:$DEBIAN_VERSION-$TARGET_ARCH-$STATUSBAR_TOOLCHAIN"
BUILD_VOLUME="statusbar-sanitize-$SANITIZER-$TARGET_ARCH-$STATUSBAR_TOOLCHAIN"

if ! "$ENGINE" info >/dev/null 2>&1; then
  if "$ENGINE" machine inspect >/dev/null 2>&1; then
    echo "=== $ENGINE VM is not running; starting it ==="
    "$ENGINE" machine start
  else
    echo "error: cannot connect to $ENGINE." >&2
    exit 1
  fi
fi

# On SELinux hosts bind mounts must be relabelled; ",z" is a no-op elsewhere.
MOUNT_OPT=""
if [ "$(uname -s)" = "Linux" ]; then
  MOUNT_OPT=",z"
fi

# The builder image is the one the packages are built in (see
# core/scripts/container-build.sh): made here when it is missing or its
# Containerfile changed.
CF_SUM="$(cksum "$ROOT/core/Containerfile" | cut -d' ' -f1)"
if [ "$("$ENGINE" image inspect \
         --format '{{index .Config.Labels "statusbar.containerfile"}}' \
         "$IMAGE" 2>/dev/null)" != "$CF_SUM" ]; then
  echo "=== building builder image $IMAGE ==="
  "$ENGINE" build -t "$IMAGE" \
    --platform "$TARGET_PLATFORM" \
    --build-arg "DEBIAN_VERSION=$DEBIAN_VERSION" \
    --build-arg "STATUSBAR_TOOLCHAIN=$STATUSBAR_TOOLCHAIN" \
    --label "statusbar.containerfile=$CF_SUM" \
    -f "$ROOT/core/Containerfile" "$ROOT/core"
fi

echo "=== $SANITIZER build and tests: $TARGET_PLATFORM, $STATUSBAR_TOOLCHAIN, build volume $BUILD_VOLUME ==="
# SYS_PTRACE: the leak check at the end of an ASan test stops the process's
# threads with ptrace, which a container is not given by default.
"$ENGINE" run --rm \
  --platform "$TARGET_PLATFORM" \
  --cap-add SYS_PTRACE \
  -v "$ROOT:/src:ro$MOUNT_OPT" \
  -v "$BUILD_VOLUME:/build" \
  -v "statusbar-deb-ccache-$TARGET_ARCH-$STATUSBAR_TOOLCHAIN:/root/.ccache" \
  -e "BUILD_DIR=/build" \
  -e "STATUSBAR_TOOLCHAIN=$STATUSBAR_TOOLCHAIN" \
  -e "STATUSBAR_SANITIZER=$SANITIZER" \
  -e "STATUSBAR_SKIP_FUNCTIONAL_TESTS=${STATUSBAR_SKIP_FUNCTIONAL_TESTS:-1}" \
  ${ASAN_OPTIONS:+-e "ASAN_OPTIONS=$ASAN_OPTIONS"} \
  ${UBSAN_OPTIONS:+-e "UBSAN_OPTIONS=$UBSAN_OPTIONS"} \
  ${TSAN_OPTIONS:+-e "TSAN_OPTIONS=$TSAN_OPTIONS"} \
  -w /src \
  "$IMAGE" ./local-build.sh \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache "$@"
echo "=== $SANITIZER: the build and its tests passed ==="
