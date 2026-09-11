#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-q-land-local)
BIN="$TMP_ROOT/bin"
WORKER_HOME="$TMP_ROOT/worker-home"
DESTINATION="$TMP_ROOT/destination"
WORKTREE="$TMP_ROOT/worktree"
mkdir -p "$BIN" "$WORKER_HOME/state"
cp "$ROOT/bin/fm-q-land-local.sh" "$BIN/fm-q-land-local.sh"
cp "$ROOT/bin/fm-pr-lib.sh" "$BIN/fm-pr-lib.sh"
cat >"$BIN/fm-captain-hold.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  open) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN"/*.sh

git init -q -b main "$DESTINATION"
git -C "$DESTINATION" config user.name Test
git -C "$DESTINATION" config user.email test@example.invalid
printf 'base\n' >"$DESTINATION/README.md"
git -C "$DESTINATION" add README.md
git -C "$DESTINATION" commit -qm base
BASE=$(git -C "$DESTINATION" rev-parse HEAD)

git clone -q --no-hardlinks "$DESTINATION" "$WORKTREE"
git -C "$WORKTREE" config user.name Test
git -C "$WORKTREE" config user.email test@example.invalid
git -C "$WORKTREE" switch -qc fm/worker-1
printf 'validated\n' >>"$WORKTREE/README.md"
git -C "$WORKTREE" add README.md
git -C "$WORKTREE" commit -qm validated
HEAD=$(git -C "$WORKTREE" rev-parse HEAD)

cat >"$WORKER_HOME/state/worker-1.meta" <<EOF
q_root_task_id=task-root
worktree=$WORKTREE
project=$WORKTREE
mode=local-only
EOF

out=$("$BIN/fm-q-land-local.sh" worker-1 "$WORKER_HOME" "$DESTINATION" "$WORKTREE" \
  "$BASE" "$HEAD" task-root) || fail "exact-head local landing failed"
printf '%s\n' "$out" | jq -e --arg head "$HEAD" \
  '.confirmed == true and .observed_head == $head and .already_landed == false' >/dev/null \
  || fail "exact-head local landing evidence is invalid"
[ "$(git -C "$DESTINATION" rev-parse HEAD)" = "$HEAD" ] \
  || fail "destination did not advance to the validated head"
pass "Q local landing imports and fast-forwards an isolated validated commit"

out=$("$BIN/fm-q-land-local.sh" worker-1 "$WORKER_HOME" "$DESTINATION" "$WORKTREE" \
  "$BASE" "$HEAD" task-root) || fail "exact-head local landing replay failed"
printf '%s\n' "$out" | jq -e '.confirmed == true and .already_landed == true' >/dev/null \
  || fail "exact-head local landing replay was not idempotent"
pass "Q local landing replay confirms the already-landed head"
