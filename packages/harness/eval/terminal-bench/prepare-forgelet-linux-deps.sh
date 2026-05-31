#!/usr/bin/env bash
# Install Linux node_modules into Forgelet staging (run on ECS after Mac prepare + sync).
#
# Usage:
#   https_proxy=http://127.0.0.1:7890 ./prepare-forgelet-linux-deps.sh
#   https_proxy=http://127.0.0.1:7890 ./prepare-forgelet-linux-deps.sh ~/.forgelet/tb-forgelet-staging

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${FORGELET_ROOT:-$HOME/.forgelet/tb-forgelet-staging}}"
NODE_DIR="$OUT/.node-prebuilt/node-v20"

if [ ! -x "$NODE_DIR/bin/node" ]; then
  echo "Missing $NODE_DIR — run prepare-forgelet.sh on Mac first (bundles Linux Node)." >&2
  exit 1
fi

echo "=== pnpm install (linux) in $OUT ==="
cd "$OUT"
export PATH="$NODE_DIR/bin:$PATH"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
rm -rf node_modules

if command -v pnpm >/dev/null 2>&1; then
  pnpm install --ignore-scripts
else
  npm install -g pnpm@8
  pnpm install --ignore-scripts
fi

echo "=== building workspace packages for CLI ==="
pnpm --filter @forgelet/cli run build:deps

echo ""
echo "=== done ==="
echo "export FORGELET_ROOT=\"$OUT\""
