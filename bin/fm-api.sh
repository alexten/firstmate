#!/usr/bin/env bash
# Versioned machine-readable facade for Quartermaster.
# Usage: fm-api.sh capabilities
#        fm-api.sh <operation> < request.json
# Supported operations are fleet.snapshot, worker lifecycle and read-only
# terminal capture, supervisor prepare/start/send/inspect/stop, and approved
# delivery execution.
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
  fleet.snapshot|worker.prepare|worker.spawn|worker.inspect|worker.capture|worker.result|worker.send|worker.control|worker.relaunch|worker.cleanup|supervisor.prepare|supervisor.start|supervisor.send|supervisor.inspect|supervisor.stop|delivery.execute) ;;
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
      absent=$(jq -cn --arg task_id "$task_id" \
        '{schema:"fm-worker-observation.v1",task_id:$task_id,present:false,snapshot_schema:"fm-fleet-snapshot.v1"}')
      respond refused "$absent" '"worker is not present in the current snapshot"' '"reconcile the recorded external identity"'
      exit 3
    fi
    respond ok "$(jq -cn --argjson task "$task" '{worker:$task}')"
    ;;
  worker.capture)
    task_id=$(jq -r '.task_id // empty' "$REQUEST_FILE")
    if ! jq -e '(.lines // 200) | type == "number" and . == floor and . >= 1 and . <= 500' \
        "$REQUEST_FILE" >/dev/null; then
      respond refused null '"capture lines must be an integer from 1 through 500"' null
      exit 2
    fi
    lines=$(jq -r '.lines // 200' "$REQUEST_FILE")
    meta="$FM_HOME/state/$task_id.meta"
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    if ! fm_backend_validate_task_endpoint "$meta" "$task_id"; then
      respond refused null '"recorded worker endpoint is missing or invalid"' '"retain the control plane and inspect Firstmate diagnostics"'
      exit 3
    fi
    backend=$FM_BACKEND_VALIDATED_BACKEND
    target=$FM_BACKEND_VALIDATED_TARGET
    run_owner fm_backend_capture_ansi "$backend" "$target" "$lines" "fm-$task_id" || exit $?
    frame_bytes=$(wc -c <"$OWNER_OUT" | tr -d ' ')
    truncated=false
    [ "$frame_bytes" -le 262144 ] || truncated=true
    frame=$(head -c 262144 "$OWNER_OUT" | jq -Rs .)
    respond ok "$(jq -cn --arg task_id "$task_id" --arg backend "$backend" \
      --argjson lines "$lines" --argjson frame "$frame" --argjson truncated "$truncated" \
      '{schema:"fm-terminal-frame.v1",task_id:$task_id,backend:$backend,
        styled:true,max_lines:$lines,content:$frame,truncated:$truncated}')"
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
        type == "object" and
        (.schema == "q.worker-result.v1" or .schema == "q.worker-result.v2") and
        .root_task_id == $root and .execution_id == $execution and
        (.outcome == "completed" or .outcome == "failed" or .outcome == "blocked") and
        (.summary | type == "string") and (.artifacts | type == "array") and
        ((.investigation_report == null) or
         ((.investigation_report | type) == "object" and
          .investigation_report.schema == "q.investigation-report.v1" and
          (.investigation_report.summary | type) == "string" and
          (.investigation_report.material_facts | type) == "array" and
          all(.investigation_report.material_facts[];
            (.kind | type) == "string" and (.summary | type) == "string" and
            ((.fact_id == null) or ((.fact_id | type) == "string"))) and
          (.investigation_report.remaining_unknowns | type) == "array" and
          all(.investigation_report.remaining_unknowns[]; type == "string") and
          (.investigation_report.recommended_implementation | type) == "array" and
          all(.investigation_report.recommended_implementation[]; type == "string") and
          (.investigation_report.authority_expansion_required | type) == "boolean")) and
        (if .schema == "q.worker-result.v2" then
          (.evidence | type == "array") and
          all(.evidence[];
            (.kind == "request" or .kind == "repository" or
             .kind == "command" or .kind == "test" or
             .kind == "analysis" or .kind == "artifact") and
            (.summary | type == "string") and
            ((.command == null) or
             ((.command | type == "object") and
              (.command.argv | type == "array") and
              (.command.exit_status | type == "number") and
              (.command.output | type == "string") and
              (.command.working_directory | type == "string")))) and
          (.observed_repository | type == "string") and
          (.observed_revision | type == "string") and
          (.worktree | type == "string") and
          ((.branch == null) or (.branch | type == "string")) and
          (.completed_at | type == "string")
        else true end)
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
brief += "\n## Quartermaster completion override\n\n"
brief += "This is a Q-managed worker. The machine-readable q-result.json below is the "
brief += "sole completion handoff. Do not call captain-hold, tasks-axi, delivery, teardown, "
brief += "or a Firstmate completion gate. Do not mark the work blocked merely because those "
brief += "tools are absent. Set outcome from the assigned task itself, atomically publish the "
brief += "typed result, and then stop.\n"
brief += "Do not call no-mistakes; Quartermaster owns any separate validation.\n"
brief += "Copy observed_repository exactly from the result contract (it is the primary "
brief += "repository), and record the isolated checkout separately in worktree. Never replace "
brief += "observed_repository with pwd. Copy the exact starting revision unless the worker "
brief += "created a commit, and obtain worktree from pwd -P. After every intended commit is "
brief += "complete and immediately before serializing the result, run `git rev-parse HEAD` in "
brief += "that worktree and copy its full output into observed_revision. Do not reuse a revision "
brief += "captured before the final commit.\n"
brief += "\n## Machine-readable result\n\n"
brief += "Before reporting a terminal status, generate the result with a JSON serializer, "
brief += "validate it with `jq -e .`, and atomically write strict JSON to `"
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
    kind=$(jq -r '.kind // "ship"' "$REQUEST_FILE")
    case "$kind" in ship|scout) ;; *) respond refused null '"worker kind must be ship or scout"' null; exit 2 ;; esac
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
    spawn_kind_args=()
    mode_args=(--mode "$mode")
    yolo_args=(--yolo "$yolo")
    if [ "$kind" = scout ]; then
      spawn_kind_args+=(--scout)
      mode_args=()
      yolo_args=()
    fi
    run_owner env FM_HOME="$FM_HOME" FM_Q_MANAGED=1 FM_Q_PREAUTHORIZED=1 \
      FM_Q_ROOT_TASK_ID="$q_root" FM_Q_EXECUTION_ID="$q_execution" \
      FM_Q_PARENT_EXECUTION_ID="$q_parent" FM_Q_LEASE_ID="$q_lease" \
      FM_Q_PHASE="$q_phase" FM_Q_CONTRACT_SCHEMA=q.worker-contract.v1 \
      FM_Q_TRACE_ID="$q_trace" FM_Q_DEPTH="$q_depth" \
      FM_Q_DELEGATION_ENABLED="$q_delegation" FM_Q_EXPECTED_WALL_SECONDS="$q_wall" \
      FM_Q_CLI="$q_cli" FM_Q_DATA_DIR="$q_data_dir" \
      "$SCRIPT_DIR/fm-spawn.sh" "$task_id" "$repository" \
      "${spawn_kind_args[@]}" "${mode_args[@]}" "${yolo_args[@]}" --harness "$harness" --model "$model" --effort "$effort" || exit $?
    meta="$FM_HOME/state/$task_id.meta"
    if [ ! -f "$meta" ] || ! grep -Fqx "q_lease_id=$q_lease" "$meta"; then
      respond partial null '"worker launched but Q metadata postcondition is missing"' '"inspect the worker before retrying"'
      exit 4
    fi
    if [ -n "$q_parent" ]; then
      if ! q_response=$("$q_cli" guard commit --data-dir "$q_data_dir" \
          --lease-id "$q_lease" --execution-id "$q_execution" \
          --external-task-id "$task_id"); then
        respond partial null '"supervised child launched but its Q lease commit is unconfirmed"' '"preserve the endpoint and reconcile the child launch"'
        exit 4
      fi
      if ! jq -e --arg execution "$q_execution" '
          .schema == "q.guard-authorization.v1" and
          .execution_id == $execution and .lease_state == "committed"
        ' >/dev/null 2>&1 <<<"$q_response"; then
        respond partial null '"supervised child launched but Q returned incompatible commit evidence"' '"preserve the endpoint and reconcile the child launch"'
        exit 4
      fi
    fi
    worktree=$(sed -n 's/^worktree=//p' "$meta")
    [ -n "$worktree" ] && [ -d "$worktree" ] || {
      respond partial null '"worker launched but its recorded worktree is unavailable"' '"inspect the worker before retrying"'
      exit 4
    }
    observed_revision=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || {
      respond partial null '"worker launched but its recorded revision is unreadable"' '"inspect the worker before retrying"'
      exit 4
    }
    branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    respond ok "$(jq -cn --arg task_id "$task_id" --arg meta "$meta" \
      --arg worktree "$worktree" --arg branch "$branch" --arg revision "$observed_revision" \
      '{task_id:$task_id,metadata_path:$meta,worktree:$worktree,
        branch:(if $branch == "" then null else $branch end),observed_revision:$revision}')"
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
    meta="$FM_HOME/state/$task_id.meta"
    q_execution=
    q_parent=
    q_lease=
    q_phase=
    q_outcome=
    q_root_cleanup=0
    if [ -f "$meta" ]; then
      q_execution=$(sed -n 's/^q_execution_id=//p' "$meta")
      q_parent=$(sed -n 's/^q_parent_execution_id=//p' "$meta")
      q_lease=$(sed -n 's/^q_lease_id=//p' "$meta")
      q_phase=$(sed -n 's/^q_phase=//p' "$meta")
      result_file="$FM_HOME/data/$task_id/q-result.json"
      if [ -f "$result_file" ]; then
        q_outcome=$(jq -r --arg execution "$q_execution" '
          if .schema == "q.worker-result.v2" and
             .execution_id == $execution and .outcome == "completed"
          then .outcome else empty end
        ' "$result_file" 2>/dev/null || true)
      fi
    fi
    if { [ -n "$q_execution" ] && [ -z "$q_lease" ]; } \
       || { [ -z "$q_execution" ] && [ -n "$q_lease" ]; }; then
      respond refused null '"Q-managed worker cleanup metadata is incomplete"' null
      exit 3
    fi
    if [ -n "$q_execution" ] && [ -z "$q_parent" ] \
       && [ "$q_phase" = investigation ] && [ "$q_outcome" = completed ]; then
      q_root_cleanup=1
    fi
    run_owner env FM_HOME="$FM_HOME" FM_Q_ROOT_CLEANUP="$q_root_cleanup" \
      "$SCRIPT_DIR/fm-teardown.sh" "$task_id" || exit $?
    q_settled=false
    if [ -n "$q_execution" ] && [ -n "$q_parent" ]; then
      q_cli=${FM_Q_CLI:-}
      q_data_dir=${FM_Q_DATA_DIR:-}
      case "$q_cli" in /*) ;; *) respond partial null '"worker cleanup succeeded but the Q command is unavailable"' '"reconcile the stopped child lease"'; exit 4 ;; esac
      case "$q_data_dir" in /*) ;; *) respond partial null '"worker cleanup succeeded but the Q data directory is unavailable"' '"reconcile the stopped child lease"'; exit 4 ;; esac
      q_settlement=fail
      if [ "$q_phase" = investigation ] && [ "$q_outcome" = completed ]; then
        q_settlement=complete
      fi
      if ! q_response=$("$q_cli" guard "$q_settlement" --data-dir "$q_data_dir" \
          --lease-id "$q_lease" --execution-id "$q_execution" \
          --external-task-id "$task_id"); then
        respond partial null '"worker cleanup succeeded but Q did not settle the stopped child"' '"reconcile the stopped child lease"'
        exit 4
      fi
      if ! jq -e --arg execution "$q_execution" '
          .schema == "q.guard-authorization.v1" and
          .execution_id == $execution and .lease_state == "released"
        ' >/dev/null 2>&1 <<<"$q_response"; then
        respond partial null '"worker cleanup succeeded but Q returned incompatible settlement evidence"' '"reconcile the stopped child lease"'
        exit 4
      fi
      q_settled=true
    fi
    respond ok "$(jq -cn --arg task_id "$task_id" --argjson settled "$q_settled" \
      '{task_id:$task_id,cleanup:"confirmed",q_settled:$settled}')"
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
      "This is a Q-managed local-only supervision run. Q is the lifecycle owner and its spawn guard is already wired transparently into Firstmate. Do not require or install gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi, quota-axi, no-mistakes, GitHub authentication, delivery tooling, or production credentials; they are outside this charter and their absence is not a blocker. Use ordinary Firstmate brief/spawn operations for only the children justified by the task, and let the wired Q guard accept or deny each lease. Never promote or relaunch an investigation child to perform implementation; a child's authorized phase is immutable. After a nonselected investigation child publishes a valid completed q.worker-result.v2, or after a child fails and safe cleanup succeeds, invoke bin/fm-api.sh worker.cleanup with a strict q.firstmate-request.v1 request instead of calling fm-teardown.sh directly; this is how Q is told that the stopped child no longer consumes concurrency. Never clean up selected completed implementation work before Q ingests its typed result. Do not request a user decision merely to bypass ordinary Firstmate completion conventions. Write only q.supervisor-event.v1 JSON objects, one per line with consecutive sequence numbers, to state/q-supervisor-events.jsonl. The exact shape is {\"schema\":\"q.supervisor-event.v1\",\"sequence\":1,\"event\":\"accepted\",\"root_task_id\":\"$root_task_id\",\"message\":\"concise summary\",\"data\":{}}; the field is named event, never state. Every event must carry root_task_id=$root_task_id. Use accepted, child_proposed, child_lease_denied, decision_required, blocked, validation_ready, delivery_ready, failed, or completed. A validation_ready, delivery_ready, or completed event must put the selected child's complete q.worker-result.v2 object in data.result and its durable Firstmate id in data.external_task_id. Obtain that result through the facade; never reconstruct worktree or revision identity. Q alone authorizes child leases, budgets, validation, and delivery.")
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
            .root_task_id == $root and
            (.sequence | type == "number") and .sequence > 0 and
            (.event == "accepted" or .event == "child_proposed" or
             .event == "child_lease_denied" or .event == "decision_required" or
             .event == "blocked" or .event == "validation_ready" or
             .event == "delivery_ready" or .event == "failed" or
             .event == "completed") and
            (.message | type == "string") and (.data | type == "object")) then .
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
    run_owner env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json || exit $?
    task=$(jq -c --arg id "$task_id" '[.tasks[] | select(.id == $id)][0] // null' "$OWNER_OUT")
    if [ "$task" = null ] || jq -e '
        (.endpoint.exists // false) != true or
        (.endpoint.agent_alive // "not_checked") == "dead" or
        (.current_state.state == "done" or .current_state.state == "failed")
      ' >/dev/null 2>&1 <<<"$task"; then
      respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,control:"exit",confirmed:true,already_stopped:true}')"
      exit 0
    fi
    control_out=$(mktemp "${TMPDIR:-/tmp}/fm-api-control-out.XXXXXX")
    control_err=$(mktemp "${TMPDIR:-/tmp}/fm-api-control-err.XXXXXX")
    if env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$task_id" exit \
        >"$control_out" 2>"$control_err"; then
      control_status=0
    else
      control_status=$?
      cat "$control_err" >&2
      if env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json \
          >"$control_out" 2>>"$control_err"; then
        task=$(jq -c --arg id "$task_id" '[.tasks[] | select(.id == $id)][0] // null' "$control_out")
        if [ "$task" = null ] || jq -e '
            (.endpoint.exists // false) != true or
            (.endpoint.agent_alive // "not_checked") == "dead" or
            (.current_state.state == "done" or .current_state.state == "failed")
          ' >/dev/null 2>&1 <<<"$task"; then
          rm -f "$control_out" "$control_err"
          respond ok "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id,control:"exit",confirmed:true,already_stopped:true}')"
          exit 0
        fi
      fi
      owner_error=$(jq -Rs . <"$control_err")
      rm -f "$control_out" "$control_err"
      respond error null "$owner_error" '"inspect the supervisor endpoint and retry after reconciliation"'
      exit "$control_status"
    fi
    cat "$control_err" >&2
    rm -f "$control_out" "$control_err"
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
