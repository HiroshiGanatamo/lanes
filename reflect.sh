#!/usr/bin/env bash
# Learning loop: turn failed orchestration units into reviewed, staged spec-writing lessons.
set -euo pipefail

ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'reflect: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[2m[reflect]\033[0m %s\n' "$*" >&2; }

usage() {
  printf 'usage: reflect.sh [--repo DIR] [--report FILE] [--lane grok|codex|kimi] [--promote] [--dry-run]\n'
}

REPO=""; REPORT=""; LANE=grok; PROMOTE=0; DRY=0

while (( $# )); do
  case "$1" in
    --repo)    [[ $# -ge 2 ]] || die "--repo requires a directory"
               REPO="$2"; shift 2 ;;
    --report)  [[ $# -ge 2 ]] || die "--report requires a file"
               REPORT="$2"; shift 2 ;;
    --lane)    [[ $# -ge 2 ]] || die "--lane requires grok, codex, or kimi"
               LANE="$2"; shift 2 ;;
    --promote) PROMOTE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq required"
[[ -z "$REPO" ]] && REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "not in a git repo; pass --repo"
REPO="$(cd "$REPO" && pwd)"
[[ -z "$REPORT" ]] && REPORT="$REPO/.orch/report.json"

STAGED="$REPO/.orch/lessons-staged.md"
LESSONS="$ORCH_HOME/LESSONS.md"

promote_lessons() {
  local today lines start tmp capped
  today=$(date -u +%Y-%m-%d)

  if [[ ! -s "$STAGED" ]]; then
    log "no staged lessons to promote"
    return
  fi

  if (( DRY )); then
    printf '## %s\n' "$today"
    cat "$STAGED"
    log "dry run — staged lessons would be promoted"
    return
  fi

  [[ -f "$LESSONS" ]] || printf '# Lessons\n' > "$LESSONS"
  tmp=$(mktemp "$ORCH_HOME/.lessons.XXXXXX")
  capped="${tmp}.capped"
  trap 'rm -f "${tmp:-}" "${capped:-}"' RETURN

  cat "$LESSONS" > "$tmp"
  printf '\n## %s\n' "$today" >> "$tmp"
  cat "$STAGED" >> "$tmp"

  lines=$(awk 'END { print NR }' "$tmp")
  if (( lines > 200 )); then
    start=$(( lines - 199 ))
    sed -n "${start},\$p" "$tmp" > "$capped"
    mv "$capped" "$LESSONS"
    log "WARNING: older lessons were dropped to enforce the 200-line cap; fold them into templates/ instead"
  else
    mv "$tmp" "$LESSONS"
  fi
  : > "$STAGED"
  trap - RETURN
  rm -f "$tmp" "$capped"
  log "promoted staged lessons into $LESSONS"
}

if (( PROMOTE )); then
  promote_lessons
  exit 0
fi

[[ -f "$REPORT" ]] || die "no report: $REPORT"
case "$LANE" in
  grok|codex|kimi) ;;
  *) die "unknown lane: $LANE" ;;
esac

mapfile -t FAILED_UNITS < <(jq -c '.units[] | select(.status == "gate_failed" or .status == "worker_failed")' "$REPORT")
if (( ${#FAILED_UNITS[@]} == 0 )); then
  log "no failures to learn from"
  exit 0
fi

prompt='Review these failed orchestration units and identify lessons for writing better future specs.
Return JSONL only, one object per line, with exactly this shape:
{"lesson":"<one sentence, imperative>","cause":"spec|gate|lane|environment","unit":"<id>"}
Each lesson must say what to do differently when WRITING THE SPEC, not how to fix the failed code.'

for unit in "${FAILED_UNITS[@]}"; do
  id=$(jq -r '.id' <<<"$unit")
  slug=$(jq -r '.slug' <<<"$unit")
  lane=$(jq -r '.lane // ""' <<<"$unit")
  effort=$(jq -r '.effort // ""' <<<"$unit")
  gate=$(jq -r '.gate // ""' <<<"$unit")
  gate_tail=$(jq -r '.gate_tail // "" | .[0:1500]' <<<"$unit")
  spec_rel=$(jq -r '.spec // ""' <<<"$unit")
  [[ -z "$spec_rel" ]] && spec_rel="$slug.md"
  spec_rel="${spec_rel#specs/}"
  [[ "$spec_rel" != ".." && "$spec_rel" != ../* && "$spec_rel" != */../* ]] \
    || die "unit $id: spec path escapes .orch/specs: $spec_rel"
  spec_path="$REPO/.orch/specs/$spec_rel"
  [[ -f "$spec_path" ]] || die "unit $id: spec not found: $spec_path"

  prompt+="

--- FAILED UNIT ---
id: $id
lane: $lane
effort: $effort
gate: $gate
gate_tail (first 1500 characters):
$gate_tail
spec:
$(cat "$spec_path")"
done

if (( DRY )); then
  printf '%s\n' "$prompt"
  log "dry run — ${#FAILED_UNITS[@]} failed unit(s) would be analyzed by $LANE"
  exit 0
fi

raw=""
if [[ -n "${REFLECT_LANE_CMD:-}" ]]; then
  raw=$(printf '%s\n' "$prompt" | bash -c "$REFLECT_LANE_CMD")
else
  case "$LANE" in
    grok)
      raw=$(grok --always-approve --max-turns 20 --effort medium --output-format json -p "$prompt")
      raw=$(jq -er '.text' <<<"$raw") ;;
    codex) raw=$(codex exec --yolo "$prompt") ;;
    kimi)  raw=$(kimi -p "$prompt") ;;
  esac
fi

mkdir -p "$REPO/.orch"
: >> "$STAGED"
staged_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  item=$(jq -er '
    select(type == "object")
    | select((.lesson | type) == "string" and (.lesson | length) > 0)
    | select(.cause == "spec" or .cause == "gate" or .cause == "lane" or .cause == "environment")
    | select((.unit | type) == "string" and (.unit | length) > 0)
    | "- \(.lesson) (cause: \(.cause); unit: \(.unit))"
  ' <<<"$line" 2>/dev/null) || { log "skipping malformed lesson line"; continue; }
  printf '%s\n' "$item" >> "$STAGED"
  (( staged_count++ )) || true
done <<< "$raw"

log "staged $staged_count lesson(s) in $STAGED"
