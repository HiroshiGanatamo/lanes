#!/usr/bin/env bash
# Integration half of the fan-out loop: commit each passing unit's worktree, merge it into the
# working branch, prune the worktree. Reads report.json; writes merge-report.json.
#
# Refuses to merge anything whose gate did not pass. Conflicts stop that unit and leave the merge
# in progress for a human — nothing is force-resolved.
set -euo pipefail

die() { printf 'merge: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[2m[merge]\033[0m %s\n' "$*" >&2; }

REPO=""; REPORT=""; TARGET=""; DRY=0; KEEP=0; FORCE_FAILED=0

while (( $# )); do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --report)      REPORT="$2"; shift 2 ;;
    --into)        TARGET="$2"; shift 2 ;;
    --dry-run)     DRY=1; shift ;;
    --keep-worktrees) KEEP=1; shift ;;
    --include-failed) FORCE_FAILED=1; shift ;;
    -h|--help)
      printf 'usage: merge.sh [--repo DIR] [--report FILE] [--into BRANCH] [--dry-run]\n'
      printf '                [--keep-worktrees] [--include-failed]\n\n'
      printf 'Commits and merges every unit whose gate passed. Conflicts stop that unit.\n'
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq required"
[[ -z "$REPO" ]] && REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "not in a git repo; pass --repo"
REPO="$(cd "$REPO" && pwd)"
[[ -z "$REPORT" ]] && REPORT="$REPO/.orch/report.json"
[[ -f "$REPORT" ]] || die "no report: $REPORT"

# Merging into a detached HEAD or into whatever happened to be checked out is how work gets lost.
[[ -z "$TARGET" ]] && TARGET="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || true)"
[[ -n "$TARGET" ]] || die "target branch is detached HEAD; pass --into"

if [[ "$TARGET" == "main" || "$TARGET" == "master" ]]; then
  die "refusing to merge into $TARGET — branch first (git checkout -b feat/<slug>), then re-run"
fi

# The orchestration scaffolding is not "dirt" — exclude it the same way run.sh does, in case
# merge.sh is the first of the pair to run in this repo.
# Worktree repos have `.git` as a file, not a directory — resolve via git-path.
excl="$(git -C "$REPO" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null || echo "$REPO/.git/info/exclude")"
mkdir -p "$(dirname "$excl")"
for p in '.orch/' '.wt/'; do
  grep -qxF "$p" "$excl" 2>/dev/null || printf '%s\n' "$p" >> "$excl"
done

if [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]]; then
  die "working tree at $REPO is dirty; commit or stash before merging units into it"
fi

# Only units that actually proved themselves. A worker's own report is not evidence.
FILTER='.units[] | select(.kind != "recon")'
if (( FORCE_FAILED )); then
  log "WARNING: --include-failed merges units whose gate never passed"
else
  FILTER="$FILTER | select(.status == \"pass\")"
fi
mapfile -t UNITS < <(jq -c "$FILTER" "$REPORT")

