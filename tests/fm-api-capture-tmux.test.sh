#!/usr/bin/env bash
# Focused real-tmux integration for the Quartermaster styled capture facade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-api-capture-tmux)
HOME_ROOT="$TMP_ROOT/home"
TMUX_ROOT="$TMP_ROOT/tmux"
mkdir -p "$HOME_ROOT/state" "$TMUX_ROOT"
export TMUX_TMPDIR="$TMUX_ROOT"

cleanup_tmux_capture() {
  tmux kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_tmux_capture EXIT INT TERM HUP

tmux new-session -d -s fixture -n fm-controlcapture \
  "printf '\\033[35mstyled-capture\\033[0m\\n'; sleep 30"
sleep 0.2
printf '%s\n' 'window=fixture:fm-controlcapture' "worktree=$TMP_ROOT" 'project=repo' \
  >"$HOME_ROOT/state/controlcapture.meta"

request='{"schema":"q.firstmate-request.v1","operation":"worker.capture","idempotency_key":"capture-real-tmux","task_id":"controlcapture","lines":40}'
out=$(printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-api.sh" worker.capture) \
  || fail "real tmux worker.capture failed"
printf '%s\n' "$out" | jq -e '
  .result == "ok" and
  .postcondition_evidence.schema == "fm-terminal-frame.v1" and
  .postcondition_evidence.backend == "tmux" and
  .postcondition_evidence.styled == true and
  (.postcondition_evidence.content | contains("styled-capture")) and
  (.postcondition_evidence.content | contains("\u001b[35m"))
' >/dev/null || fail "real tmux capture did not preserve styled terminal output"

pass "worker.capture preserves styled output through real tmux"
