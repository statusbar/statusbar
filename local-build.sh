#! /bin/bash

set -e
set -x

# STATUSBAR_TOOLCHAIN picks the compiler: clang (default) or gcc. Same knob as
# container-build.sh, so one name drives local and container builds alike.
#   ./local-build.sh                          # clang + libc++, C++23
#   STATUSBAR_TOOLCHAIN=gcc ./local-build.sh  # gcc + libstdc++, C++26
STATUSBAR_TOOLCHAIN="${STATUSBAR_TOOLCHAIN:-clang}"
case "$STATUSBAR_TOOLCHAIN" in
  clang | gcc) ;;
  *)
    set +x
    echo "error: STATUSBAR_TOOLCHAIN must be 'clang' or 'gcc'" >&2
    exit 1
    ;;
esac

# libc++ (clang) and libstdc++ (gcc) objects cannot be mixed, so each toolchain
# needs its own build tree. clang keeps the historical `build` default so
# existing habits and IDE setups are unaffected; gcc gets `build-gcc`, matching
# the `gcc` CMake preset. BUILD_DIR still overrides either.
case "$STATUSBAR_TOOLCHAIN" in
  clang) BUILD_DIR="${BUILD_DIR:-build}" ;;
  *)     BUILD_DIR="${BUILD_DIR:-build-$STATUSBAR_TOOLCHAIN}" ;;
esac

cmake -G Ninja -B "$BUILD_DIR" -S . \
  --toolchain "cmake/toolchain-$STATUSBAR_TOOLCHAIN.cmake" "$@"
cmake --build "$BUILD_DIR"
# Everything is built, the functional tests among it, and the unit tests are
# run: they test logic, open no socket and wait for nothing, so a loaded build
# host cannot fail them. The functional tests (real sockets, a real kernel) are
# not run here. They run when committing, from the pre-commit hook
# (install-hooks.sh), or by hand with: ctest --test-dir "$BUILD_DIR" -L functional
# A hung test fails instead of blocking the run (none of the suites takes a minute).
ctest --test-dir "$BUILD_DIR" --timeout 300 -LE functional
