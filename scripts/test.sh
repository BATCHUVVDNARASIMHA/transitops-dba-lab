#!/usr/bin/env bash
# Run every assertion. Exits non-zero if any test fails.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "Tests"
run_dir "$SQL_DIR/90_tests"
