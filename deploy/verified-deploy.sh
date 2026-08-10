#!/usr/bin/env bash
# Deploy by copy, then prove the copy landed.
#
# The invariant this enforces: a file on the server is a committed file.
# Servers drift when people edit in place under pressure. Once that happens
# you no longer know what is running, and the next deploy silently reverts
# somebody's fix. This refuses to deploy from a dirty tree, and can prove
# after the fact that the server matches git.
#
#   ./verified-deploy.sh            # deploy tracked files
#   ./verified-deploy.sh --verify   # compare only, transfer nothing
#   ./verified-deploy.sh --wip      # allow a dirty tree (local testing only)
set -euo pipefail

HOST="${DEPLOY_HOST:?set DEPLOY_HOST, e.g. user@server}"
REMOTE_DIR="${DEPLOY_PATH:?set DEPLOY_PATH, e.g. /opt/app}"
SSH_OPTS="${DEPLOY_SSH_OPTS:-}"

MODE="deploy"
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --verify) MODE="verify" ;;
    --wip)    ALLOW_DIRTY=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "deploy" ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "Refusing to deploy: uncommitted changes." >&2
    git status --short >&2
    echo "Commit them, or pass --wip if this is a throwaway test." >&2
    exit 1
  fi
fi

remote_sha() { ssh $SSH_OPTS "$HOST" "sha256sum '$REMOTE_DIR/$1' 2>/dev/null | cut -d' ' -f1"; }
local_sha()  { shasum -a 256 "$1" | cut -d' ' -f1; }

drift=0
count=0
while IFS= read -r f; do
  count=$((count + 1))
  if [ "$MODE" = "deploy" ]; then
    ssh $SSH_OPTS "$HOST" "mkdir -p '$REMOTE_DIR/$(dirname "$f")'"
    scp $SSH_OPTS -q "$f" "$HOST:$REMOTE_DIR/$f"
  fi
  if [ "$(local_sha "$f")" != "$(remote_sha "$f")" ]; then
    echo "MISMATCH: $f"
    drift=$((drift + 1))
  fi
done < <(git ls-files)

echo "checked $count files"
if [ "$drift" -ne 0 ]; then
  echo "$drift file(s) differ from git."
  exit 1
fi
echo "server matches git."
