#!/usr/bin/env bash
# Health-check and benchmark tool for the three CLI worker lanes (codex, kimi, grok).
# Subcommands: doctor (liveness / version / default model), eval (fixed benchmark).
set -euo pipefail

LANES=(codex kimi grok)
PROBE_TIMEOUT=90
EVAL_TIMEOUT=180
DEFAULT_EFFORT=medium

# --- helpers ----------------------------------------------------------------

die() { printf 'lanes: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[2m[lanes]\033[0m %s\n' "$*" >&2; }

# macOS ships no coreutils timeout; run in background and reap.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    (( waited >= secs )) && { kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 124; }
    sleep 1; (( waited++ ))
  done
  wait "$pid"
}

usage() {
  sed -n '2,4p' "$0"
  printf '\nusage: lanes.sh doctor\n'
  printf '       lanes.sh eval [--effort low|medium|high]\n'
}

# --- lane metadata ----------------------------------------------------------

lane_version() {
  case "$1" in
    codex) codex --version 2>/dev/null | head -1 || true ;;
    kimi)  kimi -V 2>/dev/null | head -1 || true ;;
    grok)  grok -v 2>/dev/null | head -1 || true ;;
  esac
}

# Extract a TOML key value; missing file or key → empty (caller prints -).
toml_key() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  # First non-comment assignment of key = "value" or key = value
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$/\\1/p" "$file" \
    | head -1 || true
}

lane_model() {
  case "$1" in
    codex) toml_key "${HOME}/.codex/config.toml" "model" ;;
    kimi)  toml_key "${HOME}/.kimi-code/config.toml" "default_model" ;;
    grok)
      if [[ -f "${HOME}/.grok/config.toml" ]]; then
        # Prefer an explicit model key; fall back to common aliases, else -
        local m
        m=$(toml_key "${HOME}/.grok/config.toml" "model")
        [[ -z "$m" ]] && m=$(toml_key "${HOME}/.grok/config.toml" "default_model")
        printf '%s' "$m"
      fi
      ;;
  esac
}

lane_probe() {
  case "$1" in
    codex) codex exec --yolo 'reply with exactly: LANE_OK' ;;
    kimi)  kimi -p 'reply with exactly: LANE_OK' ;;
    grok)  grok --always-approve --max-turns 2 -p 'reply with exactly: LANE_OK' ;;
  esac
}

# Fixed benchmark: count letter r in "strawberry" → 3. Self-contained, no repo.
BENCHMARK_PROMPT='Reply with only a single JSON object, no other text: {"answer": <number>} where <number> is how many times the letter r appears in the word strawberry.'

lane_eval() {
  local lane="$1" effort="$2" prompt="$3"
  case "$lane" in
    codex) codex exec --yolo -c "model_reasoning_effort=\"${effort}\"" "$prompt" ;;
    kimi)  kimi -p "$prompt" ;;
    grok)  grok --always-approve --max-turns 4 --effort "$effort" -p "$prompt" ;;
  esac
}

# --- doctor -----------------------------------------------------------------

cmd_doctor() {
  local live_count=0
  local lane ver model live_status out

  printf '%-8s %-8s %-36s %s\n' LANE LIVE VERSION MODEL

  for lane in "${LANES[@]}"; do
    ver=$(lane_version "$lane")
    [[ -z "$ver" ]] && ver="-"
    model=$(lane_model "$lane")
    [[ -z "$model" ]] && model="-"

    live_status=no
    out=""
    if command -v "$lane" >/dev/null 2>&1; then
      out=$(with_timeout "$PROBE_TIMEOUT" lane_probe "$lane" 2>&1) || true
      if grep -q 'LANE_OK' <<<"$out" 2>/dev/null; then
        live_status=yes
        (( live_count++ )) || true
      fi
    fi

    printf '%-8s %-8s %-36s %s\n' "$lane" "$live_status" "$ver" "$model"
  done

  if (( live_count == 0 )); then
    log "no live lanes"
    exit 1
  fi
  log "$live_count live lane(s)"
  exit 0
}

# --- eval -------------------------------------------------------------------

# Parse {"answer": N} from free-form CLI output; mark correct when N == 3.
eval_is_correct() {
  local text="$1"
  local n
  # Prefer a full JSON object if present
  n=$(printf '%s' "$text" | grep -oE '\{[[:space:]]*"answer"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*\}' | head -1 \
    | jq -r '.answer // empty' 2>/dev/null) || true
  if [[ -z "$n" ]]; then
    # Fallback: first "answer": <int> occurrence
    n=$(printf '%s' "$text" | sed -nE 's/.*"answer"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1) || true
  fi
  [[ "$n" == "3" ]]
}

cmd_eval() {
  local effort="$DEFAULT_EFFORT"
  while (( $# )); do
    case "$1" in
      --effort) [[ $# -ge 2 ]] || die "--effort requires low|medium|high"
                effort="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown eval flag: $1" ;;
    esac
  done
  case "$effort" in
    low|medium|high) ;;
    *) die "effort must be low, medium, or high (got: $effort)" ;;
  esac

  command -v jq >/dev/null || die "jq required"
  local eval_history="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.orch/eval-history.jsonl"
  mkdir -p "$(dirname "$eval_history")"

  # Probe first; only benchmark live lanes (same definition as doctor).
  local -a live=()
  local lane out
  log "probing lanes…"
  for lane in "${LANES[@]}"; do
    if ! command -v "$lane" >/dev/null 2>&1; then
      log "  $lane missing"
      continue
    fi
    out=$(with_timeout "$PROBE_TIMEOUT" lane_probe "$lane" 2>&1) || true
    if grep -q 'LANE_OK' <<<"$out" 2>/dev/null; then
      live+=("$lane"); log "  $lane live"
    else
      log "  $lane DEAD — skipped"
    fi
  done
  (( ${#live[@]} )) || die "no live lanes; nothing to eval"

  log "eval effort=$effort prompt=strawberry-r-count"
  printf '%-8s %-10s %-8s %s\n' LANE SECONDS CORRECT FIRST_LINE

  for lane in "${live[@]}"; do
    local start=$SECONDS elapsed raw first correct
    raw=""
    raw=$(with_timeout "$EVAL_TIMEOUT" lane_eval "$lane" "$effort" "$BENCHMARK_PROMPT" 2>&1) || true
    elapsed=$(( SECONDS - start ))

    first=$(printf '%s' "$raw" | grep -v '^[[:space:]]*$' | head -1 || true)
    [[ -z "$first" ]] && first="-"
    # Collapse wide lines for the table
    first="${first//$'\t'/ }"
    if (( ${#first} > 80 )); then
      first="${first:0:77}..."
    fi

    if eval_is_correct "$raw"; then
      correct=yes
    else
      correct=no
    fi

    jq -cn --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lane "$lane" \
      --argjson seconds "$elapsed" --argjson correct "$([[ "$correct" == yes ]] && printf true || printf false)" \
      '{timestamp:$timestamp,lane:$lane,seconds:$seconds,correct:$correct}' >> "$eval_history"
    printf '%-8s %-10s %-8s %s\n' "$lane" "$elapsed" "$correct" "$first"
  done
}

# --- main -------------------------------------------------------------------

(( $# )) || { usage; exit 1; }

case "$1" in
  doctor) shift; cmd_doctor "$@" ;;
  eval)   shift; cmd_eval "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown subcommand: $1 (try doctor or eval)" ;;
esac
