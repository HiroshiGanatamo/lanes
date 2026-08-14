#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/assumptions-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'ASSUMPTIONS TEST FAILED: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local got="$1" want="$2" message="$3"
  [[ "$got" == "$want" ]] || fail "$message (got: $got)"
}

assert_jq() {
  local file="$1" filter="$2" message="$3"
  jq -e "$filter" "$file" >/dev/null || fail "$message"
}

[[ -x "$ROOT/run.sh" ]] || fail "run.sh is missing or not executable"

# --- assumptions_from_answer parser, via the --parse-assumptions test hook -----------------

cat > "$TMP/valid.txt" <<'EOF'
Changed foo.ts to use bar().

ASSUMPTIONS_JSON:
[{"what": "which field", "reading_chosen": "field A", "alternative_rejected": "field B", "blast_radius": "shared"}]
EOF
got=$("$ROOT/run.sh" --parse-assumptions "$TMP/valid.txt")
assert_eq "$got" \
  '[{"what":"which field","reading_chosen":"field A","alternative_rejected":"field B","blast_radius":"shared"}]' \
  "valid single assumption did not parse to the exact expected JSON"

printf 'No ambiguity, nothing to report.\n' > "$TMP/no-marker.txt"
assert_eq "$("$ROOT/run.sh" --parse-assumptions "$TMP/no-marker.txt")" '[]' \
  "missing ASSUMPTIONS_JSON marker must yield an empty array, not an error"

cat > "$TMP/malformed.txt" <<'EOF'
Did the thing.

ASSUMPTIONS_JSON:
[{"what": "x", "reading_chosen": this is not json}]
EOF
assert_eq "$("$ROOT/run.sh" --parse-assumptions "$TMP/malformed.txt")" '[]' \
  "malformed JSON after the marker must degrade to an empty array, not crash the driver"

cat > "$TMP/bad-blast-radius.txt" <<'EOF'
Did the thing.

ASSUMPTIONS_JSON:
[{"what": "x", "reading_chosen": "a", "alternative_rejected": "b", "blast_radius": "medium"}]
EOF
assert_eq "$("$ROOT/run.sh" --parse-assumptions "$TMP/bad-blast-radius.txt")" '[]' \
  "a blast_radius outside local|shared must be rejected, not silently accepted"

cat > "$TMP/two-mixed.txt" <<'EOF'
Did two things.

ASSUMPTIONS_JSON:
[{"what": "x", "reading_chosen": "a", "alternative_rejected": "b", "blast_radius": "local"}, {"what": "y", "reading_chosen": "c", "alternative_rejected": "d", "blast_radius": "shared"}]
EOF
got=$("$ROOT/run.sh" --parse-assumptions "$TMP/two-mixed.txt")
assert_jq <(printf '%s' "$got") 'length == 2 and .[0].blast_radius == "local" and .[1].blast_radius == "shared"' \
  "two mixed-blast-radius assumptions were not both preserved in order"

# --- resolve_assumptions escalation, via the --resolve-assumptions test hook ---------------
# A fake `codex` stands in for the lane: it answers the judge dispatch with a score controlled by
# a marker string in the assumption's "what" field (HIGH_SCORE_TEST => 9, otherwise => 3), and on
# a resume call it drops a "fixed" file in the worktree so a gate can observe the auto-fix happened.

FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
is_resume=0; outfile=""; wt=""
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    resume) is_resume=1 ;;
    -C) wt="${args[$((i+1))]}" ;;
    -o) outfile="${args[$((i+1))]}" ;;
  esac
done

if (( is_resume )); then
  [[ -n "$wt" ]] && : > "$wt/fixed"
  printf 'session id: resumed-session-id\n'
  exit 0
fi

input="$(cat)"
score=3
grep -q "HIGH_SCORE_TEST" <<<"$input" && score=9
result="{\"score\": $score, \"verdict\": \"stub verdict\", \"issues\": [\"stub issue\"]}"
if [[ -n "$outfile" ]]; then printf '%s\n' "$result" > "$outfile"; else printf '%s\n' "$result"; fi
printf 'session id: judge-session-id\n'
STUB
chmod +x "$FAKE_BIN/codex"

ORCH="$TMP/orch"
mkdir -p "$ORCH/results" "$ORCH/specs" "$ORCH/logs" "$ORCH/prompts"
printf 'Spec text for the escalation test.\n' > "$ORCH/specs/u.md"

make_wt() {
  local wt="$1"
  mkdir -p "$wt"
}

