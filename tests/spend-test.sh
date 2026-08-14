#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spend-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'SPEND TEST FAILED: %s\n' "$*" >&2
  exit 1
}

assert_jq() {
  local file="$1" filter="$2" message="$3"
  jq -e "$filter" "$file" >/dev/null || fail "$message"
}

utc_line() {
  local timestamp="$1" lane="$2" unit="$3" usd="$4" tokens="$5"
  jq -cn --arg timestamp "$timestamp" --arg lane "$lane" --arg unit "$unit" \
    --argjson usd "$usd" --argjson tokens "$tokens" \
    '{timestamp:$timestamp,lane:$lane,unit:$unit,usd:$usd,tokens:$tokens}'
}

[[ -x "$ROOT/spend.sh" ]] || fail "spend.sh is missing or not executable"

# Missing budget.json still enforces the documented defaults.
DEFAULT_REPO="$TMP/default-repo"
mkdir -p "$DEFAULT_REPO/.orch"
if "$ROOT/spend.sh" check --repo "$DEFAULT_REPO" --estimate 5 > "$TMP/default-check.json"; then
  fail "missing budget.json allowed an estimate at the default daily cap"
fi
assert_jq "$TMP/default-check.json" \
  '.decision == "deny" and .daily_cap_usd == 5 and .per_run_cap_usd == 1' \
  "missing budget.json did not use the documented defaults"

# Daily spend below the cap passes; spend at the cap fails.
CAP_REPO="$TMP/cap-repo"
mkdir -p "$CAP_REPO/.orch"
printf '%s\n' '{"daily_usd":1,"per_run_usd":1,"currency":"USD"}' > "$CAP_REPO/.orch/budget.json"
today=$(date -u +%Y-%m-%d)
utc_line "${today}T00:00:00Z" codex below-cap 0.99 10 > "$CAP_REPO/.orch/spend-ledger.jsonl"
"$ROOT/spend.sh" check --repo "$CAP_REPO" > "$TMP/below-check.json" \
  || fail "check rejected spend below the daily cap"
assert_jq "$TMP/below-check.json" \
  '.decision == "allow" and .daily_spend_usd == 0.99 and .daily_remaining_usd == 0.01' \
  "below-cap check reported the wrong decision or headroom"
utc_line "${today}T00:00:01Z" kimi at-cap 0.01 1 >> "$CAP_REPO/.orch/spend-ledger.jsonl"
if "$ROOT/spend.sh" check --repo "$CAP_REPO" > "$TMP/at-check.json"; then
  fail "check allowed spend at the daily cap"
fi
assert_jq "$TMP/at-check.json" \
  '.decision == "deny" and .daily_spend_usd == 1 and .daily_remaining_usd == 0' \
  "at-cap check reported the wrong decision or headroom"

# An estimate that crosses the daily cap is rejected while current spend remains below it.
ESTIMATE_REPO="$TMP/estimate-repo"
mkdir -p "$ESTIMATE_REPO/.orch"
printf '%s\n' '{"daily_usd":1,"per_run_usd":0.5,"currency":"USD"}' > "$ESTIMATE_REPO/.orch/budget.json"
utc_line "${today}T00:00:00Z" grok current 0.8 10 > "$ESTIMATE_REPO/.orch/spend-ledger.jsonl"
if "$ROOT/spend.sh" check --repo "$ESTIMATE_REPO" --estimate 0.3 > "$TMP/estimate-check.json"; then
  fail "check allowed an estimate that crosses the daily cap"
fi
assert_jq "$TMP/estimate-check.json" \
  '.decision == "deny" and .daily_spend_usd == 0.8 and .estimate_usd == 0.3 and .projected_daily_usd == 1.1' \
  "estimated check reported the wrong projected spend"
if "$ROOT/spend.sh" check --repo "$ESTIMATE_REPO" --estimate 0.5 > "$TMP/per-run-check.json"; then
  fail "check allowed an estimate at the per-run cap"
fi
assert_jq "$TMP/per-run-check.json" \
  '.decision == "deny" and (.reasons | index("per_run_cap")) != null and .per_run_remaining_usd == 0' \
  "per-run cap check reported the wrong decision or headroom"

