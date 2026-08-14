#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/deps-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'DEPS TEST FAILED: %s\n' "$*" >&2
  exit 1
}

assert_jq() {
  local file="$1" filter="$2" message="$3"
  jq -e "$filter" "$file" >/dev/null || fail "$message"
}

write_fake_codex() {
  local dest="$1"
  cat > "$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
wt=""
outfile=""
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    -C) wt="${args[$((i+1))]}" ;;
    -o) outfile="${args[$((i+1))]}" ;;
  esac
done
if [[ -n "${FAKE_DISPATCH_LOG:-}" && -n "$wt" ]]; then
  printf '%s\n' "$(basename "$wt")" >> "$FAKE_DISPATCH_LOG"
fi
if [[ -n "$outfile" ]]; then
  printf 'fake worker done\n' > "$outfile"
fi
printf 'session id: 0123456789abcdef0123456789abcdef\n'
exit 0
EOF
  chmod +x "$dest"
}

setup_harness() {
  local harness="$1"
  mkdir -p "$harness"
  ln -s "$ROOT/run.sh" "$harness/run.sh"
  ln -s "$ROOT/spend.sh" "$harness/spend.sh"
}

init_git_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null
  git -C "$repo" config user.email "deps-test@example.com"
  git -C "$repo" config user.name "deps-test"
  printf 'init\n' > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" -c core.hooksPath=/dev/null commit --no-verify -m init >/dev/null
}

write_spec() {
  local repo="$1" name="$2"
  mkdir -p "$repo/.orch/specs"
  printf 'Do the thing for %s.\n' "$name" > "$repo/.orch/specs/${name}.md"
}

[[ -x "$ROOT/run.sh" ]] || fail "run.sh is missing or not executable"

# --- A. Blocked cascade -------------------------------------------------------

A_REPO="$TMP/a-repo"
A_HARNESS="$TMP/a-harness"
A_FAKE_BIN="$TMP/a-fake-bin"
A_LOG="$TMP/a-dispatch.log"
mkdir -p "$A_FAKE_BIN"
setup_harness "$A_HARNESS"
write_fake_codex "$A_FAKE_BIN/codex"
init_git_repo "$A_REPO"
write_spec "$A_REPO" a
write_spec "$A_REPO" b
write_spec "$A_REPO" c
cat > "$A_REPO/.orch/units.json" <<'JSON'
{
  "jobs": 2,
  "units": [
    {"id": "a", "slug": "a", "spec": "specs/a.md", "gate": "false", "lane": "codex"},
    {"id": "b", "slug": "b", "spec": "specs/b.md", "gate": "true", "lane": "codex", "deps": ["a"]},
    {"id": "c", "slug": "c", "spec": "specs/c.md", "gate": "true", "lane": "codex", "deps": ["a"]}
  ]
}
JSON
: > "$A_LOG"
A_EC=0
env PATH="$A_FAKE_BIN:$PATH" FAKE_DISPATCH_LOG="$A_LOG" \
  "$A_HARNESS/run.sh" --repo "$A_REPO" --no-probe "$A_REPO/.orch/units.json" \
  > "$TMP/a.out" 2> "$TMP/a.err" || A_EC=$?
[[ "$A_EC" -eq 0 ]] || fail "A: run.sh exited $A_EC instead of reporting unit failures"

A_REPORT="$A_REPO/.orch/report.json"
[[ -f "$A_REPORT" ]] || fail "A: report.json was not written"
assert_jq "$A_REPORT" \
  'any(.units[]; .id == "a" and .status == "gate_failed" and .state == "failed")' \
  "A: unit a should be gate_failed / failed"
assert_jq "$A_REPORT" \
  'any(.units[]; .id == "b" and .status == "blocked" and .state == "blocked")' \
  "A: unit b should be blocked / blocked"
assert_jq "$A_REPORT" \
  'any(.units[]; .id == "c" and .status == "blocked" and .state == "blocked")' \
  "A: unit c should be blocked / blocked"
assert_jq "$A_REPORT" \
  '.summary.blocked == 2' \
  "A: summary.blocked should be 2"

grep -qxF 'a' "$A_LOG" || fail "A: dispatch log missing unit a"
if grep -qxF 'b' "$A_LOG"; then fail "A: unit b was dispatched"; fi
if grep -qxF 'c' "$A_LOG"; then fail "A: unit c was dispatched"; fi
[[ ! -e "$A_REPO/.wt/b" ]] || fail "A: worktree .wt/b was created"
[[ ! -e "$A_REPO/.wt/c" ]] || fail "A: worktree .wt/c was created"
grep -q 'blocked' "$TMP/a.err" || fail "A: driver did not log a blocked message"

# --- B. Ordering proof (passing scenario) ------------------------------------