SKIPPED=$(jq -r '[.units[] | select(.kind != "recon") | select(.status != "pass")] | length' "$REPORT")
(( ${#UNITS[@]} )) || die "no passing units to merge ($SKIPPED skipped)"

log "target branch: $TARGET"
log "${#UNITS[@]} passing unit(s) to merge, $SKIPPED skipped"

if (( DRY )); then
  jq -r "$FILTER | \"  \(.id)  \(.branch)  \(.files_changed) files  gate: \(.gate)\"" "$REPORT" >&2
  log "dry run — nothing committed or merged"
  exit 0
fi

RESULTS="$REPO/.orch/merge-results"
rm -rf "$RESULTS"; mkdir -p "$RESULTS"

for unit in "${UNITS[@]}"; do
  id=$(jq -r '.id'    <<<"$unit")
  slug=$(jq -r '.slug' <<<"$unit")
  branch=$(jq -r '.branch' <<<"$unit")
  wt=$(jq -r '.worktree' <<<"$unit")
  gate=$(jq -r '.gate' <<<"$unit")
  lane=$(jq -r '.lane' <<<"$unit")

  outcome="merged"; detail=""

  if [[ ! -d "$wt" ]]; then
    outcome="missing_worktree"; detail="$wt does not exist"
  elif [[ -z "$(git -C "$wt" status --porcelain)" ]]; then
    outcome="empty"; detail="worker left no changes"
  else
    # Re-run the gate before committing. The report can be stale — a later unit may have merged
    # something that breaks this one, and a green line in a JSON file is not a green test now.
    if [[ -n "$gate" ]] && ! (cd "$wt" && bash -c "$gate") >/dev/null 2>&1; then
      outcome="gate_regressed"; detail="gate failed on re-run just before commit"
    else
      # A unit may name its own subject line, so a plan that mandates Conventional Commits gets
      # them. Without one, fall back to something descriptive rather than the gate command.
      subject=$(jq -r '.commit // empty' <<<"$unit")
      [[ -n "$subject" ]] || subject="chore($slug): implement unit $id"
      coauthor="${ORCH_COAUTHOR:-Claude Opus 5 <noreply@anthropic.com>}"

      git -C "$wt" add -A
      git -C "$wt" commit -q -m "$subject

Implemented by the $lane lane against .orch/specs, gate: $gate

Co-Authored-By: $coauthor" || { outcome="commit_failed"; detail="git commit returned non-zero"; }

      if [[ "$outcome" == "merged" ]]; then
        if git -C "$REPO" merge --no-ff --no-edit "$branch" >/dev/null 2>&1; then
          detail="$(git -C "$REPO" rev-parse --short HEAD)"
        else
          outcome="conflict"
          detail="$(git -C "$REPO" diff --name-only --diff-filter=U | tr '\n' ' ')"
          git -C "$REPO" merge --abort 2>/dev/null || true
        fi
      fi
    fi
  fi

  jq -n --arg id "$id" --arg slug "$slug" --arg branch "$branch" --arg wt "$wt" \
        --arg outcome "$outcome" --arg detail "$detail" \
        '{id:$id,slug:$slug,branch:$branch,worktree:$wt,outcome:$outcome,detail:$detail}' \
        > "$RESULTS/$id.json"

  log "$id [$outcome] ${detail:0:70}"

  # A conflicted branch keeps its worktree — that is where the human resolves it.
  if (( ! KEEP )) && [[ "$outcome" == "merged" || "$outcome" == "empty" ]]; then
    git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
done

git -C "$REPO" worktree prune 2>/dev/null || true

MERGE_REPORT="$REPO/.orch/merge-report.json"
jq -s --arg repo "$REPO" --arg target "$TARGET" --argjson skipped "$SKIPPED" '{
  repo: $repo, target: $target, skipped_not_passing: $skipped,
  units: .,
  summary: {
    merged:    (map(select(.outcome == "merged"))    | length),
    conflict:  (map(select(.outcome == "conflict"))  | length),
    empty:     (map(select(.outcome == "empty"))     | length),
    regressed: (map(select(.outcome == "gate_regressed")) | length),
    failed:    (map(select(.outcome | test("failed|missing"))) | length)
  }
}' "$RESULTS"/*.json > "$MERGE_REPORT"

printf '\n%-8s %-16s %s\n' ID OUTCOME DETAIL >&2
jq -r '.units[] | [.id,.outcome,(.detail[0:60])] | @tsv' "$MERGE_REPORT" \
  | while IFS=$'\t' read -r a b c; do printf '%-8s %-16s %s\n' "$a" "$b" "$c"; done >&2

printf '\nmerge report: %s\n' "$MERGE_REPORT" >&2
jq -r '.summary | "merged \(.merged)  conflict \(.conflict)  empty \(.empty)  regressed \(.regressed)  failed \(.failed)"' "$MERGE_REPORT" >&2

# Conflicts are the human's problem by design; exit non-zero so a loop stops here.
jq -e '.summary.conflict == 0 and .summary.regressed == 0 and .summary.failed == 0' "$MERGE_REPORT" >/dev/null
