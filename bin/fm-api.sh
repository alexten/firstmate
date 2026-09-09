#!/usr/bin/env bash
# Versioned machine-readable facade for Quartermaster.
# Usage: fm-api.sh capabilities
#        fm-api.sh <operation> < request.json
# Supported operations are fleet.snapshot, worker lifecycle, supervisor
# prepare/start/send/inspect/stop, and approved delivery execution.
# Requests use schema q.firstmate-request.v1 and must name the invoked operation.
# Successful stdout contains exactly one fm-api-response.v1 JSON object.
# Owner diagnostics are forwarded to stderr and never mixed into the response.
# The facade adds no lifecycle policy: it delegates briefs, spawn, observation,
# messages, control, and cleanup to their existing script owners.
# worker.cleanup never exposes forced discard; exact discard authority remains
# outside this facade and ordinary non-Q Firstmate behavior remains unchanged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
OPERATION=${1:-}
REQUEST_FILE=
OWNER_OUT=
OWNER_ERR=

cleanup() {
  [ -z "$REQUEST_FILE" ] || rm -f "$REQUEST_FILE"
  [ -z "$OWNER_OUT" ] || rm -f "$OWNER_OUT"
  [ -z "$OWNER_ERR" ] || rm -f "$OWNER_ERR"
}
trap cleanup EXIT HUP INT TERM

respond() {
  result=$1
  evidence=${2:-null}
  error=${3:-null}
  next=${4:-null}
  jq -cn \
    --arg operation "$OPERATION" \
    --arg result "$result" \
    --arg idempotency_key "${IDEMPOTENCY_KEY:-}" \
    --argjson evidence "$evidence" \
    --argjson error "$error" \
    --argjson recoverable_next_action "$next" \
    '{schema:"fm-api-response.v1", operation:$operation, result:$result,
      idempotency_key:$idempotency_key, external_identifiers:{},
      postcondition_evidence:$evidence, error:$error,
      recoverable_next_action:$recoverable_next_action}'
}

require_tools() {
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' 'error: jq is required by fm-api' >&2
    exit 127
  }
}

run_owner() {
  OWNER_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-api-out.XXXXXX")
  OWNER_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-api-err.XXXXXX")
  if "$@" >"$OWNER_OUT" 2>"$OWNER_ERR"; then
    cat "$OWNER_ERR" >&2
    return 0
  else
    owner_rc=$?
  fi
  cat "$OWNER_ERR" >&2
  guard_result=$(sed -n 's/^Q_GUARD_RESULT=//p' "$OWNER_ERR" | tail -n 1)
  if [ -n "$guard_result" ] && jq -e '
      .schema == "q.guard-authorization.v1" or
      .schema == "q.guard-retry-authorization.v1"
    ' \
      >/dev/null 2>&1 <<<"$guard_result"; then
    respond refused "$(jq -cn --argjson guard "$guard_result" '{guard:$guard}')" \
      '"Quartermaster denied the guarded operation"' '"reduce or revise the root envelope"'
    return "$owner_rc"
  fi
  owner_error=$(jq -Rs . <"$OWNER_ERR")
  respond error null "$owner_error" '"inspect owner diagnostics and retry only after reconciliation"'
  return "$owner_rc"
}

require_tools
case "$OPERATION" in
  capabilities)
    revision=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)
    jq -cn --arg operation "$OPERATION" --arg revision "$revision" \
      '{schema:"fm-api-response.v1",operation:$operation,result:"ok",idempotency_key:"",
        external_identifiers:{firstmate_revision:$revision},postcondition_evidence:{
          facade_schemas:["fm-api-response.v1"],request_schemas:["q.firstmate-request.v1"],
          harnesses:["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","omp","muse","gemini","rovo"],
          backends:["tmux","herdr","zellij","orca","cmux"],
          controls:["interrupt","exit","relaunch"],q_metadata:true,q_spawn_guard:true,
          delivery_modes:["local-only","direct-PR","no-mistakes"],
          fleet_snapshot_schema:"fm-fleet-snapshot.v1"},error:null,recoverable_next_action:null}'
    exit 0
    ;;
  fleet.snapshot|worker.prepare|worker.spawn|worker.inspect|worker.result|worker.send|worker.control|worker.relaunch|worker.cleanup|supervisor.prepare|supervisor.start|supervisor.send|supervisor.inspect|supervisor.stop|delivery.execute) ;;
  *)
    OPERATION=${OPERATION:-unknown}
    respond refused null '"unsupported operation"' null
    exit 2
    ;;
