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
      (.requested_depth | type == "number") and
      (if .result == "authorized" then
         (.result_contract.schema == "q.worker-result.v2" or
          .result_contract.schema == "q.worker-result.v3") and
         (.result_contract.observed_repository | type == "string")
       else true end)
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
  FM_Q_RESULT_CONTRACT=$(jq -c .result_contract <<<"$response")
  export FM_Q_RESULT_CONTRACT
  FM_Q_GUARD_ACQUIRED=1
}

fm_q_guard_append_child_result_contract() {  # <task-id>
  local child_id=$1 brief result_path opaque_root opaque_record selection selection_path
  local selection_tmp
  [ "${FM_Q_GUARD_ACQUIRED:-0}" = 1 ] || return 0
  [ -n "${FM_Q_RESULT_CONTRACT:-}" ] || return 1
  brief="$DATA/$child_id/brief.md"
  result_path="$DATA/$child_id/q-result.json"
  [ -f "$brief" ] || return 1
  if jq -e '.opaque_no_mistakes != null' >/dev/null 2>&1 <<<"$FM_Q_RESULT_CONTRACT"; then
    opaque_root=$(jq -r '.root_task_id' <<<"$FM_Q_RESULT_CONTRACT")
    opaque_record="$DATA/q-opaque-no-mistakes/$opaque_root.json"
    [ -f "$opaque_record" ] || {
      echo "error: selected opaque custodian has no durable supervisor instruction" >&2
      return 1
    }
    selection_path="$DATA/q-opaque-no-mistakes/$opaque_root-selection.json"
    selection=$(jq -cn --arg root "$opaque_root" --arg execution "$FM_Q_EXECUTION_ID" \
      --arg external "$child_id" --slurpfile accepted "$opaque_record" \
      '{schema:"fm.opaque-custodian-selection.v1",root_task_id:$root,
        opaque_operation_id:$accepted[0].opaque_operation_id,
        execution_id:$execution,external_task_id:$external}') || return 1
    if [ -f "$selection_path" ]; then
      [ "$(jq -S -c . <<<"$selection")" = "$(jq -S -c . "$selection_path" 2>/dev/null)" ] || {
        echo "error: opaque custodian selection conflicts with its durable record" >&2
        return 1
      }
    else
      selection_tmp=$(mktemp "$DATA/q-opaque-no-mistakes/.selection.XXXXXX") || return 1
      printf '%s\n' "$selection" >"$selection_tmp"
      chmod 600 "$selection_tmp"
      mv "$selection_tmp" "$selection_path"
    fi
  fi
  python3 - "$brief" "$result_path" "$FM_Q_RESULT_CONTRACT" <<'PY'
import json
import os
import sys

brief_path, result_path, serialized = sys.argv[1:]
contract = json.loads(serialized)
with open(brief_path, encoding="utf-8") as stream:
    brief = stream.read()
brief += "\n## Quartermaster delegated-child completion override\n\n"
brief += "This is a Q-authorized child. q-result.json is the sole completion handoff. "
brief += "Do not use captain-hold, tasks-axi, delivery, teardown, or a Firstmate "
brief += "completion gate. Their absence is not a blocker. After all intended commits, "
brief += "run `git rev-parse HEAD` immediately before serialization and record that full "
brief += "revision; record `pwd -P` separately as worktree and copy observed_repository "
brief += "exactly from the contract. Generate with a JSON serializer, validate with "
brief += "`jq -e .`, then atomically publish strict JSON to `" + result_path + "`:\n\n"
brief += "```json\n" + json.dumps(contract, indent=2) + "\n```\n"
if contract.get("opaque_no_mistakes"):
    brief += "The operator explicitly accepted this task's ungoverned compatibility path. "
    brief += "You are the single selected implementation custodian. Complete the ordinary "
    brief += "no-mistakes workflow before publishing the final result claim. Never pass "
    brief += "--yes or -y, never answer a question automatically, and never merge. "
    brief += "Quartermaster will observe final repository and PR identity separately and "
    brief += "does not attest provider internals or shutdown.\n"
temporary = brief_path + ".q-result-tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    stream.write(brief)
os.replace(temporary, brief_path)
PY
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
