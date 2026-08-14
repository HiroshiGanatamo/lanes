#!/usr/bin/env bash
# Budget checks, conservative spend recording, and UTC spend summaries.
set -euo pipefail

die() { printf 'spend: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[2m[spend]\033[0m %s\n' "$*" >&2; }

usage() {
  printf '%s\n' \
    'usage: spend.sh check --repo DIR [--estimate USD]' \
    '       spend.sh record --repo DIR --lane L --unit ID --usd N [--tokens N]' \
    '       spend.sh report --repo DIR [--days N]'
}

number() {
  local name="$1" value="$2"
  jq -en --arg value "$value" '$value | tonumber | select(isfinite and . >= 0)' 2>/dev/null \
    || die "$name requires a non-negative number"
}

positive_integer() {
  local name="$1" value="$2"
  jq -en --arg value "$value" \
    '$value | tonumber | select(isfinite and . > 0 and floor == .)' 2>/dev/null \
    || die "$name requires a positive integer"
}

load_budget() {
  local repo="$1" budget="$repo/.orch/budget.json"
  if [[ ! -f "$budget" ]]; then
    printf '%s\n' '{"daily_usd":5,"per_run_usd":1,"currency":"USD"}'
    return
  fi

  jq -ce '
    select(type == "object")
    | select((.daily_usd | type) == "number" and (.daily_usd | isfinite) and .daily_usd > 0)
    | select((.per_run_usd | type) == "number" and (.per_run_usd | isfinite) and .per_run_usd > 0)
    | select(.currency == "USD")
    | {daily_usd, per_run_usd, currency}
  ' "$budget" 2>/dev/null || die "invalid budget file: $budget"
}

