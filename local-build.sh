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

# STATUSBAR_SANITIZER builds and tests everything under a sanitizer: asan,
# ubsan or tsan (cmake/sanitizers.cmake; one at a time). A test that trips it
# fails, with the stack of the fault in its output. local-build-asan.sh and
# local-build-ubsan.sh are this knob as commands, and container-sanitize.sh
# is the same build in the Debian builder container.
#   STATUSBAR_SANITIZER=asan ./local-build.sh
STATUSBAR_SANITIZER="${STATUSBAR_SANITIZER:-}"
case "$STATUSBAR_SANITIZER" in
  "") SANITIZER_SWITCH="" ;;
  asan) SANITIZER_SWITCH="-DENABLE_ASAN=ON" ;;
  ubsan)
    SANITIZER_SWITCH="-DENABLE_UBSAN=ON"
    # The report names the line; the stack says how the test got there.
    export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1}"
    ;;
  tsan) SANITIZER_SWITCH="-DENABLE_TSAN=ON" ;;
  *)
    set +x
    echo "error: STATUSBAR_SANITIZER must be 'asan', 'ubsan' or 'tsan'" >&2
    exit 1
    ;;
esac

# libc++ (clang) and libstdc++ (gcc) objects cannot be mixed, so each toolchain
# needs its own build tree. clang keeps the historical `build` default so
# existing habits and IDE setups are unaffected; gcc gets `build-gcc`, matching
# the `gcc` CMake preset. A sanitizer changes every object too and gets its
# own tree again: build-asan, build-gcc-ubsan. BUILD_DIR still overrides all.
case "$STATUSBAR_TOOLCHAIN" in
  clang) BUILD_DIR="${BUILD_DIR:-build${STATUSBAR_SANITIZER:+-$STATUSBAR_SANITIZER}}" ;;
  *)     BUILD_DIR="${BUILD_DIR:-build-$STATUSBAR_TOOLCHAIN${STATUSBAR_SANITIZER:+-$STATUSBAR_SANITIZER}}" ;;
esac

cmake -G Ninja -B "$BUILD_DIR" -S . \
  --toolchain "cmake/toolchain-$STATUSBAR_TOOLCHAIN.cmake" $SANITIZER_SWITCH "$@"
cmake --build "$BUILD_DIR"
# Everything is built, then two test runs, kept apart. The unit tests first:
# they test logic, open no socket and wait for nothing, so a loaded build host
# cannot fail them. A hung test fails instead of blocking the run (none of the
# suites takes a minute). A failed test's output is printed: under a sanitizer
# that is the report, with the stack of the fault.
ctest --test-dir "$BUILD_DIR" --timeout 300 --output-on-failure -LE functional
# Then the functional tests (real sockets, a real kernel). They count the same:
# one that fails fails the build. STATUSBAR_SKIP_FUNCTIONAL_TESTS=1 leaves them
# out, for a host that cannot run them; the unit tests above still run.
if [ "${STATUSBAR_SKIP_FUNCTIONAL_TESTS:-0}" = "1" ]; then
  set +x
  echo "local-build: STATUSBAR_SKIP_FUNCTIONAL_TESTS=1, the functional tests are not run" >&2
else
  ctest --test-dir "$BUILD_DIR" --timeout 300 --output-on-failure -L functional
fi
