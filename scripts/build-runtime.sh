#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${MEOW_RUNTIME_BUILD_DIR:-"$ROOT_DIR/build-runtime"}

if command -v cmake >/dev/null 2>&1; then
    cmake -S "$ROOT_DIR/cmake/runtime-tests" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE="${MEOW_BUILD_TYPE:-Release}"
    cmake --build "$BUILD_DIR" --parallel "${MEOW_BUILD_JOBS:-2}"
    # Debian 11 ships CTest before --test-dir was introduced.
    (cd "$BUILD_DIR" && ctest --output-on-failure)
else
    printf '%s\n' 'cmake is required for the standalone runtime build' >&2
    exit 1
fi