B_REPO="$TMP/b-repo"
B_HARNESS="$TMP/b-harness"
B_FAKE_BIN="$TMP/b-fake-bin"
B_LOG="$TMP/b-dispatch.log"
mkdir -p "$B_FAKE_BIN"
setup_harness "$B_HARNESS"
write_fake_codex "$B_FAKE_BIN/codex"
init_git_repo "$B_REPO"
write_spec "$B_REPO" a
write_spec "$B_REPO" b
cat > "$B_REPO/.orch/units.json" <<'JSON'
{
  "jobs": 2,
  "units": [
    {"id": "a", "slug": "a", "spec": "specs/a.md", "gate": "true", "lane": "codex"},
    {"id": "b", "slug": "b", "spec": "specs/b.md", "gate": "true", "lane": "codex", "deps": ["a"]}
  ]
}
JSON
: > "$B_LOG"
B_EC=0
env PATH="$B_FAKE_BIN:$PATH" FAKE_DISPATCH_LOG="$B_LOG" \
  "$B_HARNESS/run.sh" --repo "$B_REPO" --no-probe "$B_REPO/.orch/units.json" \
  > "$TMP/b.out" 2> "$TMP/b.err" || B_EC=$?
[[ "$B_EC" -eq 0 ]] || fail "B: run.sh exited $B_EC"

B_REPORT="$B_REPO/.orch/report.json"
[[ -f "$B_REPORT" ]] || fail "B: report.json was not written"
assert_jq "$B_REPORT" \
  'any(.units[]; .id == "a" and .status == "pass" and .state == "passed")' \
  "B: unit a should be pass / passed"
assert_jq "$B_REPORT" \
  'any(.units[]; .id == "b" and .status == "pass" and .state == "passed")' \
  "B: unit b should be pass / passed"

a_line=$(grep -n '^a$' "$B_LOG" | head -1 | cut -d: -f1)
b_line=$(grep -n '^b$' "$B_LOG" | head -1 | cut -d: -f1)
[[ -n "$a_line" ]] || fail "B: dispatch log missing unit a"
[[ -n "$b_line" ]] || fail "B: dispatch log missing unit b"
(( a_line < b_line )) || fail "B: unit a (line $a_line) was not dispatched before unit b (line $b_line)"

# --- C. Unknown dep rejected before dispatch ---------------------------------

C_REPO="$TMP/c-repo"
mkdir -p "$C_REPO/.orch/specs" "$C_REPO/.git/info"
printf '%s\n' '{"jobs":1,"units":[{"id":"u1","slug":"u1","spec":"specs/x.md","lane":"codex","deps":["does-not-exist"]}]}' \
  > "$C_REPO/.orch/units.json"
C_EC=0
"$ROOT/run.sh" --repo "$C_REPO" "$C_REPO/.orch/units.json" \
  > "$TMP/c.out" 2> "$TMP/c.err" || C_EC=$?
[[ "$C_EC" -ne 0 ]] || fail "C: unknown dep was accepted"
grep -q 'unknown dep' "$TMP/c.err" || fail "C: stderr missing 'unknown dep'"
[[ ! -f "$C_REPO/.orch/report.json" ]] || fail "C: report.json was created despite validation failure"
shopt -s nullglob
c_results=("$C_REPO"/.orch/results/*.json)
shopt -u nullglob
(( ${#c_results[@]} == 0 )) || fail "C: results/ was not empty after validation failure"

# --- D. Cyclic deps rejected before dispatch ---------------------------------

D_REPO="$TMP/d-repo"
mkdir -p "$D_REPO/.orch/specs" "$D_REPO/.git/info"
printf '%s\n' '{"jobs":1,"units":[{"id":"a","slug":"a","spec":"specs/x.md","lane":"codex","deps":["b"]},{"id":"b","slug":"b","spec":"specs/x.md","lane":"codex","deps":["a"]}]}' \
  > "$D_REPO/.orch/units.json"
D_EC=0
"$ROOT/run.sh" --repo "$D_REPO" "$D_REPO/.orch/units.json" \
  > "$TMP/d.out" 2> "$TMP/d.err" || D_EC=$?
[[ "$D_EC" -ne 0 ]] || fail "D: cyclic deps were accepted"
grep -q 'cycl' "$TMP/d.err" || fail "D: stderr missing 'cycl'"
[[ ! -f "$D_REPO/.orch/report.json" ]] || fail "D: report.json was created despite validation failure"
shopt -s nullglob
d_results=("$D_REPO"/.orch/results/*.json)
shopt -u nullglob
(( ${#d_results[@]} == 0 )) || fail "D: results/ was not empty after validation failure"

printf 'DEPS TESTS PASSED\n'
