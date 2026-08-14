#!/usr/bin/env bash
# Overnight batch driver: dispatch each queued backlog job, merge what passed,
# and leave one digest for the morning.
set -euo pipefail

ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- helpers ----------------------------------------------------------------

die() { printf 'nightly: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[2m[nightly]\033[0m %s\n' "$*" >&2; }

# --- argument parsing -------------------------------------------------------

REPO=""; BACKLOG=""; DRY=0

while (( $# )); do
  case "$1" in
    --repo)     REPO="$2"; shift 2 ;;
    --backlog)  BACKLOG="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)
      printf 'usage: nightly.sh [--repo DIR] [--backlog DIR] [--dry-run]\n\n'
      printf 'Unattended overnight pass: dispatch backlog jobs, merge what passed,\n'
      printf 'and write a digest to <repo>/.orch/nightly-digest.md.\n'
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq required"
[[ -z "$REPO" ]] && REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "not in a git repo; pass --repo"
REPO="$(cd "$REPO" && pwd)"

ORCH="$REPO/.orch"
mkdir -p "$ORCH"

[[ -z "$BACKLOG" ]] && BACKLOG="$ORCH/backlog"

if [[ ! -d "$BACKLOG" ]]; then
  log "backlog missing ($BACKLOG) — nothing to do"
  exit 0
fi

mapfile -t JOBS < <(find "$BACKLOG" -maxdepth 1 -type f -name '*.json' -print | sort)

if (( ${#JOBS[@]} == 0 )); then
  log "backlog empty ($BACKLOG) — nothing to do"
  exit 0
fi

if (( DRY )); then
  log "dry run — would process ${#JOBS[@]} job(s):"
  for job in "${JOBS[@]}"; do
    printf '  %s\n' "$(basename "$job")" >&2
  done
  exit 0
fi

mkdir -p "$BACKLOG"/done "$BACKLOG"/failed

PER_JOB="$ORCH/.nightly-jobs.jsonl"
: > "$PER_JOB"

# --- process each job -------------------------------------------------------

for job in "${JOBS[@]}"; do
  name="$(basename "$job")"
  log "job: $name"

  job_start=$SECONDS
  run_exit=0
  "$ORCH_HOME/run.sh" --repo "$REPO" "$job" >&2 || run_exit=$?

  pass=0 total=0 gate_failed=0 worker_failed=0 no_gate=0 answered=0 run_seconds=0
  if (( run_exit == 0 )) && [[ -f "$ORCH/report.json" ]]; then
    pass=$(jq -r '.summary.pass // 0' "$ORCH/report.json")
    total=$(jq -r '.summary.total // 0' "$ORCH/report.json")
    gate_failed=$(jq -r '.summary.gate_failed // 0' "$ORCH/report.json")
    worker_failed=$(jq -r '.summary.worker_failed // 0' "$ORCH/report.json")
    no_gate=$(jq -r '.summary.no_gate // 0' "$ORCH/report.json")
    answered=$(jq -r '.summary.answered // 0' "$ORCH/report.json")
    run_seconds=$(jq -r '.summary.seconds // 0' "$ORCH/report.json")
  fi

  merged=0 conflict=0 regressed=0 failed=0 merge_exit=0
  conflicts_json='[]'
  if (( pass > 0 )); then
    merge_exit=0
    "$ORCH_HOME/merge.sh" --repo "$REPO" >&2 || merge_exit=$?
    if [[ -f "$ORCH/merge-report.json" ]]; then
      merged=$(jq -r '.summary.merged // 0' "$ORCH/merge-report.json")
      conflict=$(jq -r '.summary.conflict // 0' "$ORCH/merge-report.json")
      regressed=$(jq -r '.summary.regressed // 0' "$ORCH/merge-report.json")
      failed=$(jq -r '.summary.failed // 0' "$ORCH/merge-report.json")
      conflicts_json=$(jq -c '[.units[] | select(.outcome == "conflict") | .branch]' "$ORCH/merge-report.json")
    fi
  fi

  elapsed=$(( SECONDS - job_start ))

  if (( pass > 0 )); then
    if mv "$job" "$BACKLOG/done/$name" 2>/dev/null; then
      disposition="done"
    else
      disposition="move_failed"
    fi
  else
    if mv "$job" "$BACKLOG/failed/$name" 2>/dev/null; then
      disposition="failed"
    else
      disposition="move_failed"
    fi
  fi

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s %s run_exit=%d pass=%d/%d merged=%d conflict=%d disposition=%s\n' \
    "$ts" "$name" "$run_exit" "$pass" "$total" "$merged" "$conflict" "$disposition" >> "$ORCH/nightly.log"

  jq -n \
    --arg job "$name" \
    --argjson run_exit "$run_exit" \
    --argjson pass "${pass:-0}" \
    --argjson total "${total:-0}" \
    --argjson gate_failed "${gate_failed:-0}" \
    --argjson worker_failed "${worker_failed:-0}" \
    --argjson no_gate "${no_gate:-0}" \
    --argjson answered "${answered:-0}" \
    --argjson run_seconds "${run_seconds:-0}" \
    --argjson merged "${merged:-0}" \
    --argjson conflict "${conflict:-0}" \
    --argjson regressed "${regressed:-0}" \
    --argjson failed "${failed:-0}" \
    --argjson merge_exit "${merge_exit:-0}" \
    --argjson elapsed "$elapsed" \
    --argjson conflicts "$conflicts_json" \
    --arg disposition "$disposition" \
    '{
      job: $job,
      run_exit: $run_exit,
      pass: $pass,
      total: $total,
      gate_failed: $gate_failed,
      worker_failed: $worker_failed,
      no_gate: $no_gate,
      answered: $answered,
      run_seconds: $run_seconds,
      merged: $merged,
      conflict: $conflict,
      regressed: $regressed,
      failed: $failed,
      merge_exit: $merge_exit,
      elapsed: $elapsed,
      conflicts: $conflicts,
      disposition: $disposition
    }' >> "$PER_JOB"
done

# --- digest -----------------------------------------------------------------

DIGEST="$ORCH/nightly-digest.md"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -rs --arg ts "$ts" '
  def fmt_conflicts:
    if (.conflicts | length) == 0 then "none"
    else (.conflicts | join(", ")) end;

  "# Nightly digest — \($ts)\n",
  "",
  ( .[] |
    "## \(.job)",
    "",
    "- Units: \(.pass) passed / \(.total) total (\(.gate_failed) gate-failed, \(.worker_failed) worker-failed, \(.no_gate) no-gate, \(.answered) answered)",
    "- Merged: \(.merged)",
    "- Conflicts: \(.conflict) (\(fmt_conflicts))",
    "- Wall-clock: \(.run_seconds)s",
    "- Disposition: \(.disposition)",
    ""
  ),
  "## Totals",
  "",
  "- Jobs: \(length)",
  "- Units passed: \((map(.pass) | add // 0))",
  "- Units merged: \((map(.merged) | add // 0))",
  "- Conflicts: \((map(.conflict) | add // 0))"
' "$PER_JOB" > "$DIGEST"

log "digest: $DIGEST"