# Both caps fail closed when JSON numeric overflow produces a non-finite value.
NONFINITE_REPO="$TMP/nonfinite-repo"
mkdir -p "$NONFINITE_REPO/.orch"
printf '%s\n' '{"daily_usd":1e999,"per_run_usd":1,"currency":"USD"}' > "$NONFINITE_REPO/.orch/budget.json"
if "$ROOT/spend.sh" check --repo "$NONFINITE_REPO" > "$TMP/nonfinite.out" 2> "$TMP/nonfinite.err"; then
  fail "check accepted a non-finite daily cap"
fi
grep -qF 'invalid budget file' "$TMP/nonfinite.err" \
  || fail "non-finite budget did not fail closed with a clear error"

# Exact cap comparisons do not round away sub-microdollar spend.
PRECISION_REPO="$TMP/precision-repo"
mkdir -p "$PRECISION_REPO/.orch"
printf '%s\n' '{"daily_usd":1.0000004,"per_run_usd":2,"currency":"USD"}' > "$PRECISION_REPO/.orch/budget.json"
utc_line "${today}T00:00:00Z" codex precise-cap 1.0000004 1 > "$PRECISION_REPO/.orch/spend-ledger.jsonl"
if "$ROOT/spend.sh" check --repo "$PRECISION_REPO" > "$TMP/precision-check.json"; then
  fail "check rounded exact spend below a high-precision daily cap"
fi

# Impossible calendar timestamps make the ledger invalid instead of disappearing from totals.
BAD_DATE_REPO="$TMP/bad-date-repo"
mkdir -p "$BAD_DATE_REPO/.orch"
utc_line '2026-99-99T00:00:00Z' codex impossible-date 5 1 > "$BAD_DATE_REPO/.orch/spend-ledger.jsonl"
if "$ROOT/spend.sh" check --repo "$BAD_DATE_REPO" > "$TMP/bad-date.out" 2> "$TMP/bad-date.err"; then
  fail "check accepted an impossible ledger timestamp"
fi
grep -qF 'invalid ledger' "$TMP/bad-date.err" \
  || fail "impossible timestamp did not fail closed with a clear error"

