#! /bin/bash

set -e
set -x

BUILD_DIR="${BUILD_DIR:-build}"

cmake -G Ninja -B "$BUILD_DIR" -S . --toolchain cmake/toolchain-clang.cmake "$@"
cmake --build "$BUILD_DIR"
ctest --test-dir "$BUILD_DIR"