result_json() {
  local id="$1" status="$2" gate="$3" what="$4" blast="$5" wt="$6"
  jq -n --arg id "$id" --arg status "$status" --arg gate "$gate" \
        --arg what "$what" --arg blast "$blast" \
        --arg wt "$wt" --arg kind "impl" \
    '{id:$id,slug:$id,kind:$kind,lane:"codex",worktree:$wt,session:("session-"+$id),
      gate:$gate,status:$status,
      assumptions:[{what:$what,reading_chosen:"chosen",alternative_rejected:"rejected",blast_radius:$blast}],
      assumption_judgement:null}'
}

# u-high: shared assumption, judge scores it 9 — must stay pass, gate must NOT be re-run
# (gate is "false" on purpose; if the code mistakenly ran it, this unit would wrongly flip).
make_wt "$TMP/wt-u-high"
result_json u-high pass false "HIGH_SCORE_TEST reading of the API shape" shared "$TMP/wt-u-high" > "$ORCH/results/u-high.json"

# u-fixed: shared assumption, judge scores it low, resume drops the marker file the gate checks.
make_wt "$TMP/wt-u-fixed"
result_json u-fixed pass "test -f fixed" "ambiguous reading of the schema" shared "$TMP/wt-u-fixed" > "$ORCH/results/u-fixed.json"

# u-unresolved: shared assumption, judge scores it low, gate can never pass.
make_wt "$TMP/wt-u-unresolved"
result_json u-unresolved pass false "ambiguous reading of the persisted format" shared "$TMP/wt-u-unresolved" > "$ORCH/results/u-unresolved.json"

# u-local: local-only assumption — must be skipped entirely, no judge dispatch.
make_wt "$TMP/wt-u-local"
result_json u-local pass false "cosmetic naming choice" local "$TMP/wt-u-local" > "$ORCH/results/u-local.json"

# u-failed: shared assumption but the unit's own gate never passed — must be skipped.
make_wt "$TMP/wt-u-failed"
result_json u-failed gate_failed false "HIGH_SCORE_TEST but the unit already failed" shared "$TMP/wt-u-failed" > "$ORCH/results/u-failed.json"

PLAN="$TMP/plan.json"
jq -n '[{id:"u-high",spec:"specs/u.md"},{id:"u-fixed",spec:"specs/u.md"},
        {id:"u-unresolved",spec:"specs/u.md"},{id:"u-local",spec:"specs/u.md"},
        {id:"u-failed",spec:"specs/u.md"}]' > "$PLAN"

env PATH="$FAKE_BIN:$PATH" "$ROOT/run.sh" --resolve-assumptions "$ORCH" "$PLAN" 7 \
  > "$TMP/resolve.out" 2> "$TMP/resolve.err"

assert_jq "$ORCH/results/u-high.json" '.status == "pass" and .assumption_judgement.score == 9' \
  "high-scored assumption must keep status pass with the judgement attached"

assert_jq "$ORCH/results/u-fixed.json" '.status == "pass" and .assumption_judgement.score == 3' \
  "low-scored assumption fixed by auto-resume must keep status pass"
[[ -f "$TMP/wt-u-fixed/fixed" ]] || fail "u-fixed: auto-resume was never actually invoked"

assert_jq "$ORCH/results/u-unresolved.json" \
  '.status == "assumption_unresolved" and .assumption_judgement.score == 3' \
  "low-scored assumption that stays broken after auto-resume must be marked assumption_unresolved"
[[ -f "$TMP/wt-u-unresolved/fixed" ]] || fail "u-unresolved: auto-resume was never actually invoked"

assert_jq "$ORCH/results/u-local.json" '.status == "pass" and .assumption_judgement == null' \
  "a local-only assumption must never trigger a judge dispatch"
[[ -f "$TMP/wt-u-local/fixed" ]] && fail "u-local: resume ran on a unit with no shared assumption"

assert_jq "$ORCH/results/u-failed.json" '.status == "gate_failed" and .assumption_judgement == null' \
  "a unit whose own gate never passed must be left alone, not escalated"
[[ -f "$TMP/wt-u-failed/fixed" ]] && fail "u-failed: resume ran on a unit whose gate already failed"

assert_contains() { grep -qF -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_contains "$TMP/resolve.err" "u-high"
assert_contains "$TMP/resolve.err" "u-fixed"
assert_contains "$TMP/resolve.err" "u-unresolved"

# No mechanism here waits on a person: confirm the escalation path never shells out to anything
# that looks like a human-approval prompt or blocks on stdin.
assert_eq "$(grep -ci 'waiting for approval\|press y\|confirm?' "$TMP/resolve.err" || true)" "0" \
  "the auto-escalation log must never mention a human approval step"

printf 'ASSUMPTIONS TESTS PASSED\n'