# record writes valid current UTC JSON; report totals two days and two lanes.
REPORT_REPO="$TMP/report-repo"
mkdir -p "$REPORT_REPO/.orch"
printf '%s\n' '{"daily_usd":5,"per_run_usd":1,"currency":"USD"}' > "$REPORT_REPO/.orch/budget.json"
"$ROOT/spend.sh" record --repo "$REPORT_REPO" --lane codex --unit today-unit --usd 0.25 --tokens 123
yesterday=$(jq -nr --arg today "$today" '$today + "T00:00:00Z" | fromdateiso8601 - 86400 | strftime("%Y-%m-%d")')
utc_line "${yesterday}T12:00:00Z" kimi yesterday-unit 0.75 456 >> "$REPORT_REPO/.orch/spend-ledger.jsonl"
jq -e -s '
  length == 2
  and all(.[].timestamp; test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and any(.[]; .lane == "codex" and .unit == "today-unit" and .usd == 0.25 and .tokens == 123)
' "$REPORT_REPO/.orch/spend-ledger.jsonl" >/dev/null || fail "record did not append valid JSON with a UTC timestamp"
"$ROOT/spend.sh" report --repo "$REPORT_REPO" --days 2 > "$TMP/report.json"
jq -e --arg today "$today" --arg yesterday "$yesterday" '
  .days == 2
  and (.per_day | map(select(.day == $today and .usd == 0.25)) | length == 1)
  and (.per_day | map(select(.day == $yesterday and .usd == 0.75)) | length == 1)
  and (.per_lane | map(select(.lane == "codex" and .usd == 0.25)) | length == 1)
  and (.per_lane | map(select(.lane == "kimi" and .usd == 0.75)) | length == 1)
  and .today.daily_remaining_usd == 4.75
' "$TMP/report.json" >/dev/null || fail "report totals across two days and two lanes are incorrect"

# Concurrent writers serialize all ten complete JSON lines.
CONCURRENT_REPO="$TMP/concurrent-repo"
mkdir -p "$CONCURRENT_REPO/.orch"
pids=()
for i in $(seq 1 10); do
  "$ROOT/spend.sh" record --repo "$CONCURRENT_REPO" --lane codex --unit "unit-$i" --usd 0.01 --tokens "$i" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "a concurrent record call failed"
done
line_count=$(wc -l < "$CONCURRENT_REPO/.orch/spend-ledger.jsonl" | tr -d ' ')
[[ "$line_count" == "10" ]] || fail "expected 10 concurrent ledger lines, got $line_count"
jq -e -s 'length == 10 and all(.[]; type == "object")' \
  "$CONCURRENT_REPO/.orch/spend-ledger.jsonl" >/dev/null \
  || fail "concurrent ledger contains malformed JSON"

# HALT next to run.sh produces a halted result without invoking a lane.
HALT_REPO="$TMP/halt-repo"
HARNESS="$TMP/orchestrator"
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$HALT_REPO/.orch/specs" "$HALT_REPO/.git/info" "$HARNESS" "$FAKE_BIN"
ln -s "$ROOT/run.sh" "$HARNESS/run.sh"
ln -s "$ROOT/spend.sh" "$HARNESS/spend.sh"
: > "$HARNESS/HALT"
printf '%s\n' 'This unit must never run.' > "$HALT_REPO/.orch/specs/explode.md"
cat > "$HALT_REPO/.orch/units.json" <<'JSON'
{"jobs":1,"units":[{"id":"explode","slug":"explode","kind":"recon","lane":"codex","spec":"specs/explode.md"}]}
JSON
MARKER="$TMP/lane-ran"
export MARKER
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'lane ran\n' > "$MARKER"
exit 99
EOF
chmod +x "$FAKE_BIN/codex"
env PATH="$FAKE_BIN:$PATH" "$HARNESS/run.sh" --repo "$HALT_REPO" --no-probe \
  "$HALT_REPO/.orch/units.json" > "$TMP/halt.out" 2> "$TMP/halt.err" \
  || fail "run.sh failed instead of reporting a halted unit"
[[ ! -e "$MARKER" ]] || fail "HALT allowed the lane command to run"
assert_jq "$HALT_REPO/.orch/report.json" \
  '.summary.total == 1 and .summary.halted == 1 and .units[0].status == "halted"' \
  "HALT did not produce a halted unit and summary count"
grep -qF 'HALT' "$TMP/halt.err" || fail "HALT reason was not logged"

# The pre-dispatch budget hook refuses the plan before a lane can run.
BUDGET_REPO="$TMP/budget-hook-repo"
BUDGET_HARNESS="$TMP/budget-orchestrator"
mkdir -p "$BUDGET_REPO/.orch/specs" "$BUDGET_REPO/.git/info" "$BUDGET_HARNESS"
ln -s "$ROOT/run.sh" "$BUDGET_HARNESS/run.sh"
ln -s "$ROOT/spend.sh" "$BUDGET_HARNESS/spend.sh"
printf '%s\n' 'This unit must never run.' > "$BUDGET_REPO/.orch/specs/explode.md"
printf '%s\n' '{"jobs":1,"units":[{"id":"explode","slug":"explode","kind":"recon","lane":"codex","spec":"specs/explode.md"}]}' \
  > "$BUDGET_REPO/.orch/units.json"
printf '%s\n' '{"daily_usd":1,"per_run_usd":1,"currency":"USD"}' > "$BUDGET_REPO/.orch/budget.json"
utc_line "${today}T00:00:00Z" codex exhausted 1 1 > "$BUDGET_REPO/.orch/spend-ledger.jsonl"
if env PATH="$FAKE_BIN:$PATH" "$BUDGET_HARNESS/run.sh" --repo "$BUDGET_REPO" --no-probe \
  "$BUDGET_REPO/.orch/units.json" > "$TMP/budget-hook.out" 2> "$TMP/budget-hook.err"; then
  fail "run.sh dispatched despite an exhausted budget"
fi
[[ ! -e "$MARKER" ]] || fail "budget denial allowed the lane command to run"
grep -qF 'refusing to dispatch' "$TMP/budget-hook.err" \
  || fail "run.sh did not explain its budget refusal"

printf 'SPEND TESTS PASSED\n'
