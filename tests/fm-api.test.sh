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
cp "$ROOT/bin/fm-q-guard-lib.sh" "$BIN/fm-q-guard-lib.sh"
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
  if printf '%s\n' "$*" | grep -F -- '--secondmate' >/dev/null; then
    printf 'home=%s\n' "$(cat "$home/state/q-supervisor-home")"
  fi
} >"$home/state/$id.meta"
EOF

cat >"$BIN/fm-home-seed.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
controller=${FM_HOME:?}
id=$1
home=$2
mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
printf '%s\n' "$id" >"$home/.fm-secondmate-home"
printf '%s\n' "$home" >"$controller/state/q-supervisor-home"
printf 'home=%s\n' "$home"
EOF

cat >"$BIN/fm-fleet-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","tasks":[{"id":"worker-1","current_state":{"state":"working"}},{"id":"supervisor-1","current_state":{"state":"working"}}]}'
EOF

for owner in fm-send.sh fm-control.sh fm-teardown.sh fm-merge-local.sh fm-pr-merge.sh; do
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
  printf '%s\n' "$out" | jq -e '.schema == "fm-api-response.v1" and .result == "ok" and .postcondition_evidence.q_metadata == true and .postcondition_evidence.q_spawn_guard == true' >/dev/null \
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
  request='{"schema":"q.firstmate-request.v1","operation":"worker.prepare","idempotency_key":"prepare-1","task_id":"worker-1","repository_name":"repo","kind":"ship","mode":"local-only","captain_intent":"Fix it.","execution_spec":"Keep scope bounded.","result_path":"'"$HOME_ROOT"'/data/worker-1/q-result.json","result_contract":{"schema":"q.worker-result.v1","root_task_id":"task-root","execution_id":"exec-worker","outcome":"completed|failed|blocked","summary":"string","artifacts":[],"investigation_report":null}}'
  out=$(invoke worker.prepare "$request") || fail "worker.prepare failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null || fail "prepare response failed"
  grep -Fqx 'Fix it.' "$HOME_ROOT/data/worker-1/brief.md" || fail "captain intent was not rendered"
  grep -Fqx 'Keep scope bounded.' "$HOME_ROOT/data/worker-1/brief.md" || fail "execution spec was not rendered"
  grep -F 'q.worker-result.v1' "$HOME_ROOT/data/worker-1/brief.md" >/dev/null \
    || fail "typed worker result contract was not rendered"
  pass "worker.prepare delegates and renders the Q contract"
}

test_worker_result_validates_durable_identity() {
  mkdir -p "$HOME_ROOT/data/worker-1" "$HOME_ROOT/state"
  printf '%s\n' 'q_root_task_id=task-root' 'q_execution_id=exec-worker' \
    >"$HOME_ROOT/state/worker-1.meta"
  printf '%s\n' '{"schema":"q.worker-result.v1","root_task_id":"task-root","execution_id":"exec-worker","outcome":"completed","summary":"done","artifacts":[],"investigation_report":null}' \
    >"$HOME_ROOT/data/worker-1/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.result","idempotency_key":"result-1","task_id":"worker-1"}'
  out=$(invoke worker.result "$request") || fail "worker.result failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.result.outcome == "completed"' >/dev/null \
    || fail "worker result evidence is invalid"
  pass "worker result validates durable Q identity"
}

