#!/usr/bin/env bash
# Versioned machine-readable facade for Quartermaster.
# Usage: fm-api.sh capabilities
#        fm-api.sh <operation> < request.json
# Supported operations are fleet.snapshot, worker.prepare, worker.spawn,
# worker.inspect, worker.send, worker.control, and worker.cleanup.
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
  fi
  owner_rc=$?
  cat "$OWNER_ERR" >&2
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
          controls:["interrupt","exit","relaunch"],q_metadata:true,q_spawn_guard:false,
          delivery_modes:["local-only","direct-PR","no-mistakes"],
          fleet_snapshot_schema:"fm-fleet-snapshot.v1"},error:null,recoverable_next_action:null}'
    exit 0
    ;;
  fleet.snapshot|worker.prepare|worker.spawn|worker.inspect|worker.send|worker.control|worker.cleanup) ;;
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
    run_owner env FM_HOME="$FM_HOME" FM_Q_MANAGED=1 \
      FM_Q_ROOT_TASK_ID="$q_root" FM_Q_EXECUTION_ID="$q_execution" \
      FM_Q_PARENT_EXECUTION_ID="$q_parent" FM_Q_LEASE_ID="$q_lease" \
      FM_Q_PHASE="$q_phase" FM_Q_CONTRACT_SCHEMA=q.worker-contract.v1 \
      FM_Q_TRACE_ID="$q_trace" "$SCRIPT_DIR/fm-spawn.sh" "$task_id" "$repository" \
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
  worker.cleanup)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$task_id" || exit $?
    respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,cleanup:"confirmed"}')"
    ;;
esac