esac

REQUEST_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-api-request.XXXXXX")
cat >"$REQUEST_FILE"
if ! jq -e --arg operation "$OPERATION" \
  'type == "object" and .schema == "q.firstmate-request.v1" and .operation == $operation and
   (.idempotency_key | type == "string" and length > 0)' "$REQUEST_FILE" >/dev/null; then
  respond refused null '"invalid request schema, operation, or idempotency key"' null
  exit 2
fi
IDEMPOTENCY_KEY=$(jq -r .idempotency_key "$REQUEST_FILE")

case "$OPERATION" in
  fleet.snapshot)
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json || exit $?
    if ! jq -e '.schema == "fm-fleet-snapshot.v1"' "$OWNER_OUT" >/dev/null; then
      respond error null '"fleet owner returned an incompatible snapshot"' '"run capabilities and reconcile Firstmate version"'
      exit 1
    fi
    respond ok "$(jq -c '{snapshot:.}' "$OWNER_OUT")"
    ;;
  worker.inspect)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json || exit $?
    task=$(jq -c --arg id "$task_id" '[.tasks[] | select(.id == $id)][0] // null' "$OWNER_OUT")
    if [ "$task" = null ]; then
      respond refused null '"worker is not present in the current snapshot"' '"reconcile the recorded external identity"'
      exit 3
    fi
    respond ok "$(jq -cn --argjson task "$task" '{worker:$task}')"
    ;;
  worker.result)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    meta="$FM_HOME/state/$task_id.meta"
    result_path="$FM_HOME/data/$task_id/q-result.json"
    [ -f "$meta" ] || { respond refused null '"worker metadata is missing"' null; exit 3; }
    [ -f "$result_path" ] || { respond refused null '"worker result is missing"' '"wait for a terminal worker result"'; exit 3; }
    q_root=$(sed -n 's/^q_root_task_id=//p' "$meta")
    q_execution=$(sed -n 's/^q_execution_id=//p' "$meta")
    if ! jq -e --arg root "$q_root" --arg execution "$q_execution" '
        type == "object" and .schema == "q.worker-result.v1" and
        .root_task_id == $root and .execution_id == $execution and
        (.outcome == "completed" or .outcome == "failed" or .outcome == "blocked") and
        (.summary | type == "string") and (.artifacts | type == "array")
      ' "$result_path" >/dev/null 2>&1; then
      respond refused null '"worker result is invalid or belongs to another execution"' '"preserve and repair the typed result"'
      exit 3
    fi
    result=$(jq -c . "$result_path")
    respond ok "$(jq -cn --arg path "$result_path" --argjson result "$result" '{result:$result,path:$path}')"
    ;;
  worker.prepare)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    repo_name=$(jq -r '.repository_name // empty' "$REQUEST_FILE")
    kind=$(jq -r '.kind // "ship"' "$REQUEST_FILE")
    mode=$(jq -r '.mode // empty' "$REQUEST_FILE")
    case "$kind" in
      ship) run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-brief.sh" "$task_id" "$repo_name" --mode "$mode" || exit $? ;;
      scout) run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-brief.sh" "$task_id" "$repo_name" --scout || exit $? ;;
      *) respond refused null '"worker kind must be ship or scout"' null; exit 2 ;;
    esac
    brief="$FM_HOME/data/$task_id/brief.md"
    python3 - "$REQUEST_FILE" "$brief" <<'PY'
import json
import os
import sys

request_path, brief_path = sys.argv[1:]
with open(request_path, encoding="utf-8") as stream:
    request = json.load(stream)
with open(brief_path, encoding="utf-8") as stream:
    brief = stream.read()
