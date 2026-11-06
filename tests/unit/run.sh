#!/bin/sh
# Host unit tests (no Factorio): run from anywhere, exits non-zero on any failure.
cd "$(dirname "$0")/../.." || exit 1
exec lua5.2 tests/unit/run.lua "$@"