test_spawn_requires_metadata_postcondition() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.spawn","idempotency_key":"spawn-1","task_id":"worker-1","repository":"/repo","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"low","q":{"root_task_id":"task-root","execution_id":"exec-1","parent_execution_id":"","lease_id":"lease-1","phase":"implementation","trace_id":"","depth":0,"expected_wall_seconds":300,"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
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

test_worker_relaunch_delegates_with_q_transport() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.relaunch","idempotency_key":"repair-1","task_id":"worker-1","note":"Repair failed validation.","q":{"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(invoke worker.relaunch "$request") || fail "worker.relaunch failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.relaunch == "confirmed"' >/dev/null \
    || fail "worker relaunch evidence is invalid"
  pass "worker relaunch delegates through the lifecycle owner"
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

test_q_guard_authorizes_propagates_and_releases() {
  calls="$TMP_ROOT/q-guard.calls"
  fake_q="$TMP_ROOT/fake-q"
  cat >"$fake_q" <<'EOF'
#!/usr/bin/env bash
set -eu
operation=${2:?}
printf '%s\n' "$operation" >>"${FM_Q_FAKE_CALLS:?}"
case "$operation" in
  authorize)
    request=$(cat)
    jq -e '.schema == "q.guard-authorize-request.v1" and .parent_execution_id == "exec-parent" and .external_task_id == "child-one" and .phase == "implementation"' >/dev/null <<<"$request"
    if [ "${FM_Q_FAKE_RESULT:-authorized}" = denied ]; then
      printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"denied","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":null,"external_task_id":"child-one","requested_depth":1,"lease_id":"lease-denied","lease_state":"denied","denial_reason":"workers_total_exhausted"}'
    else
      printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":"exec-child","external_task_id":"child-one","requested_depth":1,"lease_id":"lease-child","lease_state":"reserved","denial_reason":null}'
    fi
    ;;
  release)
    printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":"exec-child","external_task_id":"child-one","requested_depth":1,"lease_id":"lease-child","lease_state":"released","denial_reason":null}'
    ;;
  commit)
    printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":"exec-child","external_task_id":"child-one","requested_depth":1,"lease_id":"lease-child","lease_state":"committed","denial_reason":null}'
    ;;
  retry)
    if [ "${FM_Q_FAKE_RESULT:-authorized}" = denied ]; then
      printf '%s\n' '{"schema":"q.guard-retry-authorization.v1","result":"denied","root_task_id":"task-root","execution_id":"exec-child","idempotency_key":"firstmate-relaunch:exec-child:tx-one","denial_reason":"retry_budget_exhausted"}'
    else
      printf '%s\n' '{"schema":"q.guard-retry-authorization.v1","result":"authorized","root_task_id":"task-root","execution_id":"exec-child","idempotency_key":"firstmate-relaunch:exec-child:tx-one","denial_reason":null}'
    fi
    ;;
esac
EOF
  chmod +x "$fake_q"
  # Q identity mutations are intentionally confined to this test subshell.
  # shellcheck disable=SC2030
  (
    # shellcheck source=bin/fm-q-guard-lib.sh
    . "$BIN/fm-q-guard-lib.sh"
    export FM_Q_MANAGED=1 FM_Q_DELEGATION_ENABLED=1 FM_Q_PREAUTHORIZED=0
    export FM_Q_ROOT_TASK_ID=task-root FM_Q_EXECUTION_ID=exec-parent
    export FM_Q_EXPECTED_WALL_SECONDS=300 FM_Q_CLI="$fake_q"
    export FM_Q_DATA_DIR="$TMP_ROOT/q-data" FM_Q_FAKE_CALLS="$calls"
    fm_q_guard_authorize_child child-one ship codex model high || exit 1
    [ "$FM_Q_PARENT_EXECUTION_ID" = exec-parent ] || exit 1
    [ "$FM_Q_EXECUTION_ID" = exec-child ] || exit 1
    [ "$FM_Q_LEASE_ID" = lease-child ] || exit 1
    [ "$FM_Q_DEPTH" = 1 ] || exit 1
    fm_q_guard_release_child || exit 1
  ) || fail "Q guard did not propagate and release its authorization"
  [ "$(tr '\n' ' ' <"$calls")" = "authorize release " ] \
    || fail "Q guard did not use the expected authorization lifecycle"
  pass "Q guard propagates child identity and releases an aborted launch"
}