brief = brief.replace("{TASK}", request["captain_intent"])
brief = brief.replace("{FIRSTMATE_SPEC}", request["execution_spec"])
brief += "\n## Machine-readable result\n\n"
brief += "Before reporting a terminal status, atomically write strict JSON to `"
brief += request["result_path"] + "` matching this contract:\n\n```json\n"
brief += json.dumps(request["result_contract"], indent=2) + "\n```\n"
temporary = brief_path + ".q-tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    stream.write(brief)
os.replace(temporary, brief_path)
PY
    respond ok "$(jq -cn --arg brief "$brief" '{brief_path:$brief}')"
    ;;
  worker.spawn)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    repository=$(jq -r '.repository // empty' "$REQUEST_FILE")
    mode=$(jq -r '.mode // empty' "$REQUEST_FILE")
    yolo=$(jq -r '.yolo // "off"' "$REQUEST_FILE")
    harness=$(jq -r '.harness // empty' "$REQUEST_FILE")
    model=$(jq -r '.model // empty' "$REQUEST_FILE")
    effort=$(jq -r '.effort // empty' "$REQUEST_FILE")
    q_root=$(jq -r '.q.root_task_id // empty' "$REQUEST_FILE")
    q_execution=$(jq -r '.q.execution_id // empty' "$REQUEST_FILE")
    q_parent=$(jq -r '.q.parent_execution_id // empty' "$REQUEST_FILE")
    q_lease=$(jq -r '.q.lease_id // empty' "$REQUEST_FILE")
    q_phase=$(jq -r '.q.phase // empty' "$REQUEST_FILE")
    q_trace=$(jq -r '.q.trace_id // empty' "$REQUEST_FILE")
    q_depth=$(jq -r '.q.depth // 0' "$REQUEST_FILE")
    q_wall=$(jq -r '.q.expected_wall_seconds // 1' "$REQUEST_FILE")
    q_cli=$(jq -r '.q.guard_executable // empty' "$REQUEST_FILE")
    q_data_dir=$(jq -r '.q.data_dir // empty' "$REQUEST_FILE")
    if [ -z "$q_cli" ] || [ -z "$q_data_dir" ]; then
      respond refused null '"Q-managed workers require a durable guard executable and data directory"' null
      exit 2
    fi
    q_delegation=1
    run_owner env FM_HOME="$FM_HOME" FM_Q_MANAGED=1 FM_Q_PREAUTHORIZED=1 \
      FM_Q_ROOT_TASK_ID="$q_root" FM_Q_EXECUTION_ID="$q_execution" \
      FM_Q_PARENT_EXECUTION_ID="$q_parent" FM_Q_LEASE_ID="$q_lease" \
      FM_Q_PHASE="$q_phase" FM_Q_CONTRACT_SCHEMA=q.worker-contract.v1 \
      FM_Q_TRACE_ID="$q_trace" FM_Q_DEPTH="$q_depth" \
      FM_Q_DELEGATION_ENABLED="$q_delegation" FM_Q_EXPECTED_WALL_SECONDS="$q_wall" \
      FM_Q_CLI="$q_cli" FM_Q_DATA_DIR="$q_data_dir" \
      "$SCRIPT_DIR/fm-spawn.sh" "$task_id" "$repository" \
      --mode "$mode" --yolo "$yolo" --harness "$harness" --model "$model" --effort "$effort" || exit $?
    meta="$FM_HOME/state/$task_id.meta"
    if [ ! -f "$meta" ] || ! grep -Fqx "q_lease_id=$q_lease" "$meta"; then
      respond partial null '"worker launched but Q metadata postcondition is missing"' '"inspect the worker before retrying"'
      exit 4
    fi
    respond ok "$(jq -cn --arg task_id "$task_id" --arg meta "$meta" '{task_id:$task_id,metadata_path:$meta}')"
    ;;
  worker.send)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    message=$(jq -r '.message // empty' "$REQUEST_FILE")
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$task_id" "$message" || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,delivery:"durably_recorded"}')"
    ;;
  worker.control)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    verb=$(jq -r '.verb // empty' "$REQUEST_FILE")
    case "$verb" in interrupt|exit) ;; *) respond refused null '"unsupported control verb"' null; exit 2 ;; esac
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$task_id" "$verb" || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" --arg verb "$verb" '{task_id:$task_id,control:$verb,confirmed:true}')"
    ;;
  worker.relaunch)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    note=$(jq -r '.note // empty' "$REQUEST_FILE")
    relaunch_key=$(jq -r '.idempotency_key // empty' "$REQUEST_FILE")
    q_cli=$(jq -r '.q.guard_executable // empty' "$REQUEST_FILE")
    q_data_dir=$(jq -r '.q.data_dir // empty' "$REQUEST_FILE")
    [ -n "$note" ] && [ -n "$q_cli" ] && [ -n "$q_data_dir" ] || {
      respond refused null '"worker relaunch requires a note and Q guard transport"' null
      exit 2
    }
    run_owner env FM_HOME="$FM_HOME" FM_Q_CLI="$q_cli" FM_Q_DATA_DIR="$q_data_dir" \
      FM_Q_RELAUNCH_IDEMPOTENCY_KEY="$relaunch_key" \
      "$SCRIPT_DIR/fm-control.sh" "$task_id" relaunch --note "$note" || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,relaunch:"confirmed"}')"
    ;;
  worker.cleanup)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$task_id" || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,cleanup:"confirmed"}')"
    ;;
  supervisor.prepare)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    project_name=$(jq -r '.project_name // empty' "$REQUEST_FILE")
    supervisor_home=$(jq -r '.supervisor_home // empty' "$REQUEST_FILE")
    root_task_id=$(jq -r '.root_task_id // empty' "$REQUEST_FILE")
    captain_intent=$(jq -r '.captain_intent // empty' "$REQUEST_FILE")
    execution_spec=$(jq -r '.execution_spec // empty' "$REQUEST_FILE")
    case "$supervisor_home" in /*) ;; *) respond refused null '"supervisor_home must be absolute"' null; exit 2 ;; esac
    case "$project_name" in ''|*[!A-Za-z0-9._-]*) respond refused null '"invalid supervisor project name"' null; exit 2 ;; esac
    [ -d "$FM_HOME/projects/$project_name" ] || {
      respond refused null '"supervisor project mirror is missing"' '"prepare the isolated controller mirror and retry"'
      exit 2
    }
    if [ -f "$supervisor_home/.fm-secondmate-home" ] \
       && [ "$(cat "$supervisor_home/.fm-secondmate-home")" = "$task_id" ]; then
      respond ok "$(jq -cn --arg home "$supervisor_home" --arg events "$supervisor_home/state/q-supervisor-events.jsonl" '{supervisor_home:$home,events_path:$events,reused:true}')"
      exit 0
    fi
    charter=$(printf '%s\n\n%s\n\n%s\n' "$captain_intent" "$execution_spec" \
      "Write only q.supervisor-event.v1 JSON objects, one per line with consecutive sequence numbers, to state/q-supervisor-events.jsonl. Every event must carry root_task_id=$root_task_id. Use accepted, child_proposed, child_lease_denied, decision_required, blocked, validation_ready, delivery_ready, failed, or completed. Q alone authorizes child leases, budgets, validation, and delivery.")
    run_owner env FM_HOME="$FM_HOME" FM_SECONDMATE_CHARTER="$charter" \
      FM_SECONDMATE_SCOPE="Quartermaster root $root_task_id only." \
      "$SCRIPT_DIR/fm-home-seed.sh" "$task_id" "$supervisor_home" "$project_name" || exit $?
    respond ok "$(jq -cn --arg home "$supervisor_home" --arg events "$supervisor_home/state/q-supervisor-events.jsonl" '{supervisor_home:$home,events_path:$events,reused:false}')"
    ;;
  supervisor.start)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    supervisor_home=$(jq -r '.supervisor_home // empty' "$REQUEST_FILE")
    harness=$(jq -r '.harness // empty' "$REQUEST_FILE")
    model=$(jq -r '.model // empty' "$REQUEST_FILE")
    effort=$(jq -r '.effort // empty' "$REQUEST_FILE")
    q_root=$(jq -r '.q.root_task_id // empty' "$REQUEST_FILE")
    q_execution=$(jq -r '.q.execution_id // empty' "$REQUEST_FILE")
    q_lease=$(jq -r '.q.lease_id // empty' "$REQUEST_FILE")
    q_wall=$(jq -r '.q.expected_wall_seconds // empty' "$REQUEST_FILE")
    q_cli=$(jq -r '.q.guard_executable // empty' "$REQUEST_FILE")
    q_data_dir=$(jq -r '.q.data_dir // empty' "$REQUEST_FILE")
    [ -n "$q_cli" ] && [ -n "$q_data_dir" ] || {
      respond refused null '"supervisor requires the Q child guard transport"' null
      exit 2
    }
    run_owner env FM_HOME="$FM_HOME" FM_Q_MANAGED=1 FM_Q_PREAUTHORIZED=1 \
      FM_Q_ROOT_TASK_ID="$q_root" FM_Q_EXECUTION_ID="$q_execution" \
      FM_Q_LEASE_ID="$q_lease" FM_Q_PHASE=supervision FM_Q_DEPTH=0 \
      FM_Q_CONTRACT_SCHEMA=q.worker-contract.v1 FM_Q_DELEGATION_ENABLED=1 \
      FM_Q_EXPECTED_WALL_SECONDS="$q_wall" FM_Q_CLI="$q_cli" FM_Q_DATA_DIR="$q_data_dir" \
      "$SCRIPT_DIR/fm-spawn.sh" "$task_id" --secondmate --harness "$harness" \
      --model "$model" --effort "$effort" || exit $?
    meta="$FM_HOME/state/$task_id.meta"
    if [ ! -f "$meta" ] || ! grep -Fqx "home=$supervisor_home" "$meta" \
       || ! grep -Fqx "q_lease_id=$q_lease" "$meta"; then
      respond partial null '"supervisor launched but metadata confirmation is incomplete"' '"inspect before retrying"'
      exit 4
    fi
    respond ok "$(jq -cn --arg task_id "$task_id" --arg home "$supervisor_home" '{task_id:$task_id,supervisor_home:$home}')"
    ;;
  supervisor.inspect)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    supervisor_home=$(jq -r '.supervisor_home // empty' "$REQUEST_FILE")
    meta="$FM_HOME/state/$task_id.meta"
    [ -f "$meta" ] || { respond refused null '"supervisor metadata is missing"' '"reconcile the supervisor launch"'; exit 3; }
    root_task_id=$(sed -n 's/^q_root_task_id=//p' "$meta")
    [ -n "$root_task_id" ] || { respond error null '"supervisor Q root metadata is missing"' null; exit 1; }
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json || exit $?
    task=$(jq -c --arg id "$task_id" '[.tasks[] | select(.id == $id)][0] // null' "$OWNER_OUT")
    live=false
    [ "$task" = null ] || live=true
    events_file="$supervisor_home/state/q-supervisor-events.jsonl"
    events='[]'
    if [ -s "$events_file" ]; then
      if ! events=$(jq -sc --arg root "$root_task_id" '
          if all(.[]; .schema == "q.supervisor-event.v1" and
            .root_task_id == $root and (.sequence | type == "number")) then .
          else error("invalid supervisor event stream") end
        ' "$events_file" 2>/dev/null); then
        respond error null '"supervisor event stream is invalid"' '"preserve the stream and reconcile it"'
        exit 1
      fi
    fi
    respond ok "$(jq -cn --arg root "$root_task_id" --arg external "$task_id" \
      --argjson live "$live" --argjson events "$events" \
      '{schema:"q.supervisor-snapshot.v1",root_task_id:$root,external_id:$external,live:$live,events:$events}')"
    ;;
  supervisor.send)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    message=$(jq -r '.message // empty' "$REQUEST_FILE")
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$task_id" "$message" || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,delivery:"durably_recorded"}')"
    ;;
  supervisor.stop)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$task_id" exit || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,control:"exit",confirmed:true}')"
    ;;
  delivery.execute)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    action=$(jq -r '.action // empty' "$REQUEST_FILE")
    mode=$(jq -r '.mode // empty' "$REQUEST_FILE")
    case "$action:$mode" in
      land:local-only)
        run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-local.sh" "$task_id" || exit $?
        ;;
      merge:direct-PR|merge:no-mistakes)
        meta="$FM_HOME/state/$task_id.meta"
        [ -f "$meta" ] || { respond refused null '"delivery metadata is missing"' null; exit 3; }
        pr_url=$(sed -n 's/^pr=//p' "$meta")
        [ -n "$pr_url" ] || { respond refused null '"task has no recorded pull request"' '"wait for PR-ready evidence"'; exit 3; }
        run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-pr-merge.sh" "$task_id" "$pr_url" || exit $?
        ;;
      *) respond refused null '"delivery action and mode are incompatible"' null; exit 2 ;;
    esac
    owner_output=$(jq -Rs . <"$OWNER_OUT")
    respond ok "$(jq -cn --arg task_id "$task_id" --arg action "$action" \
      --arg mode "$mode" --argjson owner_output "$owner_output" \
      '{task_id:$task_id,action:$action,mode:$mode,confirmed:true,owner_output:$owner_output}')"
    ;;
esac
