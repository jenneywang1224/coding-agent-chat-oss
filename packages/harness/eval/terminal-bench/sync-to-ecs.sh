#!/usr/bin/env bash
# Mac → ECS：同步代码、Forgelet staging、.env
#
# Usage:
#   export ECS_IP=1.2.3.4
#   ./sync-to-ecs.sh
#
# Env:
#   ECS_USER          default ubuntu
#   ECS_REPO_DIR      default ~/coding-agent-chat-oss--terminal-bench
#   FORGELET_ROOT     default ~/.forgelet/tb-forgelet-staging (Mac 侧路径)
#   FORGELET_ENV_FILE 显式指定 .env（默认：worktree 根 / 主仓库兄弟目录）

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../../.." && pwd)"

ECS_IP="${ECS_IP:?set ECS_IP (e.g. export ECS_IP=1.2.3.4)}"
ECS_USER="${ECS_USER:-ubuntu}"
ECS_HOST="${ECS_HOST:-${ECS_USER}@${ECS_IP}}"
ECS_REPO_DIR="${ECS_REPO_DIR:-~/coding-agent-chat-oss--terminal-bench}"
LOCAL_STAGING="${FORGELET_ROOT:-$HOME/.forgelet/tb-forgelet-staging}"
REMOTE_STAGING='~/.forgelet/tb-forgelet-staging'
TB_EVAL='~/coding-agent-chat-oss--terminal-bench/packages/harness/eval/terminal-bench'

resolve_env_file() {
  if [ -n "${FORGELET_ENV_FILE:-}" ] && [ -f "${FORGELET_ENV_FILE}" ]; then
    echo "${FORGELET_ENV_FILE}"
    return 0
  fi
  if [ -f "$REPO_ROOT/.env" ]; then
    echo "$REPO_ROOT/.env"
    return 0
  fi
  local sibling
  sibling="$(cd "$REPO_ROOT/.." && pwd)/coding-agent-chat-oss/.env"
  if [ -f "$sibling" ]; then
    echo "$sibling"
    return 0
  fi
  return 1
}

if [ ! -d "$LOCAL_STAGING/.node-prebuilt/node-v20/bin" ]; then
  echo "Missing Linux Node bundle at $LOCAL_STAGING/.node-prebuilt/node-v20 — run ./prepare-forgelet.sh on Mac first." >&2
  exit 1
fi
if [ ! -d "$LOCAL_STAGING/node_modules/tsx" ]; then
  echo "warn: no linux node_modules in staging — on ECS after sync run:" >&2
  echo "  https_proxy=http://127.0.0.1:7890 ./prepare-forgelet-linux-deps.sh" >&2
fi

echo "=== sync repo → ${ECS_HOST}:${ECS_REPO_DIR} ==="
ssh "$ECS_HOST" "mkdir -p ${ECS_REPO_DIR} ~/.forgelet ~/tb-batch"
rsync -avz --delete \
  --exclude node_modules \
  --exclude .git \
  --exclude 'apps/chat-desktop' \
  --exclude 'packages/harness/eval/swe-bench/.venv' \
  --exclude 'packages/harness/eval/terminal-bench/.venv' \
  "$REPO_ROOT/" "${ECS_HOST}:${ECS_REPO_DIR}/"

# harbor-bundle may live only under eval/terminal-bench (not repo root)
if [ -d "$DIR/harbor-bundle/wheels" ] && ls "$DIR/harbor-bundle/wheels"/*.whl >/dev/null 2>&1; then
  echo "=== sync harbor-bundle wheels ==="
  rsync -avz "$DIR/harbor-bundle/" "${ECS_HOST}:${ECS_REPO_DIR}/packages/harness/eval/terminal-bench/harbor-bundle/"
fi

echo "=== sync FORGELET_ROOT staging ==="
rsync -avz "$LOCAL_STAGING/" "${ECS_HOST}:${REMOTE_STAGING}/"

if ENV_FILE="$(resolve_env_file)"; then
  echo "=== scp .env (from $ENV_FILE) ==="
  scp "$ENV_FILE" "${ECS_HOST}:${ECS_REPO_DIR}/.env"
else
  echo "warn: no .env found (worktree, FORGELET_ENV_FILE, or ../coding-agent-chat-oss/.env)" >&2
  echo "warn: on ECS run: export DEEPSEEK_API_KEY=... before smoke" >&2
fi

echo ""
echo "=== done ==="
cat <<EOF
Next — open a NEW ssh session to ECS, then paste ONLY the block below
(do NOT run smoke/setup on Mac; Mac has no Docker):

  ssh ${ECS_HOST}
  cd ${ECS_REPO_DIR}/packages/harness/eval/terminal-bench
  export FORGELET_ROOT=~/.forgelet/tb-forgelet-staging
  set -a && source ../../../.env && set +a
  python3.12 --version || sudo apt install -y python3.12 python3.12-venv
  ./setup.sh
  mkdir -p ~/tb-batch && cd ~/tb-batch
  ${TB_EVAL}/prepare-forgelet-linux-deps.sh   # 首次，需 https_proxy
  ${TB_EVAL}/smoke.sh

EOF