test_q_guard_authorizes_each_relaunch_transaction() {
  calls="$TMP_ROOT/q-guard-retry.calls"
  fake_q="$TMP_ROOT/fake-q"
  (
    # shellcheck source=bin/fm-q-guard-lib.sh
    . "$BIN/fm-q-guard-lib.sh"
    # shellcheck disable=SC2030,SC2031
    export FM_Q_MANAGED=1 FM_Q_ROOT_TASK_ID=task-root
    export FM_Q_EXECUTION_ID=exec-child FM_CONTROL_RELAUNCH_TX=tx-one
    # shellcheck disable=SC2030,SC2031
    export FM_Q_CLI="$fake_q" FM_Q_DATA_DIR="$TMP_ROOT/q-data"
    # shellcheck disable=SC2030,SC2031
    export FM_Q_FAKE_CALLS="$calls"
    fm_q_guard_authorize_relaunch
  ) || fail "Q guard did not authorize the relaunch transaction"
  [ "$(cat "$calls")" = retry ] || fail "Q guard did not call the retry boundary"
  pass "Q guard authorizes a durable relaunch transaction"
}

test_q_guard_refuses_denial_and_unavailable_contract() {
  calls="$TMP_ROOT/q-guard-denied.calls"
  fake_q="$TMP_ROOT/fake-q-denied"
  cp "$TMP_ROOT/fake-q" "$fake_q"
  chmod +x "$fake_q"
  # The denial case uses a fresh subshell and does not consume the prior case's identity.
  # shellcheck disable=SC2031
  out=$({
    # shellcheck disable=SC1091
    . "$BIN/fm-q-guard-lib.sh"
    export FM_Q_DELEGATION_ENABLED=1 FM_Q_PREAUTHORIZED=0
    export FM_Q_ROOT_TASK_ID=task-root FM_Q_EXECUTION_ID=exec-parent
    export FM_Q_EXPECTED_WALL_SECONDS=300 FM_Q_CLI="$fake_q"
    export FM_Q_DATA_DIR="$TMP_ROOT/q-data" FM_Q_FAKE_CALLS="$calls"
    export FM_Q_FAKE_RESULT=denied
    fm_q_guard_authorize_child child-one ship codex model high
  } 2>&1)
  status=$?
  [ "$status" -eq 3 ] || fail "Q budget denial should return status 3"
  printf '%s\n' "$out" | grep -F 'Q_GUARD_RESULT={"schema":"q.guard-authorization.v1","result":"denied"' >/dev/null \
    || fail "Q budget denial did not preserve the structured result"

  home="$TMP_ROOT/q-contract-home"
  mkdir -p "$home"
  out=$(FM_HOME="$home" FM_Q_MANAGED=1 FM_Q_DELEGATION_ENABLED=1 \
    FM_Q_ROOT_TASK_ID=task-root FM_Q_EXECUTION_ID=exec-parent FM_Q_LEASE_ID=lease-parent \
    FM_Q_PHASE=supervision FM_Q_CONTRACT_SCHEMA=q.worker-contract.v1 FM_Q_DEPTH=0 \
    FM_Q_EXPECTED_WALL_SECONDS=300 FM_Q_CLI=relative-q FM_Q_DATA_DIR="$TMP_ROOT/q-data" \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" child-one projects/missing \
    --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "relative Q command should be refused"
  printf '%s\n' "$out" | grep -F 'requires an absolute FM_Q_CLI' >/dev/null \
    || fail "Q contract refusal was not explicit"
  [ ! -e "$home/state/child-one.meta" ] || fail "Q contract refusal mutated task state"
  pass "Q guard refuses budget denial and an unavailable contract before mutation"
}

test_supervisor_operations_use_secondmate_owners_and_structured_events() {
  supervisor_home="$TMP_ROOT/supervisor-home"
  mkdir -p "$HOME_ROOT/projects/q-project"
  request='{"schema":"q.firstmate-request.v1","operation":"supervisor.prepare","idempotency_key":"supervisor-prepare-1","task_id":"supervisor-1","repository":"/repo","project_name":"q-project","supervisor_home":"'"$supervisor_home"'","root_task_id":"task-root","captain_intent":"Coordinate it.","execution_spec":"Remain bounded."}'
  out=$(invoke supervisor.prepare "$request") || fail "supervisor.prepare failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.reused == false' >/dev/null \
    || fail "supervisor prepare evidence is invalid"
  [ "$(cat "$supervisor_home/.fm-secondmate-home")" = supervisor-1 ] \
    || fail "supervisor home owner did not provision the home"

  request='{"schema":"q.firstmate-request.v1","operation":"supervisor.start","idempotency_key":"supervisor-start-1","task_id":"supervisor-1","repository":"/repo","supervisor_home":"'"$supervisor_home"'","harness":"codex","model":"default","effort":"high","q":{"root_task_id":"task-root","execution_id":"exec-supervisor","lease_id":"lease-supervisor","expected_wall_seconds":600,"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(invoke supervisor.start "$request") || fail "supervisor.start failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.task_id == "supervisor-1"' >/dev/null \
    || fail "supervisor start evidence is invalid"
  grep -Fqx "home=$supervisor_home" "$HOME_ROOT/state/supervisor-1.meta" \
    || fail "supervisor metadata did not retain its dedicated home"

  printf '%s\n' '{"schema":"q.supervisor-event.v1","sequence":1,"event":"accepted","root_task_id":"task-root","message":"accepted","data":{}}' \
    >"$supervisor_home/state/q-supervisor-events.jsonl"
  request='{"schema":"q.firstmate-request.v1","operation":"supervisor.inspect","idempotency_key":"supervisor-inspect-1","task_id":"supervisor-1","supervisor_home":"'"$supervisor_home"'"}'
  out=$(invoke supervisor.inspect "$request") || fail "supervisor.inspect failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.schema == "q.supervisor-snapshot.v1" and .postcondition_evidence.live == true and .postcondition_evidence.events[0].event == "accepted"' >/dev/null \
    || fail "supervisor inspect did not return versioned structured events"

  base='{"schema":"q.firstmate-request.v1","idempotency_key":"supervisor-operation-1"'
  out=$(invoke supervisor.send "$base,"'"operation":"supervisor.send","task_id":"supervisor-1","message":"continue"}') || fail "supervisor.send failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null || fail "supervisor send response invalid"
  out=$(invoke supervisor.stop "$base,"'"operation":"supervisor.stop","task_id":"supervisor-1"}') || fail "supervisor.stop failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.confirmed == true' >/dev/null \
    || fail "supervisor stop was not confirmed"
  pass "supervisor operations reuse secondmate owners and expose structured events"
}

test_delivery_delegates_to_confirming_merge_owner() {
  request='{"schema":"q.firstmate-request.v1","operation":"delivery.execute","idempotency_key":"delivery-1","task_id":"worker-1","action":"land","mode":"local-only"}'
  out=$(invoke delivery.execute "$request") || fail "local delivery failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.confirmed == true and .postcondition_evidence.action == "land"' >/dev/null \
    || fail "delivery did not return a confirmed postcondition"
  pass "delivery delegates to the confirming Firstmate merge owner"
}

test_capabilities_are_one_versioned_json_object
test_invalid_request_refuses_as_json
test_prepare_delegates_and_renders_contract
test_worker_result_validates_durable_identity
test_spawn_requires_metadata_postcondition
test_snapshot_inspect_and_lifecycle_delegation
test_worker_relaunch_delegates_with_q_transport
test_q_spawn_validation_is_opt_in_and_precedes_mutation
test_q_guard_authorizes_propagates_and_releases
test_q_guard_authorizes_each_relaunch_transaction
test_q_guard_refuses_denial_and_unavailable_contract
test_supervisor_operations_use_secondmate_owners_and_structured_events
test_delivery_delegates_to_confirming_merge_owner
