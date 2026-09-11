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

cat >"$BIN/fm-backend.sh" <<'EOF'
fm_backend_validate_task_endpoint() {
  [ -f "$1" ] || return 1
  [ "$2" = worker-capture ] || return 1
  FM_BACKEND_VALIDATED_BACKEND=tmux
  FM_BACKEND_VALIDATED_TARGET=fixture:fm-worker-capture
}

fm_backend_capture_ansi() {
  [ "$1" = tmux ]
  [ "$2" = fixture:fm-worker-capture ]
  [ "$3" -le 500 ]
  printf '\033[32mstyled worker output\033[0m\n'
}
EOF

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
if [ "${FM_TEST_SPAWN_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'deliberate spawn-owner failure' >&2
  exit 19
fi
home=${FM_HOME:?}
id=$1
mkdir -p "$home/state"
worktree="$home/worktree-$id"
mkdir -p "$worktree"
if [ ! -d "$worktree/.git" ]; then
  git -C "$worktree" init -q
  git -C "$worktree" config user.name Test
  git -C "$worktree" config user.email test@example.invalid
  printf 'fixture\n' >"$worktree/README.md"
  git -C "$worktree" add README.md
  git -C "$worktree" commit -qm initial
fi
{
  printf 'q_root_task_id=%s\n' "${FM_Q_ROOT_TASK_ID:?}"
  printf 'q_execution_id=%s\n' "${FM_Q_EXECUTION_ID:?}"
  printf 'q_lease_id=%s\n' "${FM_Q_LEASE_ID:?}"
  printf 'q_phase=%s\n' "${FM_Q_PHASE:?}"
  printf 'q_contract_schema=%s\n' "${FM_Q_CONTRACT_SCHEMA:?}"
  printf 'worktree=%s\n' "$worktree"
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
mkdir -p "$home/state" "$home/data/$id" "$home/config" "$home/projects"
printf '%s\n' "$id" >"$home/.fm-secondmate-home"
printf '%s\n' "${FM_SECONDMATE_CHARTER:-}" >"$home/data/$id/charter.md"
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
if [ "${0##*/}" = fm-control.sh ] && [ -n "${FM_Q_RELAUNCH_IDEMPOTENCY_KEY:-}" ]; then
  printf '%s\n' "$FM_Q_RELAUNCH_IDEMPOTENCY_KEY" >"$FM_HOME/state/relaunch-operation-key"
fi
if [ "${0##*/}" = fm-teardown.sh ]; then
  printf '%s\n' "${FM_Q_ROOT_CLEANUP:-0}" >"$FM_HOME/state/root-cleanup-flag"
fi
printf 'owner diagnostic\n' >&2
exit 0
EOF
done
cat >"$BIN/fm-q-land-local.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >"$FM_HOME/state/q-local-land-argv"
jq -cn --arg destination "$3" --arg head "$6" \
  '{confirmed:true,destination:$destination,observed_head:$head,already_landed:false}'
EOF
chmod +x "$BIN"/*.sh

invoke() {
  operation=$1
  request=$2
  printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" "$BIN/fm-api.sh" "$operation"
}

test_capabilities_are_one_versioned_json_object() {
  out=$(FM_HOME="$HOME_ROOT" "$BIN/fm-api.sh" capabilities) || fail "capabilities failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "capabilities emitted multiple lines"
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-api-response.v1" and .result == "ok" and
    .postcondition_evidence.q_metadata == true and
    .postcondition_evidence.q_spawn_guard == true and
    (.postcondition_evidence.request_schemas | index("q.firstmate-request.v2")) != null and
    .postcondition_evidence.retirement_receipts == true and
    .postcondition_evidence.artifact_publication == true
  ' >/dev/null \
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
  grep -F 'jq -e .' "$HOME_ROOT/data/worker-1/brief.md" >/dev/null \
    || fail "typed worker result did not require parser validation"
  grep -F 'Do not call captain-hold, tasks-axi' "$HOME_ROOT/data/worker-1/brief.md" >/dev/null \
    || fail "Q completion did not override the ordinary Firstmate completion gate"
  grep -F 'immediately before serializing the result' "$HOME_ROOT/data/worker-1/brief.md" >/dev/null \
    || fail "Q completion did not require a post-commit observed revision"
  pass "worker.prepare delegates and renders the Q contract"
}

test_v2_report_worker_contract_prepares_and_spawns() {
  request=$(jq -cn --arg result_path "$HOME_ROOT/data/worker-v2/q-result.json" \
    --arg publication "$HOME_ROOT/publications/worker-v2" \
    '{schema:"q.firstmate-request.v2",operation:"worker.prepare",
      idempotency_key:"prepare-v2",task_id:"worker-v2",repository_name:"repo",
      kind:"scout",mode:"local-only",captain_intent:"Evaluate readiness.",
      execution_spec:"Publish the typed report.",result_path:$result_path,
      worker_contract:{schema:"q.worker-contract.v2",root_task_id:"task-root-v2",
        execution_id:"worker-v2",phase:"report",disposition:"report_only",
        output_manifest_id:"manifest-v2",
        output_artifact_ids:["artifact-v2"],publication_directory:$publication},
      result_contract:{schema:"q.worker-result.v3",root_task_id:"task-root-v2",
        execution_id:"worker-v2",artifact_manifest_id:"manifest-v2",
        primary_output:{kind:"report",artifact_id:"artifact-v2"}}}')
  out=$(invoke worker.prepare "$request") || fail "v2 worker.prepare failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null \
    || fail "v2 worker.prepare response failed"
  grep -F 'q.worker-result.v3' "$HOME_ROOT/data/worker-v2/brief.md" >/dev/null \
    || fail "v2 preparation did not render the v3 result contract"
  grep -F "$HOME_ROOT/publications/worker-v2" "$HOME_ROOT/data/worker-v2/brief.md" >/dev/null \
    || fail "v2 preparation did not permit the artifact publication directory"

  request='{"schema":"q.firstmate-request.v2","operation":"worker.spawn","idempotency_key":"spawn-v2","task_id":"worker-v2","repository":"/repo","kind":"scout","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"medium","q":{"root_task_id":"task-root-v2","execution_id":"worker-v2","parent_execution_id":"","lease_id":"lease-v2","phase":"investigation","trace_id":"","depth":0,"expected_wall_seconds":300,"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(invoke worker.spawn "$request") || fail "v2 worker.spawn failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null \
    || fail "v2 worker.spawn response failed"
  grep -Fqx 'q_contract_schema=q.worker-contract.v2' "$HOME_ROOT/state/worker-v2.meta" \
    || fail "v2 worker contract identity was not retained by spawn"
  pass "v2 report worker contract prepares and spawns additively"
}

test_v2_investigation_prepares_without_artifact_publication() {
  request=$(jq -cn --arg result_path "$HOME_ROOT/data/worker-investigation/q-result.json" \
    '{schema:"q.firstmate-request.v2",operation:"worker.prepare",
      idempotency_key:"prepare-investigation",task_id:"worker-investigation",
      repository_name:"repo",kind:"scout",mode:"local-only",
      captain_intent:"Investigate ambiguity.",execution_spec:"Publish the typed handoff.",
      result_path:$result_path,
      worker_contract:{schema:"q.worker-contract.v2",root_task_id:"task-investigation",
        execution_id:"worker-investigation",phase:"investigation",disposition:"report_only",
        output_manifest_id:null,output_artifact_ids:[],publication_directory:null},
      result_contract:{schema:"q.worker-result.v3",root_task_id:"task-investigation",
        execution_id:"worker-investigation",artifact_manifest_id:null,
        primary_output:{kind:"summary",artifact_id:null}}}')
  out=$(invoke worker.prepare "$request") || fail "v2 investigation worker.prepare failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null \
    || fail "v2 investigation worker.prepare response failed"
  grep -F '"kind": "summary"' "$HOME_ROOT/data/worker-investigation/brief.md" >/dev/null \
    || fail "v2 investigation did not render the inline handoff contract"
  pass "v2 investigation prepares without fake artifact publication"
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

test_worker_result_accepts_v2_typed_evidence() {
  mkdir -p "$HOME_ROOT/data/worker-1" "$HOME_ROOT/state" "$HOME_ROOT/observed"
  printf '%s\n' 'q_root_task_id=task-root' 'q_execution_id=exec-worker' \
    >"$HOME_ROOT/state/worker-1.meta"
  printf '%s\n' '{"schema":"q.worker-result.v2","root_task_id":"task-root","execution_id":"exec-worker","outcome":"completed","summary":"README is 8 bytes.","artifacts":[],"evidence":[{"kind":"command","summary":"measured","command":{"argv":["wc","-c","README.md"],"exit_status":0,"output":"8 README.md","working_directory":"/tmp/work"}}],"observed_repository":"/repo","observed_revision":"abc123","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-09T00:00:00Z"}' \
    >"$HOME_ROOT/data/worker-1/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.result","idempotency_key":"result-v2","task_id":"worker-1"}'
  out=$(invoke worker.result "$request") || fail "worker.result v2 failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.result.schema == "q.worker-result.v2" and (.postcondition_evidence.result.evidence | length) == 1' >/dev/null \
    || fail "worker result v2 evidence is invalid"
  printf '%s\n' '{"schema":"q.worker-result.v2","root_task_id":"task-root","execution_id":"exec-worker","outcome":"completed","summary":"bad evidence","artifacts":[],"evidence":[{"kind":"command","summary":"not typed","command":"pytest -q"}],"observed_repository":"/repo","observed_revision":"abc123","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-09T00:00:00Z"}' \
    >"$HOME_ROOT/data/worker-1/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.result","idempotency_key":"result-v2-invalid-evidence","task_id":"worker-1"}'
  out=$(invoke worker.result "$request")
  [ "$?" -eq 3 ] || fail "worker result accepted a string command as typed evidence"
  printf '%s\n' "$out" | jq -e '.result == "refused"' >/dev/null \
    || fail "invalid v2 evidence did not return a typed refusal"
  printf '%s\n' '{"schema":"q.worker-result.v2","root_task_id":"task-root","execution_id":"exec-worker","outcome":"completed","summary":"bad report","artifacts":[],"investigation_report":"not typed","evidence":[],"observed_repository":"/repo","observed_revision":"abc123","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-09T00:00:00Z"}' \
    >"$HOME_ROOT/data/worker-1/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.result","idempotency_key":"result-v2-invalid-report","task_id":"worker-1"}'
  out=$(invoke worker.result "$request")
  [ "$?" -eq 3 ] || fail "worker result accepted an untyped investigation report"
  printf '%s\n' "$out" | jq -e '.result == "refused"' >/dev/null \
    || fail "invalid investigation report did not return a typed refusal"
  pass "worker result accepts v2 typed evidence"
}

test_worker_result_v3_and_retirement_are_typed_and_idempotent() {
  mkdir -p "$HOME_ROOT/data/worker-retire" "$HOME_ROOT/state" "$HOME_ROOT/worktree-worker-retire"
  printf '%s\n' 'q_root_task_id=task-root-v3' 'q_execution_id=exec-v3' \
    'q_contract_schema=q.worker-contract.v2' \
    "worktree=$HOME_ROOT/worktree-worker-retire" \
    >"$HOME_ROOT/state/worker-retire.meta"
  printf '%s\n' '{"schema":"q.worker-result.v3","root_task_id":"task-root-v3","execution_id":"exec-v3","execution_generation":1,"result_generation":1,"outcome":"completed","summary":"Readiness report completed.","artifacts":[],"investigation_report":null,"usage":[],"evidence":[],"observed_repository":"/repo","observed_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-10T00:00:00Z","finality":"final","disposition":"report_only","primary_output":{"kind":"report","title":"Readiness","media_type":"text/markdown; charset=utf-8","artifact_id":"artifact-report","completeness":"complete"},"artifact_manifest_id":"manifest-report","supersedes_result_id":null,"validation_binding":null}' \
    >"$HOME_ROOT/data/worker-retire/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.result","idempotency_key":"result-v3","task_id":"worker-retire"}'
  out=$(invoke worker.result "$request") || fail "worker.result v3 failed"
  printf '%s\n' "$out" | jq -e \
    '.postcondition_evidence.result.schema == "q.worker-result.v3" and
     .postcondition_evidence.result.primary_output.artifact_id == "artifact-report"' \
    >/dev/null || fail "worker result v3 evidence is invalid"

  request='{"schema":"q.firstmate-request.v2","operation":"worker.retire","idempotency_key":"retire-v3","task_id":"worker-retire"}'
  first=$(invoke worker.retire "$request") || fail "worker.retire failed"
  second=$(invoke worker.retire "$request") || fail "worker.retire replay failed"
  printf '%s\n' "$first" | jq -e \
    '.result == "ok" and
     .postcondition_evidence.retirement_receipt.schema == "fm.retirement-receipt.v1" and
     .postcondition_evidence.retirement_receipt.root_task_id == "task-root-v3" and
     .postcondition_evidence.retirement_receipt.execution_generation == 1 and
     .postcondition_evidence.retirement_receipt.mutation_owner == "none"' \
    >/dev/null || fail "worker retirement receipt is invalid"
  [ "$(printf '%s\n' "$first" | jq -c .postcondition_evidence)" = \
    "$(printf '%s\n' "$second" | jq -c .postcondition_evidence)" ] \
    || fail "worker retirement replay changed its durable receipt"
  pass "worker result v3 and retirement are typed and idempotent"
}

test_worker_result_v3_canonicalizes_redundant_artifact_declarations() {
  worker='worker-v3-redundant-artifacts'
  mkdir -p "$HOME_ROOT/data/$worker" "$HOME_ROOT/state"
  printf '%s\n' 'q_root_task_id=task-v3-redundant-artifacts' \
    'q_execution_id=exec-v3-redundant-artifacts' \
    >"$HOME_ROOT/state/$worker.meta"
  printf '%s\n' \
    '{"schema":"q.worker-result.v3","root_task_id":"task-v3-redundant-artifacts","execution_id":"exec-v3-redundant-artifacts","execution_generation":1,"result_generation":1,"outcome":"completed","summary":"Readiness report completed.","artifacts":[{"id":"artifact-report","kind":"report","title":"Readiness","media_type":"text/markdown; charset=utf-8","path":"report.md","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":42,"completeness":"complete","supersedes_artifact_id":null}],"investigation_report":null,"usage":[],"evidence":[],"observed_repository":"/repo","observed_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-10T00:00:00Z","finality":"final","disposition":"report_only","primary_output":{"kind":"report","title":"Readiness","media_type":"text/markdown; charset=utf-8","artifact_id":"artifact-report","completeness":"complete"},"artifact_manifest_id":"manifest-report","supersedes_result_id":null,"validation_binding":null}' \
    >"$HOME_ROOT/data/$worker/q-result.json"
  request='{"schema":"q.firstmate-request.v2","operation":"worker.result","idempotency_key":"result-v3-redundant-artifacts","task_id":"worker-v3-redundant-artifacts"}'
  out=$(invoke worker.result "$request") || fail "worker.result rejected redundant v3 declarations"
  printf '%s\n' "$out" | jq -e \
    '.result == "ok" and .postcondition_evidence.result.artifacts == []' \
    >/dev/null || fail "worker.result did not canonicalize redundant v3 declarations"
  pass "worker result v3 canonicalizes redundant artifact declarations"
}

test_legacy_v3_investigation_report_is_normalized_to_internal_summary() {
  worker='worker-investigation-result'
  mkdir -p "$HOME_ROOT/data/$worker" "$HOME_ROOT/state"
  printf '%s\n' 'q_root_task_id=task-investigation-result' \
    'q_execution_id=exec-investigation-result' 'q_phase=investigation' \
    >"$HOME_ROOT/state/$worker.meta"
  printf '%s\n' \
    '{"schema":"q.worker-result.v3","root_task_id":"task-investigation-result","execution_id":"exec-investigation-result","execution_generation":1,"result_generation":1,"outcome":"completed","summary":"The ambiguity is resolved.","artifacts":[],"investigation_report":{"schema":"q.investigation-report.v1","summary":"The ambiguity is resolved.","material_facts":[],"remaining_unknowns":[],"recommended_implementation":["Write the final report."],"authority_expansion_required":false},"usage":[],"evidence":[],"observed_repository":"/repo","observed_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-10T00:00:00Z","finality":"final","disposition":"report_only","primary_output":{"kind":"report","title":"Investigation","media_type":"text/markdown; charset=utf-8","artifact_id":null,"completeness":"complete"},"artifact_manifest_id":"manifest-unused","supersedes_result_id":null,"validation_binding":null}' \
    >"$HOME_ROOT/data/$worker/q-result.json"
  request='{"schema":"q.firstmate-request.v2","operation":"worker.result","idempotency_key":"result-investigation-normalize","task_id":"worker-investigation-result"}'
  out=$(invoke worker.result "$request") || fail "legacy investigation result was refused"
  printf '%s\n' "$out" | jq -e '
    .postcondition_evidence.result.primary_output == {
      kind:"summary",title:"Investigation handoff",media_type:null,
      artifact_id:null,completeness:"complete"
    } and .postcondition_evidence.result.artifact_manifest_id == null
  ' >/dev/null || fail "legacy investigation result was not normalized"
  pass "legacy v3 investigation result is normalized to an internal summary"
}

test_codex_worker_result_waits_for_and_reports_structured_usage() {
  worker='worker-codex-usage'
  codex_home="$TMP_ROOT/codex-home"
  sessions="$codex_home/sessions/2023/11/14"
  mkdir -p "$HOME_ROOT/data/$worker" "$HOME_ROOT/state" "$sessions"
  printf '%s\n' 'q_root_task_id=task-codex-usage' 'q_execution_id=exec-codex-usage' \
    'harness=codex' 'spawn_gen=s1700000000.12.34' \
    "worktree=$HOME_ROOT/worktree-codex-usage" \
    >"$HOME_ROOT/state/$worker.meta"
  printf '%s\n' \
    '{"schema":"q.worker-result.v3","root_task_id":"task-codex-usage","execution_id":"exec-codex-usage","execution_generation":1,"result_generation":1,"outcome":"completed","summary":"Investigation complete.","artifacts":[],"investigation_report":null,"usage":[{"schema":"q.usage-report.v1","metric":"tokens","amount":999,"source":"worker guess"},{"schema":"q.usage-report.v1","metric":"cost_usd","amount":0,"source":"worker did not receive a harness cost observation"}],"evidence":[],"observed_repository":"/repo","observed_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","worktree":"/tmp/work","branch":null,"completed_at":"2026-09-10T00:00:00Z","finality":"final","disposition":"report_only","primary_output":{"kind":"summary","title":"Investigation handoff","media_type":null,"artifact_id":null,"completeness":"complete"},"artifact_manifest_id":null,"supersedes_result_id":null,"validation_binding":null}' \
    >"$HOME_ROOT/data/$worker/q-result.json"
  request='{"schema":"q.firstmate-request.v2","operation":"worker.result","idempotency_key":"result-codex-usage-pending","task_id":"worker-codex-usage"}'
  out=$(printf '%s\n' "$request" | CODEX_HOME="$codex_home" FM_HOME="$HOME_ROOT" \
    "$BIN/fm-api.sh" worker.result)
  status=$?
  [ "$status" -eq 3 ] || fail "Codex result did not wait for the final turn-end observation"
  printf '%s\n' "$out" | jq -e '.error == "worker result is finalizing"' >/dev/null \
    || fail "Codex finalization wait was not structured"

  printf '%s\n' \
    '{"timestamp":"2023-11-14T22:13:21Z","type":"session_meta","payload":{"timestamp":"2023-11-14T22:13:21Z","cwd":"'"$HOME_ROOT"'/worktree-codex-usage","originator":"codex_exec"}}' \
    '{"timestamp":"2023-11-14T22:14:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":5}}}}' \
    >"$sessions/rollout.jsonl"
  touch "$HOME_ROOT/state/$worker.turn-ended"
  request='{"schema":"q.firstmate-request.v2","operation":"worker.result","idempotency_key":"result-codex-usage","task_id":"worker-codex-usage"}'
  out=$(printf '%s\n' "$request" | CODEX_HOME="$codex_home" FM_HOME="$HOME_ROOT" \
    "$BIN/fm-api.sh" worker.result) || fail "Codex worker.result failed after turn end"
  printf '%s\n' "$out" | jq -e '
    .postcondition_evidence.result.usage == [{
      schema:"q.usage-report.v1",metric:"tokens",amount:65,
      source:"codex rollout token_count (uncached input + output)"
    }]
  ' >/dev/null || fail "Codex structured usage was not attributed to the worker"
  pass "Codex worker result waits for and reports structured task usage"
}

test_spawn_requires_metadata_postcondition() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.spawn","idempotency_key":"spawn-1","task_id":"worker-1","repository":"/repo","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"low","q":{"root_task_id":"task-root","execution_id":"exec-1","parent_execution_id":"","lease_id":"lease-1","phase":"implementation","trace_id":"","depth":0,"expected_wall_seconds":300,"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(invoke worker.spawn "$request") || fail "worker.spawn failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.task_id == "worker-1" and (.postcondition_evidence.worktree | type == "string") and (.postcondition_evidence.observed_revision | length) == 40' >/dev/null \
    || fail "spawn response lacks postcondition evidence"
  grep -Fqx 'q_lease_id=lease-1' "$HOME_ROOT/state/worker-1.meta" || fail "lease metadata is absent"
  pass "worker.spawn verifies additive Q metadata"
}

test_supervised_worker_spawn_commits_pre_authorized_lease() {
  fake_q="$TMP_ROOT/fake-q-spawn-commit"
  calls="$TMP_ROOT/q-spawn-commit.calls"
  cat >"$fake_q" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = guard ] && [ "$2" = commit ]
printf '%s\n' "$*" >"${FM_Q_FAKE_CALLS:?}"
printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-supervisor","execution_id":"exec-child","external_task_id":"worker-child","requested_depth":1,"lease_id":"lease-child","lease_state":"committed","denial_reason":null}'
EOF
  chmod +x "$fake_q"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.spawn","idempotency_key":"spawn-child-1","task_id":"worker-child","repository":"/repo","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"low","q":{"root_task_id":"task-root","execution_id":"exec-child","parent_execution_id":"exec-supervisor","lease_id":"lease-child","phase":"implementation","trace_id":"","depth":1,"expected_wall_seconds":300,"guard_executable":"'"$fake_q"'","data_dir":"/tmp/q-data"}}'
  out=$(printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" FM_Q_FAKE_CALLS="$calls" \
    "$BIN/fm-api.sh" worker.spawn) || fail "supervised worker.spawn failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null \
    || fail "supervised worker.spawn response failed"
  grep -F -- 'guard commit --data-dir /tmp/q-data' "$calls" >/dev/null \
    || fail "supervised worker.spawn did not commit its pre-authorized lease"
  grep -F -- '--external-task-id worker-child' "$calls" >/dev/null \
    || fail "supervised worker.spawn commit did not bind the external identity"
  pass "supervised worker.spawn commits its pre-authorized child lease"
}

test_report_only_spawn_accepts_inspect_phase() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.spawn","idempotency_key":"spawn-inspect-1","task_id":"worker-inspect","repository":"/repo","kind":"scout","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"low","q":{"root_task_id":"task-root","execution_id":"exec-inspect","parent_execution_id":"","lease_id":"lease-inspect","phase":"inspect","trace_id":"","depth":0,"expected_wall_seconds":300,"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(invoke worker.spawn "$request") || fail "report-only worker.spawn failed"
  printf '%s\n' "$out" | jq -e '.result == "ok" and .postcondition_evidence.task_id == "worker-inspect"' >/dev/null \
    || fail "inspect phase did not return spawn evidence"
  pass "report-only worker.spawn accepts the inspect phase"
}

test_owner_failure_returns_one_error_response() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.spawn","idempotency_key":"spawn-failure-1","task_id":"worker-failure","repository":"/repo","mode":"local-only","yolo":"off","harness":"codex","model":"default","effort":"low","q":{"root_task_id":"task-root","execution_id":"exec-failure","parent_execution_id":"","lease_id":"lease-failure","phase":"implementation","trace_id":"","depth":0,"expected_wall_seconds":300,"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" FM_TEST_SPAWN_FAIL=1 \
    "$BIN/fm-api.sh" worker.spawn 2>"$TMP_ROOT/spawn-failure.err")
  status=$?
  [ "$status" -eq 19 ] || fail "facade did not preserve the spawn owner's failure status"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "failed owner emitted more than one facade response"
  printf '%s\n' "$out" | jq -e \
    '.schema == "fm-api-response.v1" and .result == "error" and (.error | contains("deliberate spawn-owner failure"))' \
    >/dev/null || fail "failed owner response is not one structured error"
  grep -F 'deliberate spawn-owner failure' "$TMP_ROOT/spawn-failure.err" >/dev/null \
    || fail "failed owner diagnostics were not forwarded to stderr"
  [ ! -e "$HOME_ROOT/state/worker-failure.meta" ] \
    || fail "facade continued into metadata verification after owner failure"
  pass "owner failure returns exactly one structured facade response"
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
  printf '%s\n' 'kind=ship' >"$HOME_ROOT/state/worker-1.meta"
  out=$(invoke worker.cleanup "$base,"'"operation":"worker.cleanup","task_id":"worker-1"}') || fail "cleanup failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.cleanup == "confirmed"' >/dev/null || fail "cleanup was not confirmed"
  pass "snapshot and worker lifecycle calls delegate through typed responses"
}

test_q_worker_cleanup_settles_failed_child_lease() {
  fake_q="$TMP_ROOT/fake-q-cleanup"
  calls="$TMP_ROOT/q-cleanup.calls"
  cat >"$fake_q" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = guard ] && [ "$2" = fail ]
printf '%s\n' "$*" >"${FM_Q_FAKE_CALLS:?}"
printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":"exec-child","external_task_id":"failed-child","requested_depth":1,"lease_id":"lease-child","lease_state":"released","denial_reason":null}'
EOF
  chmod +x "$fake_q"
  printf '%s\n' 'q_execution_id=exec-child' 'q_parent_execution_id=exec-parent' \
    'q_lease_id=lease-child' \
    >"$HOME_ROOT/state/failed-child.meta"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.cleanup","idempotency_key":"cleanup-q-child","task_id":"failed-child"}'
  out=$(printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" FM_Q_CLI="$fake_q" \
    FM_Q_DATA_DIR="$TMP_ROOT/q-data" FM_Q_FAKE_CALLS="$calls" \
    "$BIN/fm-api.sh" worker.cleanup) || fail "Q child cleanup failed"
  printf '%s\n' "$out" | jq -e \
    '.result == "ok" and .postcondition_evidence.cleanup == "confirmed" and .postcondition_evidence.q_settled == true' \
    >/dev/null || fail "Q child cleanup did not confirm lease settlement"
  grep -F -- 'guard fail --data-dir' "$calls" >/dev/null \
    || fail "Q child cleanup did not use the failed-child settlement boundary"
  grep -F -- '--external-task-id failed-child' "$calls" >/dev/null \
    || fail "Q child cleanup did not bind settlement to the external identity"
  pass "Q worker cleanup settles a stopped failed child lease"
}

test_q_worker_cleanup_settles_completed_investigation_child() {
  fake_q="$TMP_ROOT/fake-q-complete"
  calls="$TMP_ROOT/q-complete.calls"
  cat >"$fake_q" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = guard ] && [ "$2" = complete ]
printf '%s\n' "$*" >"${FM_Q_FAKE_CALLS:?}"
printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":"exec-scout","external_task_id":"completed-scout","requested_depth":1,"lease_id":"lease-scout","lease_state":"released","denial_reason":null}'
EOF
  chmod +x "$fake_q"
  mkdir -p "$HOME_ROOT/data/completed-scout"
  printf '%s\n' 'kind=scout' 'q_execution_id=exec-scout' \
    'q_parent_execution_id=exec-parent' 'q_lease_id=lease-scout' \
    'q_phase=investigation' >"$HOME_ROOT/state/completed-scout.meta"
  printf '%s\n' '{"schema":"q.worker-result.v2","root_task_id":"task-root","execution_id":"exec-scout","outcome":"completed"}' \
    >"$HOME_ROOT/data/completed-scout/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.cleanup","idempotency_key":"cleanup-q-scout","task_id":"completed-scout"}'
  out=$(printf '%s\n' "$request" | FM_HOME="$HOME_ROOT" FM_Q_CLI="$fake_q" \
    FM_Q_DATA_DIR="$TMP_ROOT/q-data" FM_Q_FAKE_CALLS="$calls" \
    "$BIN/fm-api.sh" worker.cleanup) || fail "completed Q scout cleanup failed"
  printf '%s\n' "$out" | jq -e \
    '.result == "ok" and .postcondition_evidence.q_settled == true' >/dev/null \
    || fail "completed Q scout cleanup did not confirm lease settlement"
  grep -F -- 'guard complete --data-dir' "$calls" >/dev/null \
    || fail "completed Q scout cleanup did not use the completion boundary"
  pass "Q worker cleanup settles a completed investigation child"
}

test_q_root_investigation_cleanup_leaves_settlement_to_q() {
  local home request out
  home="$TMP_ROOT/q-root-cleanup-home"
  mkdir -p "$home/state" "$home/data/root-scout"
  printf '%s\n' 'q_root_task_id=task-root' 'q_execution_id=exec-root-scout' \
    'q_lease_id=lease-root-scout' 'q_phase=investigation' \
    >"$home/state/root-scout.meta"
  printf '%s\n' '{"schema":"q.worker-result.v3","root_task_id":"task-root","execution_id":"exec-root-scout","outcome":"completed"}' \
    >"$home/data/root-scout/q-result.json"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.cleanup","idempotency_key":"cleanup-q-root-scout","task_id":"root-scout"}'
  out=$(printf '%s\n' "$request" | FM_HOME="$home" \
    "$BIN/fm-api.sh" worker.cleanup) || fail "root Q scout cleanup failed"
  printf '%s\n' "$out" | jq -e \
    '.result == "ok" and .postcondition_evidence.cleanup == "confirmed" and .postcondition_evidence.q_settled == false' >/dev/null \
    || fail "root Q scout cleanup did not preserve Q-owned settlement"
  grep -Fqx '1' "$home/state/root-cleanup-flag" \
    || fail "root Q scout cleanup did not authorize the typed-result teardown path"
  pass "Q root investigation cleanup leaves lease settlement to Q"
}

test_inspect_reports_typed_worker_absence() {
  base='{"schema":"q.firstmate-request.v1","idempotency_key":"inspect-absent-1"'
  out=$(invoke worker.inspect "$base,"'"operation":"worker.inspect","task_id":"missing-worker"}')
  status=$?
  [ "$status" -eq 3 ] || fail "missing worker inspection did not preserve refusal status"
  printf '%s\n' "$out" | jq -e \
    '.schema == "fm-api-response.v1" and .result == "refused" and
     .postcondition_evidence == {
       schema:"fm-worker-observation.v1",
       task_id:"missing-worker",
       present:false,
       snapshot_schema:"fm-fleet-snapshot.v1"
     }' >/dev/null || fail "missing worker inspection did not return typed absence evidence"
  pass "worker.inspect reports typed snapshot absence"
}

test_worker_capture_resolves_recorded_endpoint_and_preserves_ansi() {
  printf '%s\n' 'window=fixture:fm-worker-capture' 'worktree=/tmp/work' 'project=repo' \
    >"$HOME_ROOT/state/worker-capture.meta"
  request='{"schema":"q.firstmate-request.v1","operation":"worker.capture","idempotency_key":"capture-1","task_id":"worker-capture","lines":120}'
  out=$(invoke worker.capture "$request") || fail "worker.capture failed"
  printf '%s\n' "$out" | jq -e '
    .result == "ok" and
    .postcondition_evidence.schema == "fm-terminal-frame.v1" and
    .postcondition_evidence.task_id == "worker-capture" and
    .postcondition_evidence.backend == "tmux" and
    .postcondition_evidence.styled == true and
    .postcondition_evidence.max_lines == 120 and
    (.postcondition_evidence.content | contains("\u001b[32mstyled worker output"))
  ' >/dev/null || fail "worker capture did not return bounded styled evidence"

  request='{"schema":"q.firstmate-request.v1","operation":"worker.capture","idempotency_key":"capture-too-large","task_id":"worker-capture","lines":501}'
  out=$(invoke worker.capture "$request")
  [ "$?" -eq 2 ] || fail "worker.capture accepted an unbounded line count"
  printf '%s\n' "$out" | jq -e '.result == "refused"' >/dev/null \
    || fail "unbounded worker capture did not return a typed refusal"
  pass "worker.capture resolves recorded endpoints and preserves ANSI"
}

test_worker_relaunch_delegates_with_q_transport() {
  request='{"schema":"q.firstmate-request.v1","operation":"worker.relaunch","idempotency_key":"repair-1","task_id":"worker-1","note":"Repair failed validation.","q":{"guard_executable":"/bin/true","data_dir":"/tmp/q-data"}}'
  out=$(invoke worker.relaunch "$request") || fail "worker.relaunch failed"
  printf '%s\n' "$out" | jq -e '.postcondition_evidence.relaunch == "confirmed"' >/dev/null \
    || fail "worker relaunch evidence is invalid"
  [ "$(cat "$HOME_ROOT/state/relaunch-operation-key")" = repair-1 ] \
    || fail "worker relaunch did not propagate the stable facade operation key"
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

  out=$(FM_HOME="$home" FM_Q_MANAGED=1 FM_Q_PREAUTHORIZED=1 \
    FM_Q_ROOT_TASK_ID=task-root FM_Q_EXECUTION_ID=exec-report \
    FM_Q_LEASE_ID=lease-report FM_Q_PHASE=report \
    FM_Q_CONTRACT_SCHEMA=q.worker-contract.v2 FM_Q_DEPTH=0 \
    FM_Q_EXPECTED_WALL_SECONDS=300 FM_Q_CLI=/bin/true \
    FM_Q_DATA_DIR="$TMP_ROOT/q-data" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" q-v2-report projects/missing --scout \
    --harness codex --model default --effort medium 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing v2 report project should not launch"
  printf '%s\n' "$out" | grep -F 'FM_Q_CONTRACT_SCHEMA' >/dev/null \
    && fail "real spawn rejected the v2 worker contract before project validation"
  printf '%s\n' "$out" | grep -F 'invalid FM_Q_PHASE' >/dev/null \
    && fail "real spawn rejected the report phase"
  [ ! -e "$home/state/q-v2-report.meta" ] \
    || fail "refused v2 report spawn mutated task metadata"
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
      printf '%s\n' '{"schema":"q.guard-authorization.v1","result":"authorized","root_task_id":"task-root","parent_execution_id":"exec-parent","execution_id":"exec-child","external_task_id":"child-one","requested_depth":1,"lease_id":"lease-child","lease_state":"reserved","denial_reason":null,"result_contract":{"schema":"q.worker-result.v2","root_task_id":"task-root","execution_id":"exec-child","outcome":"completed | failed | blocked","summary":"string","artifacts":[],"investigation_report":null,"usage":[],"evidence":[],"observed_repository":"/repo","observed_revision":"git rev-parse HEAD after the final commit","worktree":"pwd -P","branch":"git branch --show-current, or null when detached","completed_at":"RFC3339 timestamp"}}'
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
    DATA="$TMP_ROOT/q-child-data"
    mkdir -p "$DATA/child-one"
    printf '%s\n' 'child brief' >"$DATA/child-one/brief.md"
    fm_q_guard_authorize_child child-one ship codex model high || exit 1
    [ "$FM_Q_PARENT_EXECUTION_ID" = exec-parent ] || exit 1
    [ "$FM_Q_EXECUTION_ID" = exec-child ] || exit 1
    [ "$FM_Q_LEASE_ID" = lease-child ] || exit 1
    [ "$FM_Q_DEPTH" = 1 ] || exit 1
    [ "$(jq -r .schema <<<"$FM_Q_RESULT_CONTRACT")" = q.worker-result.v2 ] || exit 1
    fm_q_guard_append_child_result_contract child-one || exit 1
    grep -F 'Quartermaster delegated-child completion override' \
      "$DATA/child-one/brief.md" >/dev/null || exit 1
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
    # shellcheck disable=SC2030,SC2031
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

test_q_guard_reuses_facade_operation_key_across_transaction_recovery() {
  local fake_q="$TMP_ROOT/fake-q-stable" key_one key_two
  mkdir -p "$TMP_ROOT/q-data"
  cat >"$fake_q" <<'SH'
#!/usr/bin/env bash
key=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --idempotency-key ]; then key=$2; shift 2; else shift; fi
done
printf '%s\n' "$key" >>"$FM_Q_DATA_DIR/retry-keys"
jq -cn --arg key "$key" '{schema:"q.guard-retry-authorization.v1",result:"authorized",root_task_id:"task-root",execution_id:"exec-child",idempotency_key:$key,denial_reason:null}'
SH
  chmod +x "$fake_q"
  (
    # shellcheck source=bin/fm-q-guard-lib.sh
    . "$BIN/fm-q-guard-lib.sh"
    # shellcheck disable=SC2030,SC2031
    export FM_Q_MANAGED=1 FM_Q_ROOT_TASK_ID=task-root FM_Q_EXECUTION_ID=exec-child
    # shellcheck disable=SC2030,SC2031
    export FM_Q_CLI="$fake_q" FM_Q_DATA_DIR="$TMP_ROOT/q-data"
    # shellcheck disable=SC2030,SC2031
    export FM_Q_RELAUNCH_IDEMPOTENCY_KEY=validation-repair-task
    FM_CONTROL_RELAUNCH_TX=tx-one fm_q_guard_authorize_relaunch
    FM_CONTROL_RELAUNCH_TX=tx-two fm_q_guard_authorize_relaunch
  ) || fail "stable facade relaunch key should authorize on recovery"
  key_one=$(sed -n '1p' "$TMP_ROOT/q-data/retry-keys")
  key_two=$(sed -n '2p' "$TMP_ROOT/q-data/retry-keys")
  [ -n "$key_one" ] || fail "facade recovery must send a non-empty Q retry key"
  [ "$key_one" = "$key_two" ] || fail "facade recovery must replay one Q retry key"
  pass "Q relaunch recovery reuses the facade operation identity"
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
  grep -F 'data.result' "$supervisor_home/data/supervisor-1/charter.md" >/dev/null 2>&1 \
    || grep -R -F 'data.result' "$supervisor_home" >/dev/null 2>&1 \
    || fail "supervisor charter did not require the typed terminal child result"
  grep -R -F 'their absence is not a blocker' "$supervisor_home" >/dev/null 2>&1 \
    || fail "supervisor charter did not exclude unrelated Firstmate dependencies"
  grep -R -F 'the field is named event, never state' "$supervisor_home" >/dev/null 2>&1 \
    || fail "supervisor charter did not make the event discriminator explicit"

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

  printf '%s\n' '{"schema":"q.supervisor-event.v1","sequence":1,"state":"accepted","root_task_id":"task-root","message":"wrong discriminator","data":{}}' \
    >"$supervisor_home/state/q-supervisor-events.jsonl"
  out=$(invoke supervisor.inspect "$request")
  [ "$?" -eq 1 ] || fail "invalid supervisor event discriminator was accepted"
  printf '%s\n' "$out" | jq -e '.result == "error" and .error == "supervisor event stream is invalid"' >/dev/null \
    || fail "invalid supervisor event stream did not return a typed error"
  printf '%s\n' '{"schema":"q.supervisor-event.v1","sequence":1,"event":"accepted","root_task_id":"task-root","message":"accepted","data":{}}' \
    >"$supervisor_home/state/q-supervisor-events.jsonl"

  base='{"schema":"q.firstmate-request.v1","idempotency_key":"supervisor-operation-1"'
  out=$(invoke supervisor.send "$base,"'"operation":"supervisor.send","task_id":"supervisor-1","message":"continue"}') || fail "supervisor.send failed"
  printf '%s\n' "$out" | jq -e '.result == "ok"' >/dev/null || fail "supervisor send response invalid"
  out=$(invoke supervisor.stop "$base,"'"operation":"supervisor.stop","task_id":"supervisor-1"}') || fail "supervisor.stop failed"
  printf '%s\n' "$out" | jq -e '
    .postcondition_evidence.confirmed == true and
    .postcondition_evidence.retirement_receipt.schema == "fm.retirement-receipt.v1" and
    .postcondition_evidence.retirement_receipt.root_task_id == "task-root" and
    .postcondition_evidence.retirement_receipt.actors[0].role == "supervisor"
  ' >/dev/null \
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

test_v2_delivery_delegates_exact_head_local_landing() {
  base=1111111111111111111111111111111111111111
  head=2222222222222222222222222222222222222222
  request=$(jq -cn --arg base "$base" --arg head "$head" \
    '{schema:"q.firstmate-request.v2",operation:"delivery.execute",
      idempotency_key:"delivery-v2",task_id:"worker-v2",action:"land",mode:"local-only",
      local_landing:{root_task_id:"task-root",repository:"/repo",worktree:"/worktree",
        starting_revision:$base,validated_revision:$head,supervisor_child:false,
        authority:"trusted_user_config"}}')
  out=$(invoke delivery.execute "$request") || fail "v2 local delivery failed"
  printf '%s\n' "$out" | jq -e --arg head "$head" '
    .result == "ok" and .postcondition_evidence.confirmed == true and
    .postcondition_evidence.observed_head == $head
  ' >/dev/null || fail "v2 local delivery evidence is invalid"
  sed -n '1p' "$HOME_ROOT/state/q-local-land-argv" | grep -Fqx worker-v2 \
    || fail "v2 local delivery did not preserve the worker identity"
  sed -n '7p' "$HOME_ROOT/state/q-local-land-argv" | grep -Fqx task-root \
    || fail "v2 local delivery did not preserve the root identity"
  pass "v2 delivery delegates exact-head automatic local landing"
}

test_capabilities_are_one_versioned_json_object
test_invalid_request_refuses_as_json
test_prepare_delegates_and_renders_contract
test_v2_report_worker_contract_prepares_and_spawns
test_v2_investigation_prepares_without_artifact_publication
test_worker_result_validates_durable_identity
test_worker_result_accepts_v2_typed_evidence
test_worker_result_v3_and_retirement_are_typed_and_idempotent
test_worker_result_v3_canonicalizes_redundant_artifact_declarations
test_legacy_v3_investigation_report_is_normalized_to_internal_summary
test_codex_worker_result_waits_for_and_reports_structured_usage
test_spawn_requires_metadata_postcondition
test_supervised_worker_spawn_commits_pre_authorized_lease
test_report_only_spawn_accepts_inspect_phase
test_owner_failure_returns_one_error_response
test_snapshot_inspect_and_lifecycle_delegation
test_q_worker_cleanup_settles_failed_child_lease
test_q_worker_cleanup_settles_completed_investigation_child
test_q_root_investigation_cleanup_leaves_settlement_to_q
test_inspect_reports_typed_worker_absence
test_worker_capture_resolves_recorded_endpoint_and_preserves_ansi
test_worker_relaunch_delegates_with_q_transport
test_q_spawn_validation_is_opt_in_and_precedes_mutation
test_q_guard_authorizes_propagates_and_releases
test_q_guard_authorizes_each_relaunch_transaction
test_q_guard_reuses_facade_operation_key_across_transaction_recovery
test_q_guard_refuses_denial_and_unavailable_contract
test_supervisor_operations_use_secondmate_owners_and_structured_events
test_delivery_delegates_to_confirming_merge_owner
test_v2_delivery_delegates_exact_head_local_landing
