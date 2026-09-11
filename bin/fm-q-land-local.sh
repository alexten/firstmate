#!/usr/bin/env bash
# Land one Q-validated local-only changeset into the captain's requested checkout.
# Q supplies exact base/head identities; this owner re-verifies them, releases the
# Firstmate captain hold, imports a supervised child commit when necessary, and
# performs only a clean fast-forward of the checked-out default branch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ "$#" -ne 7 ]; then
  echo "error: expected task, worker home, repository, worktree, base, head, and root task" >&2
  exit 2
fi

ID=$1
WORKER_HOME=$2
DESTINATION=$3
WORKTREE=$4
EXPECTED_BASE=$5
VALIDATED_HEAD=$6
ROOT_TASK_ID=$7

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
fm_pr_task_id_valid "$ID" || { echo "error: invalid Q local-land task id" >&2; exit 2; }

case "$EXPECTED_BASE:$VALIDATED_HEAD" in
  *[!0-9a-f:]*|:*|*:) echo "error: invalid Q local-land revision" >&2; exit 2 ;;
esac
[ "${#EXPECTED_BASE}" -eq 40 ] && [ "${#VALIDATED_HEAD}" -eq 40 ] || {
  echo "error: Q local-land revisions must be full SHA-1 object names" >&2
  exit 2
}

WORKER_HOME=$(realpath -e -- "$WORKER_HOME")
DESTINATION=$(realpath -e -- "$DESTINATION")
WORKTREE=$(realpath -e -- "$WORKTREE")
META="$WORKER_HOME/state/$ID.meta"
[ -f "$META" ] || { echo "error: Q local-land worker metadata is missing" >&2; exit 1; }

recorded_root=$(sed -n 's/^q_root_task_id=//p' "$META")
recorded_worktree=$(sed -n 's/^worktree=//p' "$META")
recorded_mode=$(sed -n 's/^mode=//p' "$META")
recorded_project=$(sed -n 's/^project=//p' "$META")
[ "$recorded_root" = "$ROOT_TASK_ID" ] || {
  echo "error: Q local-land root identity does not match worker metadata" >&2
  exit 1
}
[ "$recorded_mode" = local-only ] || {
  echo "error: Q local-land requires local-only worker metadata" >&2
  exit 1
}
[ -n "$recorded_worktree" ] && [ "$(realpath -e -- "$recorded_worktree")" = "$WORKTREE" ] || {
  echo "error: Q local-land worktree does not match worker metadata" >&2
  exit 1
}
[ -n "$recorded_project" ] && [ -d "$recorded_project" ] || {
  echo "error: Q local-land project metadata is unavailable" >&2
  exit 1
}
recorded_project=$(realpath -e -- "$recorded_project")
if [ "$recorded_project" != "$DESTINATION" ]; then
  project_origin=$(git -C "$recorded_project" remote get-url origin 2>/dev/null || true)
  case "$project_origin" in
    file://*) project_origin=${project_origin#file://} ;;
  esac
  [ -n "$project_origin" ] && [ -e "$project_origin" ] && \
      [ "$(realpath -e -- "$project_origin")" = "$DESTINATION" ] || {
    echo "error: Q local-land destination is not the worker project's local origin" >&2
    exit 1
  }
fi

git -C "$DESTINATION" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: Q local-land destination is not a Git checkout" >&2
  exit 1
}
git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: Q local-land source is not a Git worktree" >&2
  exit 1
}
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$VALIDATED_HEAD" ] || {
  echo "error: Q local-land source moved after validation" >&2
  exit 1
}
git -C "$WORKTREE" merge-base --is-ancestor "$EXPECTED_BASE" "$VALIDATED_HEAD" || {
  echo "error: Q local-land validated head is not based on the recorded start" >&2
  exit 1
}

default_branch() {
  local ref branch
  ref=$(git -C "$DESTINATION" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$DESTINATION" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || {
  echo "error: Q local-land could not determine the destination default branch" >&2
  exit 1
}
[ "$(git -C "$DESTINATION" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$DEFAULT" ] || {
  echo "error: Q local-land destination is not on its default branch" >&2
  exit 1
}
[ -z "$(git -C "$DESTINATION" status --porcelain | head -1)" ] || {
  echo "error: Q local-land destination is dirty" >&2
  exit 1
}

current=$(git -C "$DESTINATION" rev-parse HEAD)
if [ "$current" = "$VALIDATED_HEAD" ]; then
  jq -cn --arg destination "$DESTINATION" --arg head "$current" \
    '{confirmed:true,destination:$destination,observed_head:$head,already_landed:true}'
  exit 0
fi
[ "$current" = "$EXPECTED_BASE" ] || {
  echo "error: Q local-land destination moved after the task started" >&2
  exit 1
}

hold_status=0
env FM_HOME="$WORKER_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" \
  open "$ID" --distinguish-absent >/dev/null 2>&1 || hold_status=$?
case "$hold_status" in
  0)
    decision=$(mktemp "${TMPDIR:-/tmp}/fm-q-land-decision.XXXXXX")
    trap 'rm -f "$decision"' EXIT HUP INT TERM
    printf 'Quartermaster trusted user configuration authorized exact-head local landing of %s.\n' \
      "$VALIDATED_HEAD" >"$decision"
    env FM_HOME="$WORKER_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$ID" \
      --decision-file "$decision" --release >/dev/null
    ;;
  1|3) ;;
  *) echo "error: Q local-land could not establish captain-hold state" >&2; exit 1 ;;
esac

if ! git -C "$DESTINATION" cat-file -e "$VALIDATED_HEAD^{commit}" 2>/dev/null; then
  git -C "$DESTINATION" fetch --quiet --no-tags "$WORKTREE" "$VALIDATED_HEAD"
fi
[ "$(git -C "$DESTINATION" rev-parse HEAD)" = "$EXPECTED_BASE" ] || {
  echo "error: Q local-land destination changed before fast-forward" >&2
  exit 1
}
git -C "$DESTINATION" merge --quiet --ff-only "$VALIDATED_HEAD"
observed=$(git -C "$DESTINATION" rev-parse HEAD)
[ "$observed" = "$VALIDATED_HEAD" ] || {
  echo "error: Q local-land could not confirm the validated head" >&2
  exit 1
}
jq -cn --arg destination "$DESTINATION" --arg head "$observed" \
  '{confirmed:true,destination:$destination,observed_head:$head,already_landed:false}'
