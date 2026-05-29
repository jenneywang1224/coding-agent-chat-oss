#!/usr/bin/env bash
# Alias for smoke.sh — naming parity with swe-bench docker-smoke.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/smoke.sh" "$@"
