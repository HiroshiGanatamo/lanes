#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/reflect-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'REFLECT TEST FAILED: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" text="$2"
  grep -qF -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
  local file="$1" text="$2"
  if grep -qF -- "$text" "$file"; then
    fail "$file unexpectedly contains: $text"
  fi
}

REPO="$TMP/repo"
HARNESS="$TMP/orchestrator"
mkdir -p "$REPO/.orch/specs" "$HARNESS"
ln -s "$ROOT/reflect.sh" "$HARNESS/reflect.sh"

cat > "$REPO/.orch/report.json" <<'JSON'
{
  "units": [
    {
      "id": "passing-unit",
      "slug": "passing-spec",
      "status": "pass",
      "lane": "codex",
      "effort": "low",
      "gate": "true",
      "gate_tail": "PASSING_TAIL_MUST_NOT_APPEAR"
    },
    {
      "id": "gate-failure",
      "slug": "gate-fallback",
      "spec": "gate-explicit.md",
      "status": "gate_failed",
      "lane": "grok",
      "effort": "high",
      "gate": "./tests/gate.sh",
      "gate_tail": "gate output details"
    },
    {
      "id": "worker-failure",
      "slug": "worker-fallback",
      "status": "worker_failed",
      "lane": "kimi",
      "effort": "medium",
      "gate": "bash -n worker.sh",
      "gate_tail": "worker output details"
    }
  ]
}
JSON

cat > "$REPO/.orch/specs/gate-explicit.md" <<'EOF'
Gate failure spec text.
EOF
cat > "$REPO/.orch/specs/worker-fallback.md" <<'EOF'
Worker failure fallback spec text.
EOF
cat > "$REPO/.orch/specs/passing-spec.md" <<'EOF'
Passing spec text must not be analyzed.
EOF

CAPTURE_PROMPT="$TMP/prompt.txt"
export CAPTURE_PROMPT
STUB="$TMP/lane-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "$CAPTURE_PROMPT"
printf '%s\n' \
  '{"lesson":"State the required fixture shape in the spec.","cause":"spec","unit":"gate-failure"}' \
  'this line is malformed' \
  '{"lesson":"Require a preflight check for worker dependencies.","cause":"environment","unit":"worker-failure"}'
EOF
chmod +x "$STUB"
export REFLECT_LANE_CMD="$STUB"

REFLECT_LANE_CMD="$TMP/must-not-run" "$HARNESS/reflect.sh" --repo "$REPO" --dry-run > "$TMP/dry-analysis.out"
[[ ! -e "$REPO/.orch/lessons-staged.md" ]] || fail "analysis dry run created a staging file"
assert_contains "$TMP/dry-analysis.out" "gate-failure"
assert_contains "$TMP/dry-analysis.out" "worker-failure"
assert_not_contains "$TMP/dry-analysis.out" "passing-unit"

"$HARNESS/reflect.sh" --repo "$REPO"

STAGED="$REPO/.orch/lessons-staged.md"
[[ -f "$STAGED" ]] || fail "staging file was not created"
lesson_count=$(grep -c '^- ' "$STAGED" || true)
[[ "$lesson_count" == "2" ]] || fail "expected 2 staged lessons, got $lesson_count"
assert_contains "$STAGED" "State the required fixture shape in the spec."
assert_contains "$STAGED" "Require a preflight check for worker dependencies."
assert_not_contains "$STAGED" "malformed"

assert_contains "$CAPTURE_PROMPT" "gate-failure"
assert_contains "$CAPTURE_PROMPT" "worker-failure"
assert_not_contains "$CAPTURE_PROMPT" "passing-unit"
assert_not_contains "$CAPTURE_PROMPT" "PASSING_TAIL_MUST_NOT_APPEAR"
assert_contains "$CAPTURE_PROMPT" "Gate failure spec text."
assert_contains "$CAPTURE_PROMPT" "Worker failure fallback spec text."

cp "$STAGED" "$TMP/staged-before-dry-promote.md"
"$HARNESS/reflect.sh" --repo "$REPO" --promote --dry-run > "$TMP/dry-promote.out"
cmp -s "$STAGED" "$TMP/staged-before-dry-promote.md" || fail "promotion dry run changed staging"
[[ ! -e "$HARNESS/LESSONS.md" ]] || fail "promotion dry run created LESSONS.md"
assert_contains "$TMP/dry-promote.out" "State the required fixture shape in the spec."

"$HARNESS/reflect.sh" --repo "$REPO" --promote
LESSONS="$HARNESS/LESSONS.md"
today=$(date -u +%Y-%m-%d)
[[ -f "$LESSONS" ]] || fail "LESSONS.md was not created"
assert_contains "$LESSONS" "## $today"
assert_contains "$LESSONS" "State the required fixture shape in the spec."
assert_contains "$LESSONS" "Require a preflight check for worker dependencies."
[[ ! -s "$STAGED" ]] || fail "staging file was not truncated after promotion"

for i in $(seq 1 230); do
  printf -- '- bulk lesson %03d (cause: gate; unit: bulk)\n' "$i" >> "$STAGED"
done
"$HARNESS/reflect.sh" --repo "$REPO" --promote >"$TMP/cap.out" 2>"$TMP/cap.err"
line_count=$(wc -l < "$LESSONS" | tr -d ' ')
[[ "$line_count" == "200" ]] || fail "expected 200 capped lines, got $line_count"
assert_contains "$LESSONS" "bulk lesson 230"
assert_not_contains "$LESSONS" "bulk lesson 001"
assert_contains "$TMP/cap.err" "older lessons were dropped"
[[ ! -s "$STAGED" ]] || fail "staging file was not truncated after capped promotion"

cat > "$REPO/.orch/no-failures.json" <<'JSON'
{"units":[{"id":"only-pass","status":"pass"}]}
JSON
REFLECT_LANE_CMD="$TMP/must-not-run" "$HARNESS/reflect.sh" --repo "$REPO" \
  --report "$REPO/.orch/no-failures.json" > "$TMP/no-failures.out" 2> "$TMP/no-failures.err"
assert_contains "$TMP/no-failures.err" "no failures to learn from"

ln -s "$ROOT/lanes.sh" "$HARNESS/lanes.sh"
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/lane-stub" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *LANE_OK*) printf 'LANE_OK\n' ;;
  *strawberry*) printf '{"answer":3}\n' ;;
esac
EOF
chmod +x "$FAKE_BIN/lane-stub"
ln -s "$FAKE_BIN/lane-stub" "$FAKE_BIN/codex"
ln -s "$FAKE_BIN/lane-stub" "$FAKE_BIN/kimi"
ln -s "$FAKE_BIN/lane-stub" "$FAKE_BIN/grok"
env PATH="$FAKE_BIN:$PATH" "$HARNESS/lanes.sh" eval > "$TMP/eval.out" 2> "$TMP/eval.err"

HISTORY="$HARNESS/.orch/eval-history.jsonl"
[[ -f "$HISTORY" ]] || fail "lane eval history was not created"
history_count=$(wc -l < "$HISTORY" | tr -d ' ')
[[ "$history_count" == "3" ]] || fail "expected 3 lane history rows, got $history_count"
jq -e -s '
  length == 3
  and (map(.lane) | sort == ["codex", "grok", "kimi"])
  and all(.[];
    (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.seconds | type == "number")
    and (.correct == true)
  )
' "$HISTORY" >/dev/null || fail "lane eval history rows have the wrong shape"

printf 'REFLECT TESTS PASSED\n'
