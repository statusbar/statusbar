#! /bin/sh
# Convenience wrapper: local-build.sh with the gcc toolchain selected.
# All arguments are forwarded, and every knob local-build.sh documents
# (BUILD_DIR, extra -D flags) still applies.
STATUSBAR_TOOLCHAIN=gcc exec "$(dirname "$0")/local-build.sh" "$@"
