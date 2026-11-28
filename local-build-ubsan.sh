#! /bin/sh
# Convenience wrapper: local-build.sh under UndefinedBehaviorSanitizer: a signed
# overflow, a misaligned or null access, a shift out of range, an enum or bool
# with no valid value fail the test that does it, with the stack of the fault.
#
#   ./local-build-ubsan.sh                          # clang, in build-ubsan
#   STATUSBAR_TOOLCHAIN=gcc ./local-build-ubsan.sh  # gcc, in build-gcc-ubsan
#
# All arguments are forwarded, and every knob local-build.sh documents
# (BUILD_DIR, STATUSBAR_SKIP_FUNCTIONAL_TESTS, extra -D flags) still applies.
# On Linux from any host: ./container-sanitize.sh ubsan
STATUSBAR_SANITIZER=ubsan exec "$(dirname "$0")/local-build.sh" "$@"
