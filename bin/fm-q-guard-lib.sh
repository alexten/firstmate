#!/usr/bin/env bash
# Durable Quartermaster lease guard for Q-managed Firstmate child spawns.
# Source this library from the existing spawn owner only.
# It is inert unless FM_Q_DELEGATION_ENABLED=1 and FM_Q_PREAUTHORIZED is not 1.
# Authorization is obtained before endpoint or worktree creation.
# The caller owns the launch boundary and must commit after confirmed launch or
# release before launch delivery when an abort occurs.

fm_q_guard_child_phase() {  # <kind>
  case "$1" in
    scout) printf '%s\n' investigation ;;
    ship) printf '%s\n' implementation ;;
    *) return 1 ;;
  esac
}

fm_q_guard_child_role() {  # <kind>
  case "$1" in
    scout) printf '%s\n' investigator ;;
    ship) printf '%s\n' implementer ;;
    *) return 1 ;;
  esac
}

fm_q_guard_authorize_child() {  # <task-id> <kind> <harness> <model> <effort>
  local child_id=$1 kind=$2 harness=$3 model=$4 effort=$5
  local parent_execution phase role key request response result
  [ "${FM_Q_DELEGATION_ENABLED:-0}" = 1 ] || return 0
  [ "${FM_Q_PREAUTHORIZED:-0}" != 1 ] || return 0
  parent_execution=$FM_Q_EXECUTION_ID
  phase=$(fm_q_guard_child_phase "$kind") || {
    echo "error: Q guard supports only ship and scout children" >&2
    return 2
  }
  role=$(fm_q_guard_child_role "$kind") || return 2
  key="firstmate-child:$parent_execution:$child_id"
  request=$(jq -cn \
    --arg root "$FM_Q_ROOT_TASK_ID" \
    --arg parent "$parent_execution" \
    --arg external "$child_id" \
    --arg role "$role" \
    --arg harness "$harness" \
    --arg model "${model:-default}" \
    --arg effort "${effort:-default}" \
    --arg phase "$phase" \
    --arg key "$key" \
    --argjson wall "$FM_Q_EXPECTED_WALL_SECONDS" \
    '{schema:"q.guard-authorize-request.v1",root_task_id:$root,
      parent_execution_id:$parent,external_task_id:$external,
      requested_role:$role,harness:$harness,model:$model,effort:$effort,
      phase:$phase,expected_wall_seconds:$wall,idempotency_key:$key}') || return 1
  if ! response=$(printf '%s\n' "$request" | \
      "$FM_Q_CLI" guard authorize --data-dir "$FM_Q_DATA_DIR"); then
    echo "error: Q child authorization is unavailable; spawn refused before launch" >&2
    return 1
  fi
  if ! jq -e '
      type == "object" and .schema == "q.guard-authorization.v1" and
      (.result == "authorized" or .result == "denied") and
      (.lease_id | type == "string" and length > 0) and
      (.requested_depth | type == "number")
    ' >/dev/null 2>&1 <<<"$response"; then
    echo "error: Q child authorization returned an incompatible response" >&2
    return 1
  fi
  result=$(jq -r .result <<<"$response")
  if [ "$result" != authorized ]; then
    printf 'Q_GUARD_RESULT=%s\n' "$(jq -c . <<<"$response")" >&2
    echo "error: Q denied child $child_id before launch" >&2
    return 3
  fi
  export FM_Q_PARENT_EXECUTION_ID=$parent_execution
  FM_Q_EXECUTION_ID=$(jq -r .execution_id <<<"$response")
  export FM_Q_EXECUTION_ID
  FM_Q_LEASE_ID=$(jq -r .lease_id <<<"$response")
  export FM_Q_LEASE_ID
  FM_Q_DEPTH=$(jq -r .requested_depth <<<"$response")
  export FM_Q_DEPTH
  export FM_Q_PHASE=$phase
  FM_Q_GUARD_ACQUIRED=1
}

fm_q_guard_commit_child() {  # <external-task-id>
  local child_id=$1 response
  [ "${FM_Q_GUARD_ACQUIRED:-0}" = 1 ] || return 0
  if ! response=$("$FM_Q_CLI" guard commit \
      --data-dir "$FM_Q_DATA_DIR" \
      --lease-id "$FM_Q_LEASE_ID" \
      --execution-id "$FM_Q_EXECUTION_ID" \
      --external-task-id "$child_id"); then
    echo "error: Q could not confirm child lease $FM_Q_LEASE_ID after launch" >&2
    return 1
  fi
  jq -e '.schema == "q.guard-authorization.v1" and .lease_state == "committed"' \
    >/dev/null 2>&1 <<<"$response" || {
      echo "error: Q returned an incompatible child lease commit" >&2
      return 1
    }
  FM_Q_GUARD_COMMITTED=1
}

fm_q_guard_release_child() {
  local response
  [ "${FM_Q_GUARD_ACQUIRED:-0}" = 1 ] || return 0
  [ "${FM_Q_GUARD_COMMITTED:-0}" != 1 ] || return 0
  if ! response=$("$FM_Q_CLI" guard release \
      --data-dir "$FM_Q_DATA_DIR" \
      --lease-id "$FM_Q_LEASE_ID" \
      --execution-id "$FM_Q_EXECUTION_ID"); then
    echo "warning: Q child lease $FM_Q_LEASE_ID could not be released; recovery must reconcile it" >&2
    return 1
  fi
  jq -e '.schema == "q.guard-authorization.v1" and .lease_state == "released"' \
    >/dev/null 2>&1 <<<"$response" || {
      echo "warning: Q returned an incompatible child lease release" >&2
      return 1
    }
  FM_Q_GUARD_ACQUIRED=0
}

fm_q_guard_authorize_relaunch() {
  local key response result
  [ "${FM_Q_MANAGED:-0}" = 1 ] || return 0
  if [ -z "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "error: Q-managed relaunch requires a durable Firstmate relaunch transaction" >&2
    return 1
  fi
  if [ -n "${FM_Q_RELAUNCH_IDEMPOTENCY_KEY:-}" ]; then
    key="firstmate-relaunch:$FM_Q_EXECUTION_ID:$FM_Q_RELAUNCH_IDEMPOTENCY_KEY"
  else
    key="firstmate-relaunch:$FM_Q_EXECUTION_ID:$FM_CONTROL_RELAUNCH_TX"
  fi
  if ! response=$("$FM_Q_CLI" guard retry \
      --data-dir "$FM_Q_DATA_DIR" \
      --root-task-id "$FM_Q_ROOT_TASK_ID" \
      --execution-id "$FM_Q_EXECUTION_ID" \
      --idempotency-key "$key"); then
    echo "error: Q retry authorization is unavailable; relaunch refused before launch" >&2
    return 1
  fi
  if ! jq -e '
      type == "object" and .schema == "q.guard-retry-authorization.v1" and
      (.result == "authorized" or .result == "denied") and
      .root_task_id == $root and .execution_id == $execution and
      (.idempotency_key | type == "string" and length > 0)
    ' --arg root "$FM_Q_ROOT_TASK_ID" --arg execution "$FM_Q_EXECUTION_ID" \
      >/dev/null 2>&1 <<<"$response"; then
    echo "error: Q retry authorization returned an incompatible response" >&2
    return 1
  fi
  result=$(jq -r .result <<<"$response")
  if [ "$result" != authorized ]; then
    printf 'Q_GUARD_RESULT=%s\n' "$(jq -c . <<<"$response")" >&2
    echo "error: Q denied relaunch of $FM_Q_EXECUTION_ID before launch" >&2
    return 3
  fi
}
