#! /bin/sh
# Copyright 2026 Jeff Koftinoff <jeff.koftinoff@statusbar.com>
# SPDX-License-Identifier: MIT

# Format every package by delegating to its own reformat.sh, plus the
# umbrella's own top-level files.
#   default:  rewrite files in place.
#   --check:  exit non-zero if anything would change; no files modified.

set -e

check_arg=""
case "${1:-}" in
    --check|--dry-run) check_arg="--check" ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

# Run from the umbrella root regardless of the caller's CWD, so the
# per-package reformat.sh scripts (which use root-relative paths) resolve.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

overall_status=0

# Format each package by delegating to its own reformat.sh.
for pkg in core crypto audio avb; do
    if [ -f "$pkg/reformat.sh" ]; then
        if ! ( cd "$pkg" && sh reformat.sh $check_arg ); then
            overall_status=1
        fi
    else
        echo "skipping $pkg: reformat.sh not found (submodule not initialized?)"
    fi
done

# Format the umbrella's own CMake files.
if command -v cmake-format >/dev/null 2>&1; then
    if [ -n "$check_arg" ]; then
        cmake_args="--check"
    else
        cmake_args="-i"
    fi
    cmake-format $cmake_args CMakeLists.txt || overall_status=1
    find cmake -name '*.cmake' -print0 2>/dev/null \
        | xargs -0 -r cmake-format $cmake_args || overall_status=1
fi

exit $overall_status