load_ledger() {
  local repo="$1" ledger="$repo/.orch/spend-ledger.jsonl"
  if [[ ! -f "$ledger" ]]; then
    printf '%s\n' '[]'
    return
  fi

  jq -sce '
    def valid_utc_timestamp:
      . as $timestamp
      | type == "string"
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        and ((try ($timestamp | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch "") == $timestamp);
    select(all(.[];
      type == "object"
      and (.timestamp | valid_utc_timestamp)
      and (.lane | type == "string" and length > 0)
      and (.unit | type == "string" and length > 0)
      and (.usd | type == "number" and isfinite and . >= 0)
      and (.tokens | type == "number" and isfinite and . >= 0)
    ))
  ' "$ledger" 2>/dev/null || die "invalid ledger: $ledger"
}

check_spend() {
  local repo="" estimate=0 budget ledger today output decision

  while (( $# )); do
    case "$1" in
      --repo)     [[ $# -ge 2 ]] || die "--repo requires a directory"
                  repo="$2"; shift 2 ;;
      --estimate) [[ $# -ge 2 ]] || die "--estimate requires a number"
                  estimate=$(number --estimate "$2"); shift 2 ;;
      *) die "unknown check argument: $1" ;;
    esac
  done

  [[ -n "$repo" ]] || die "check requires --repo DIR"
  [[ -d "$repo" ]] || die "repo is not a directory: $repo"
  repo="$(cd "$repo" && pwd)"
  budget=$(load_budget "$repo")
  ledger=$(load_ledger "$repo")
  today=$(date -u +%Y-%m-%d)

  output=$(jq -cn \
    --arg today "$today" --argjson budget "$budget" --argjson ledger "$ledger" \
    --argjson estimate "$estimate" '
      def money: . * 1000000 | round / 1000000;
      ([ $ledger[] | select(.timestamp[0:10] == $today) | .usd ] | add // 0) as $spent_exact
      | ($spent_exact + $estimate) as $projected_exact
      | ($spent_exact | money) as $spent
      | ($projected_exact | money) as $projected
      | (($budget.daily_usd - $projected_exact) | if . < 0 then 0 else . end | money) as $daily_remaining
      | (($budget.per_run_usd - $estimate) | if . < 0 then 0 else . end | money) as $run_remaining
      | ([
          if $projected_exact >= $budget.daily_usd then "daily_cap" else empty end,
          if $estimate >= $budget.per_run_usd then "per_run_cap" else empty end
        ]) as $reasons
      | {
          decision: (if ($reasons | length) == 0 then "allow" else "deny" end),
          utc_day: $today,
          currency: $budget.currency,
          daily_cap_usd: $budget.daily_usd,
          per_run_cap_usd: $budget.per_run_usd,
          daily_spend_usd: $spent,
          estimate_usd: $estimate,
          projected_daily_usd: $projected,
          daily_remaining_usd: $daily_remaining,
          per_run_remaining_usd: $run_remaining,
          reasons: $reasons
        }
    ')
  printf '%s\n' "$output"
  decision=$(jq -r '.decision' <<<"$output")
  [[ "$decision" == "allow" ]]
}

record_spend() {
  local repo="" lane="" unit="" usd="" tokens=0
  local ledger lock timestamp line attempt=0

  while (( $# )); do
    case "$1" in
      --repo)   [[ $# -ge 2 ]] || die "--repo requires a directory"
                repo="$2"; shift 2 ;;
      --lane)   [[ $# -ge 2 ]] || die "--lane requires a value"
                lane="$2"; shift 2 ;;
      --unit)   [[ $# -ge 2 ]] || die "--unit requires a value"
                unit="$2"; shift 2 ;;
      --usd)    [[ $# -ge 2 ]] || die "--usd requires a number"
                usd=$(number --usd "$2"); shift 2 ;;
      --tokens) [[ $# -ge 2 ]] || die "--tokens requires a number"
                tokens=$(number --tokens "$2"); shift 2 ;;
      *) die "unknown record argument: $1" ;;
    esac
  done

  [[ -n "$repo" ]] || die "record requires --repo DIR"
  [[ -d "$repo" ]] || die "repo is not a directory: $repo"
  [[ -n "$lane" ]] || die "record requires --lane L"
  [[ -n "$unit" ]] || die "record requires --unit ID"
  [[ -n "$usd" ]] || die "record requires --usd N"
  repo="$(cd "$repo" && pwd)"
  mkdir -p "$repo/.orch"
  ledger="$repo/.orch/spend-ledger.jsonl"
  lock="$repo/.orch/spend-ledger.lock"
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  line=$(jq -cn --arg timestamp "$timestamp" --arg lane "$lane" --arg unit "$unit" \
    --argjson usd "$usd" --argjson tokens "$tokens" \
    '{timestamp:$timestamp,lane:$lane,unit:$unit,usd:$usd,tokens:$tokens}')

  until mkdir "$lock" 2>/dev/null; do
    (( attempt++ )) || true
    (( attempt < 200 )) || die "timed out waiting for ledger lock: $lock"
    sleep 0.01
  done
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  printf '%s\n' "$line" >> "$ledger"
  rmdir "$lock"
  trap - EXIT
}

report_spend() {
  local repo="" days=7 budget ledger today start

  while (( $# )); do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die "--repo requires a directory"
              repo="$2"; shift 2 ;;
      --days) [[ $# -ge 2 ]] || die "--days requires a positive integer"
              days=$(positive_integer --days "$2"); shift 2 ;;
      *) die "unknown report argument: $1" ;;
    esac
  done

  [[ -n "$repo" ]] || die "report requires --repo DIR"
  [[ -d "$repo" ]] || die "repo is not a directory: $repo"
  repo="$(cd "$repo" && pwd)"
  budget=$(load_budget "$repo")
  ledger=$(load_ledger "$repo")
  today=$(date -u +%Y-%m-%d)
  start=$(jq -nr --arg today "$today" --argjson days "$days" \
    '$today + "T00:00:00Z" | fromdateiso8601 - (($days - 1) * 86400) | strftime("%Y-%m-%d")')

  jq -cn \
    --arg today "$today" --arg start "$start" --argjson days "$days" \
    --argjson budget "$budget" --argjson ledger "$ledger" '
      def money: . * 1000000 | round / 1000000;
      [ $ledger[] | select(.timestamp[0:10] >= $start and .timestamp[0:10] <= $today) ] as $window
      | ([ $ledger[] | select(.timestamp[0:10] == $today) | .usd ] | add // 0 | money) as $today_spend
      | {
          days: $days,
          start_utc_day: $start,
          end_utc_day: $today,
          currency: $budget.currency,
          per_day: ([
            $window | group_by(.timestamp[0:10])[]
            | {day: .[0].timestamp[0:10], usd: (map(.usd) | add | money), tokens: (map(.tokens) | add)}
          ] | sort_by(.day)),
          per_lane: ([
            $window | group_by(.lane)[]
            | {lane: .[0].lane, usd: (map(.usd) | add | money), tokens: (map(.tokens) | add)}
          ] | sort_by(.lane)),
          today: {
            utc_day: $today,
            daily_cap_usd: $budget.daily_usd,
            per_run_cap_usd: $budget.per_run_usd,
            daily_spend_usd: $today_spend,
            daily_remaining_usd: (($budget.daily_usd - $today_spend) | if . < 0 then 0 else . end | money),
            per_run_remaining_usd: $budget.per_run_usd
          }
        }
    '
}

command -v jq >/dev/null || die "jq required"
(( $# )) || { usage; exit 1; }
COMMAND="$1"; shift

case "$COMMAND" in
  check)  check_spend "$@" ;;
  record) record_spend "$@" ;;
  report) report_spend "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command: $COMMAND" ;;
esac
