#!/usr/bin/env bash
# Mac 上打包 Harbor + 依赖 wheel，供 ECS 离线 pip install（ECS 访问不了 GitHub 时用）。
#
# Usage:
#   ./bundle-harbor-for-ecs.sh
#
# Output: ./harbor-bundle/wheels/*.whl
# Then:   ./sync-to-ecs.sh  （会带上 harbor-bundle/）

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
OUT="$DIR/harbor-bundle/wheels"
mkdir -p "$OUT"

pick_python() {
  for candidate in python3.13 python3.12 /opt/homebrew/opt/python@3.12/bin/python3.12; do
    if command -v "$candidate" >/dev/null 2>&1; then
      local ver major minor
      ver="$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
      major="${ver%%.*}"
      minor="${ver#*.}"
      if [ "$major" -eq 3 ] && [ "$minor" -ge 12 ] && [ "$minor" -le 13 ]; then
        echo "$candidate"
        return
      fi
    fi
  done
  return 1
}

PY="$(pick_python)" || {
  echo "Need Python 3.12 or 3.13 on Mac. brew install python@3.12" >&2
  exit 1
}

echo "=== bundle Harbor wheels with $PY ==="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$PY" -m venv "$TMP/venv"
"$TMP/venv/bin/pip" install -U pip wheel
# Build deps for harbor's pyproject (needed if target ever builds from sdist)
"$TMP/venv/bin/pip" wheel 'uv_build>=0.8.4,<0.9.0' -w "$OUT"
"$TMP/venv/bin/pip" wheel -r "$DIR/requirements.txt" -w "$OUT"
echo ""
echo "Harbor wheel: $(ls -1 "$OUT"/harbor-*.whl 2>/dev/null | head -1 || echo MISSING)"
echo "=== done: $(ls -1 "$OUT" | wc -l | tr -d ' ') wheels in $OUT ==="
echo "Next: ./sync-to-ecs.sh   then on ECS: ./setup.sh"
