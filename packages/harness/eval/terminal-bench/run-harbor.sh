#!/usr/bin/env bash
# Run Terminal-Bench via Harbor with the Forgelet agent adapter.
#
# Usage:
#   ./run-harbor.sh [harbor run args...]
#
# Examples:
#   ./run-harbor.sh --dataset terminal-bench/terminal-bench-2-1 --include-task-name terminal-bench/adaptive-rejection-sampler
#   ./run-harbor.sh --dataset terminal-bench/terminal-bench-2-1 --n-concurrent 4
#
# Prereqs:
#   ./setup.sh && ./prepare-forgelet.sh
#   export DEEPSEEK_API_KEY=...   (or provider key for --model)
#   export FORGELET_ROOT=~/.forgelet/tb-forgelet-staging

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [ ! -x ".venv/bin/harbor" ]; then
  echo "Run ./setup.sh first" >&2
  exit 1
fi

if [ -z "${FORGELET_ROOT:-}" ]; then
  DEFAULT="$HOME/.forgelet/tb-forgelet-staging"
  if [ -d "$DEFAULT/node_modules/tsx" ]; then
    export FORGELET_ROOT="$DEFAULT"
    echo "Using FORGELET_ROOT=$FORGELET_ROOT"
  else
    echo "Error: FORGELET_ROOT unset. Run ./prepare-forgelet.sh first." >&2
    exit 1
  fi
fi

MODEL="${FORGELET_HARBOR_MODEL:-deepseek/deepseek-chat}"
N_CONCURRENT="${FORGELET_HARBOR_CONCURRENT:-4}"
DATASET="${FORGELET_HARBOR_DATASET:-terminal-bench/terminal-bench-2-1}"
# Harbor 0.9+ removed --timeout (seconds). Use multipliers or task.toml defaults.
AGENT_TIMEOUT_MULTIPLIER="${FORGELET_HARBOR_AGENT_TIMEOUT_MULTIPLIER:-}"

AGENT_IMPORT="forgelet_agent:ForgeletAgent"
export PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}"

ARGS=()
if [ "$#" -eq 0 ]; then
  ARGS=(
    run
    --dataset "$DATASET"
    --agent-import-path "$AGENT_IMPORT"
    --model "$MODEL"
    --n-concurrent "$N_CONCURRENT"
    --yes
  )
  if [ -n "$AGENT_TIMEOUT_MULTIPLIER" ]; then
    ARGS+=(--agent-timeout-multiplier "$AGENT_TIMEOUT_MULTIPLIER")
  fi
else
  ARGS=("$@")
  # Ensure import path is set when caller passes partial args
  has_import=0
  for a in "${ARGS[@]}"; do
    if [ "$a" = "--agent-import-path" ]; then has_import=1; fi
  done
  if [ "$has_import" -eq 0 ]; then
    ARGS+=(--agent-import-path "$AGENT_IMPORT")
  fi
fi

echo "=== harbor ${ARGS[*]} ==="
exec .venv/bin/harbor "${ARGS[@]}"
