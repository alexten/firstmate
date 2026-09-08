#!/usr/bin/env bash
# Contract tests for the Quartermaster JSON facade and opt-in spawn metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-api)
BIN="$TMP_ROOT/bin"
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$BIN" "$HOME_ROOT/data" "$HOME_ROOT/state"
cp "$ROOT/bin/fm-api.sh" "$BIN/fm-api.sh"
chmod +x "$BIN/fm-api.sh"

cat >"$BIN/fm-brief.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
home=${FM_HOME:?}
id=$1
mkdir -p "$home/data/$id"
printf '# Task\n## Captain intent\n{TASK}\n## Spec\n{FIRSTMATE_SPEC}\n' >"$home/data/$id/brief.md"
EOF

cat >"$BIN/fm-spawn.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
home=${FM_HOME:?}
id=$1
mkdir -p "$home/state"
{
  printf 'q_root_task_id=%s\n' "${FM_Q_ROOT_TASK_ID:?}"
  printf 'q_execution_id=%s\n' "${FM_Q_EXECUTION_ID:?}"
  printf 'q_lease_id=%s\n' "${FM_Q_LEASE_ID:?}"
  printf 'q_phase=%s\n' "${FM_Q_PHASE:?}"
  printf 'q_contract_schema=%s\n' "${FM_Q_CONTRACT_SCHEMA:?}"
} >"$home/state/$id.meta"
EOF

cat >"$BIN/fm-fleet-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","tasks":[{"id":"worker-1","current_state":{"state":"working"}}]}'
EOF

for owner in fm-send.sh fm-control.sh fm-teardown.sh; do
  cat >"$BIN/$owner" <<'EOF'
#!/usr/bin/env bash
printf 'owner diagnostic\n' >&2
exit 0
EOF
done
chmod +x "$BIN"/*.sh

invoke() {
  operation=$1
  request=$2
  printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" "$BIN/fm-api.sh" "$operation"
}

test_capabilities_are_one_versioned_json_object() {
  out=$(FM_HOME="$HOME_ROOT" "$BIN/fm-api.sh" capabilities) || fail "capabilities failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "capabilities emitted multiple lines"
  printf '%s\n' "$out" | jq -e '.schema == "fm-api-response.v1" and .result == "ok" and .postcondition_evidence.q_metadata == true' >/dev/null \
    || fail "capabilities response shape is invalid"
  pass "capabilities returns one versioned JSON object"
}

test_invalid_request_refuses_as_json() {
  out=$(printf '{}\n' | FM_HOME="$HOME_ROOT" "$BIN/fm-api.sh" worker.inspect)
  status=$?
  [ "$status" -eq 2 ] || fail "invalid request should return status 2"
  printf '%s\n' "$out" | jq -e '.result == "refused" and .error != null' >/dev/null \
    || fail "invalid request did not return a structured refusal"
  pass "invalid request returns a structured refusal"
}

test_prepare_delegates_and_renders_contract() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.prepare","idempotency_key":"prepare-1","task_id":"worker-1","repository_name":"repo","kind":"ship","mode":"local-only","captain_intent":"Fix it.","execution_spec":"Keep scope bounded."}'
  out=$(invoke worker.prepare "$request") || fail "worker.prepare failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null || fail "prepare response failed"
  grep -Fqx 'Fix it.' "$HOME_ROOT/data/worker-1/brief.md" || fail "captain intent was not rendered"
  grep -Fqx 'Keep scope bounded.' "$HOME_ROOT/data/worker-1/brief.md" || fail "execution spec was not rendered"
  pass "worker.prepare delegates and renders the Q contract"
}

test_spawn_requires_metadata_postcondition() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.spawn","idempotency_key":"spawn-1","task_id":"worker-1","repository":"/repo","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"low","q":{"root_task_id":"task-root","execution_id":"exec-1","parent_execution_id":"","lease_id":"lease-1","phase":"implementation","trace_id":""}}'
  out=$(invoke worker.spawn "$request") || fail "worker.spawn failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.task_id == "worker-1"' >/dev/null \
    || fail "spawn response lacks postcondition evidence"
  grep -Fqx 'q_lease_id=lease-1' "$HOME_ROOT/state/worker-1.meta" || fail "lease metadata is absent"
  pass "worker.spawn verifies additive Q metadata"
}

test_snapshot_inspect_and_lifecycle_delegation() {
  base='{"schema":"q.firstmate-request.v1","idempotency_key":"operation-1"'
  out=$(invoke fleet.snapshot "$base,"'"operation":"fleet.snapshot"}') || fail "snapshot failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.snapshot.schema == "fm-fleet-snapshot.v1"' >/dev/null \
    || fail "snapshot owner response was not preserved"
  out=$(invoke worker.inspect "$base,"'"operation":"worker.inspect","task_id":"worker-1"}') || fail "inspect failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.worker.id == "worker-1"' >/dev/null \
    || fail "inspect did not select the worker"
  out=$(invoke worker.send "$base,"'"operation":"worker.send","task_id":"worker-1","message":"continue"}' 2>"$TMP_ROOT/send.err") || fail "send failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null || fail "send response invalid"
  grep -F 'owner diagnostic' "$TMP_ROOT/send.err" >/dev/null || fail "owner diagnostics were not forwarded to stderr"
  out=$(invoke worker.control "$base,"'"operation":"worker.control","task_id":"worker-1","verb":"exit"}') || fail "control failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.confirmed == true' >/dev/null || fail "control was not confirmed"
  out=$(invoke worker.cleanup "$base,"'"operation":"worker.cleanup","task_id":"worker-1"}') || fail "cleanup failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.cleanup == "confirmed"' >/dev/null || fail "cleanup was not confirmed"
  pass "snapshot and worker lifecycle calls delegate through typed responses"
}

test_q_spawn_validation_is_opt_in_and_precedes_mutation() {
  home="$TMP_ROOT/real-home"
  mkdir -p "$home"
  out=$(FM_HOME="$home" FM_Q_MANAGED=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" q-invalid projects/missing --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "incomplete Q identity should be refused"
  printf '%s\n' "$out" | grep -F 'Q-managed spawn requires a safe non-empty FM_Q_ROOT_TASK_ID' >/dev/null \
    || fail "Q identity refusal was not explicit"
  [ ! -e "$home/state/q-invalid.meta" ] || fail "Q refusal created task metadata"

  out=$(FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" ordinary projects/missing --mode local-only --yolo off 2>&1)
  printf '%s\n' "$out" | grep -F 'FM_Q_ROOT_TASK_ID' >/dev/null \
    && fail "ordinary spawn activated Q validation"
  pass "Q validation is opt-in and refuses before task mutation"
}

test_capabilities_are_one_versioned_json_object
test_invalid_request_refuses_as_json
test_prepare_delegates_and_renders_contract
test_spawn_requires_metadata_postcondition
test_snapshot_inspect_and_lifecycle_delegation
test_q_spawn_validation_is_opt_in_and_precedes_mutation
