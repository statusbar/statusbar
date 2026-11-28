#! /bin/sh
# Convenience wrapper: local-build.sh under AddressSanitizer: a read or write outside
# an object, a use after free and, on Linux, a leak fail the test that does
# it, with the stack of the access.
#
#   ./local-build-asan.sh                          # clang, in build-asan
#   STATUSBAR_TOOLCHAIN=gcc ./local-build-asan.sh  # gcc, in build-gcc-asan
#
# All arguments are forwarded, and every knob local-build.sh documents
# (BUILD_DIR, STATUSBAR_SKIP_FUNCTIONAL_TESTS, extra -D flags) still applies.
# On Linux from any host: ./container-sanitize.sh asan
STATUSBAR_SANITIZER=asan exec "$(dirname "$0")/local-build.sh" "$@"
