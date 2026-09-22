#! /bin/sh
# Convenience wrapper: local-build.sh with the clang toolchain selected.
# All arguments are forwarded, and every knob local-build.sh documents
# (BUILD_DIR, extra -D flags) still applies.
STATUSBAR_TOOLCHAIN=clang exec "$(dirname "$0")/local-build.sh" "$@"
