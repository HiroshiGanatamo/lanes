#!/usr/bin/env bash
# Fan-out driver: dispatch frozen specs to CLI worker lanes, gate each result, emit one report.
# Claude writes specs and reads report.json. Everything between is this script.
set -euo pipefail

ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES=(codex kimi grok)

# --- lane invocations -------------------------------------------------------
# Each lane runs one frozen prompt file to completion, non-interactively, in $wt.
# Verified against the installed CLIs; see README.md for the flags that do NOT work.

lane_probe() {
  case "$1" in
    codex) codex exec --yolo 'reply with exactly: LANE_OK' ;;
    kimi)  kimi -p 'reply with exactly: LANE_OK' ;;
    grok)  grok --always-approve --max-turns 2 -p 'reply with exactly: LANE_OK' ;;
  esac
}

# Effort is the cheapest quality/cost dial there is, and every lane defaults high:
# codex's config sits at "max", which is why a routine unit can burn four minutes.
# codex and grok both take low|medium|high. kimi exposes no effort flag — its dial is the
# model alias, so an effort request there resolves to a model instead.
lane_run() {
  local lane="$1" wt="$2" prompt="$3" max_turns="$4" session="$5" lastmsg="$6"
  local model="$7" effort="$8"
  local -a args=()
  case "$lane" in
    codex)
      [[ -n "$model"  ]] && args+=(-m "$model")
      [[ -n "$effort" ]] && args+=(-c "model_reasoning_effort=\"$effort\"")
      codex exec --yolo "${args[@]}" -C "$wt" -o "$lastmsg" - < "$prompt" ;;
    kimi)
      [[ -n "$model" ]] && args+=(-m "$model")
      (cd "$wt" && kimi "${args[@]}" -p "$(cat "$prompt")") ;;
    grok)
      [[ -n "$model"  ]] && args+=(-m "$model")
      [[ -n "$effort" ]] && args+=(--effort "$effort")
      grok --cwd "$wt" --always-approve --max-turns "$max_turns" --output-format json \
           "${args[@]}" -s "$session" --prompt-file "$prompt" ;;
  esac
}

# Effort a unit gets when it does not name one. Recon is retrieval, not reasoning, and the
# lane defaults would spend high-effort tokens reading files. "inherit" leaves the CLI's own
# config alone.
default_effort() {
  case "$1" in
    recon) echo low ;;
    judge) echo high ;;
    *)     echo medium ;;
  esac
}

# Resume line handed back in the report. Follow-ups cost a sentence, not a re-brief:
# the worker still holds the spec, the codebase, and its own reasoning.
lane_resume_cmd() {
  local lane="$1" wt="$2" session="$3"
  case "$lane" in
    codex) printf "codex exec -C %q resume %s '<message>'" "$wt" "${session:---last}" ;;
    kimi)  printf "cd %q && kimi -r %s -p '<message>'" "$wt" "${session:-<session_id>}" ;;
    grok)  printf "grok --cwd %q --always-approve -r %s -p '<message>'" "$wt" "$session" ;;
  esac
}

# Actually performs a resume, unlike lane_resume_cmd above which only builds the human-readable
# string for report.json. Used by resolve_assumptions to auto-fix without a human retyping the
# command — --yolo/--always-approve carried through since nobody is present to click approve.
lane_resume_run() {
  local lane="$1" wt="$2" session="$3" msg="$4"
  case "$lane" in
    codex) codex exec --yolo -C "$wt" resume "${session:---last}" "$msg" ;;
    kimi)  (cd "$wt" && kimi -r "$session" -p "$msg") ;;
    grok)  grok --cwd "$wt" --always-approve -r "$session" -p "$msg" ;;
  esac
}

# Session id, for lanes that report one.
lane_session_from_log() {
  local lane="$1" log="$2"
  case "$lane" in
    kimi)  grep -oE 'session_[0-9a-f-]{8,}' "$log" | tail -1 || true ;;
    codex) sed -nE 's/^session id: ([0-9a-f-]{20,}).*/\1/p' "$log" | head -1 || true ;;
    grok)  jq -r '.sessionId // empty' "$log" 2>/dev/null || true ;;
    *)     : ;;
  esac
}

lane_tokens() {
  local lane="$1" log="$2" session="${3:-}"
  case "$lane" in
    codex) awk '/^tokens used$/ { if (getline > 0) { gsub(/,/, ""); if ($0 ~ /^[0-9]+$/) tokens=$0 } } END { print tokens+0 }' "$log" ;;
    kimi)
      local sessions="$HOME/.kimi-code/sessions"
      [[ -n "$session" && -d "$sessions" ]] || { echo 0; return; }
      find "$sessions" -maxdepth 2 -type d -name "$session" \
        -exec sh -c 'cat "$1"/agents/*/wire.jsonl' _ {} \; 2>/dev/null \
        | jq -s '[.[] | select(.type=="usage.record") | .usage | (.inputOther + .output + .inputCacheRead + .inputCacheCreation)] | add // 0' ;;
    grok)  jq -r '.usage.total_tokens // 0' "$log" 2>/dev/null || echo 0 ;;
    *)     echo 0 ;;
  esac
}

lane_cost() {
  local lane="$1" log="$2"
  case "$lane" in
    grok) jq -r '.total_cost_usd // 0' "$log" 2>/dev/null || echo 0 ;;
    *)    echo 0 ;;
  esac
}

# --- helpers ----------------------------------------------------------------

die() { printf 'orchestrator: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[2m[orch]\033[0m %s\n' "$*" >&2; }

# Normalize the many historical `status` values onto four terminal states. status
# itself is left alone — merge.sh and the summary counters still key off it.
unit_state_from_status() {
  case "$1" in
    pass|answered|judged) echo passed ;;
    halted)               echo cancelled ;;
    blocked)              echo blocked ;;
    *)                    echo failed ;;
  esac
}

# Fail fast on unknown dep ids and cycles. Validates the full units.json, not
# the --only subset: a missing sibling in this invocation is a runtime block,
# not a schema error.
validate_deps() {
  local file="$1" unknown cyclic

  unknown=$(jq -r '
    (.units | map(.id)) as $ids
    | [
        .units[]
        | .id as $uid
        | ((.deps // []) | if type == "array" then . else empty end)[]
        | select(. as $d | ($ids | index($d)) == null)
        | "\($uid) -> \(.)"
      ]
    | unique
    | .[]
  ' "$file")
  [[ -z "$unknown" ]] || die "unknown dep: ${unknown//$'\n'/, }"

  cyclic=$(jq -r '
    .units
    | map({id, deps: ((.deps // []) | if type == "array" then . else [] end)}) as $nodes
    | ($nodes | map(.id)) as $ids
    | reduce range(0; ($ids | length) + 1) as $_ (
        {remaining: $ids, resolved: []};
        . as $st
        | ($st.remaining | map(select(
            . as $id
            | ($nodes[] | select(.id == $id) | .deps)
            | all(. as $d | ($st.resolved | index($d)) != null)
          ))) as $ready
        | if ($ready | length) == 0 then $st
          else {remaining: ($st.remaining - $ready), resolved: ($st.resolved + $ready)}
          end
      )
    | .remaining[]
  ' "$file")
  [[ -z "$cyclic" ]] || die "cyclic deps: ${cyclic//$'\n'/, }"
}

# Never-dispatched result for a unit whose dependency cannot become passed in
# this invocation. Field set matches the HALT branch in exec_unit.
write_blocked_result() {
  local repo="$1" orch="$2" plan="$3" id="$4" reason="$5"
  local unit slug lane kind gate model effort wt branch logf resultf status state
  unit=$(jq --arg id "$id" '.[] | select(.id == $id)' "$plan")
  slug=$(jq -r '.slug' <<<"$unit")
  lane=$(jq -r '.lane' <<<"$unit")
  kind=$(jq -r '.kind // "impl"' <<<"$unit")
  gate=$(jq -r '.gate // ""' <<<"$unit")
  model=$(jq -r '.model // ""' <<<"$unit")
  effort=$(jq -r '.effort // ""' <<<"$unit")
  [[ -z "$effort" ]] && effort=$(default_effort "$kind")
  [[ "$effort" == "inherit" ]] && effort=""
  [[ "$lane" == "kimi" ]] && effort=""

  if [[ "$kind" == "recon" || "$kind" == "judge" ]]; then
    wt="$repo"; branch=""; gate=""
  else
    wt="$repo/.wt/$slug"; branch="wip/$slug"
  fi

  logf=""
  resultf="$orch/results/$id.json"
  status="blocked"
  state=$(unit_state_from_status "$status")

  log "$id [$lane] blocked — dependency $reason did not pass"

  jq -n \
    --arg id "$id" --arg slug "$slug" --arg lane "$lane" --arg branch "$branch" --arg kind "$kind" \
    --arg wt "$wt" --arg gate "$gate" --arg log "$logf" --arg model "$model" --arg effort "$effort" \
    --arg status "$status" --arg state "$state" \
    '{id:$id,slug:$slug,kind:$kind,lane:$lane,model:$model,effort:$effort,branch:$branch,worktree:$wt,
      worker_exit:0,gate:$gate,gate_exit:-1,gate_tail:"",files_changed:0,insertions:0,deletions:0,
      dirty_paths:0,seconds:0,tokens:0,cost_usd:0,session:"",resume:"",log:$log,answer:"",
      judgement:null,assumptions:[],assumption_judgement:null,status:$status,state:$state}' > "$resultf"
}

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

# All three lanes can spawn their own subagents, so a unit is not limited to one worker's
# serial attention. The tool names differ per CLI, so name all three and let the worker pick.
subagent_note() {
  case "$1" in
    codex) printf -- '- You may spawn parallel subagents (`collaboration.spawn_agent`) for independent parts of\n  this unit — separate files, separate test targets, or an investigation that runs while you write.\n  Do not spawn one per trivial edit; the coordination is only worth it for genuinely parallel work.' ;;
    kimi)  printf -- '- You may spawn parallel subagents (`AgentSwarm`) for independent parts of this unit — separate\n  files, separate test targets, or an investigation that runs while you write. Do not spawn one per\n  trivial edit; the coordination is only worth it for genuinely parallel work.' ;;
    grok)  printf -- '- You may spawn parallel subagents (`spawn_subagent`, called several times in one turn) for\n  independent parts of this unit — separate files, separate test targets, or an investigation that\n  runs while you write. Do not spawn one per trivial edit; the coordination is only worth it for\n  genuinely parallel work.' ;;
  esac
}

render_recon_prompt() {
  # Recon answers a question about the repo without touching it. In lanes-only mode this is
  # what replaces Claude reading files: the file dumps stay in the worker's context, and only
  # the answer crosses back.
  local spec="$1" wt="$2" out="$3"
  cat > "$out" <<EOF
You are answering a question about an existing codebase. This is a read-only investigation.

Working directory: $wt

Hard rules:
- Do not modify, create, or delete any file. Do not run any git write command.
- Do not ask questions. If something is ambiguous, answer for the most likely reading and say so.
- Your final message is the entire deliverable and is read by an orchestrator, not a human. Lead
  with the answer. Cite concrete paths as path:line. No preamble, no restating the question.

--- QUESTION ---
$(cat "$spec")
EOF
}

render_judge_prompt() {
  # A judge scores an existing artifact without touching the repository. Its answer is machine-read
  # into the result JSON, so the output contract is deliberately strict.
  local spec="$1" wt="$2" out="$3"
  cat > "$out" <<EOF
You are scoring an existing artifact against a rubric. This is a read-only investigation.

Working directory: $wt

Hard rules:
- Do not modify, create, or delete any file. Do not run any git write command.
- Do not ask questions. If something is ambiguous, use the most likely reading.
- Output ONLY a JSON object with exactly this shape:
  {"score": <integer 1-10>, "verdict": "<one sentence>", "issues": ["<issue>", ...]}
- Output nothing else: no prose and no code fences.

--- ARTIFACT AND RUBRIC ---
$(cat "$spec")
EOF
}

judgement_from_answer() {
  local answer="$1" candidate
  local filter='
    select(type == "object")
    | select((.score | type) == "number" and (.score | floor) == .score and .score >= 1 and .score <= 10)
    | select((.verdict | type) == "string")
    | select((.issues | type) == "array" and all(.issues[]; type == "string"))
  '

  if candidate=$(jq -ce "$filter" "$answer" 2>/dev/null); then
    printf '%s\n' "$candidate"
    return
  fi

  candidate=$(awk '
    {
      if (NR > 1 && depth > 0) candidate = candidate "\n"
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (depth == 0) {
          if (char == "{") {
            candidate = char
            depth = 1
            in_string = 0
            escaped = 0
          }
          continue
        }

        candidate = candidate char
        if (in_string) {
          if (escaped) escaped = 0
          else if (char == "\\") escaped = 1
          else if (char == "\"") in_string = 0
        } else if (char == "\"") {
          in_string = 1
        } else if (char == "{") {
          depth++
        } else if (char == "}") {
          depth--
          if (depth == 0) {
            last = candidate
            candidate = ""
          }
        }
      }
    }
    END { if (last != "") printf "%s", last }
  ' "$answer")

  [[ -n "$candidate" ]] || return 1
  jq -ce "$filter" <<<"$candidate" 2>/dev/null
}

# The no-questions rule (render_prompt) means a worker never blocks on ambiguity — it guesses and
# is told to record the guess. This extracts that record. Absence is the common case, not an error:
# always prints valid JSON (an empty array when nothing was flagged or the block didn't parse).
assumptions_from_answer() {
  local answer="$1" body candidate
  grep -q '^ASSUMPTIONS_JSON:' "$answer" 2>/dev/null || { printf '[]\n'; return; }
  body=$(sed -n '/^ASSUMPTIONS_JSON:/,$p' "$answer")

  local filter='
    select(type == "array")
    | select(all(.[]; type == "object"
        and (.what | type) == "string"
        and (.reading_chosen | type) == "string"
        and (.alternative_rejected | type) == "string"
        and (.blast_radius == "local" or .blast_radius == "shared")))
  '

  if candidate=$(jq -ce "$filter" <<<"$body" 2>/dev/null) && [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  candidate=$(awk '
    {
      if (NR > 1 && depth > 0) candidate = candidate "\n"
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (depth == 0) {
          if (char == "[") {
            candidate = char
            depth = 1
            in_string = 0
            escaped = 0
          }
          continue
        }

        candidate = candidate char
        if (in_string) {
          if (escaped) escaped = 0
          else if (char == "\\") escaped = 1
          else if (char == "\"") in_string = 0
        } else if (char == "\"") {
          in_string = 1
        } else if (char == "[") {
          depth++
        } else if (char == "]") {
          depth--
          if (depth == 0) {
            last = candidate
            candidate = ""
          }
        }
      }
    }
    END { if (last != "") printf "%s", last }
  ' <<<"$body")

  [[ -n "$candidate" ]] || { printf '[]\n'; return; }
  jq -ce "$filter" <<<"$candidate" 2>/dev/null || printf '[]\n'
}

render_prompt() {
  # The worker starts with zero context. Everything it may not do goes here,
  # so a forgotten line in a hand-written spec cannot cost a rejected unit.
  local spec="$1" wt="$2" slug="$3" gate="$4" out="$5" SUBAGENT_NOTE="$6"
  cat > "$out" <<EOF
You are implementing one unit of work inside an isolated git worktree.

Working directory: $wt
It is already checked out on branch wip/$slug. Stay inside it.

Hard rules:
- Do not run git commit, git push, git add, git stage, git checkout, git branch, git merge, or any
  other git write command. Leave the working tree dirty. The orchestrator reviews and commits.
- Do not create, remove, or switch git worktrees.
- Do not edit files outside this worktree.
- Do not ask questions. If the spec leaves a detail open, choose the conventional option and record
  the choice in your final message.
- If you had to guess on anything ambiguous, append this block after your final message (omit
  entirely if you made no guesses). One entry per guess:

  ASSUMPTIONS_JSON:
  [{"what": "<what was ambiguous>", "reading_chosen": "<the reading you went with>", "alternative_rejected": "<the other plausible reading>", "blast_radius": "local|shared"}]

  Use "shared" when the reading affects a public API, a shared type, a data schema, or persisted
  data — anything another unit or caller could depend on. Otherwise use "local".
$SUBAGENT_NOTE

Definition of done: the command below exits zero. Run it yourself and iterate until it passes.

    $gate

Your final message must state: what you changed, the gate result, and every deviation from the spec.

--- SPEC ---
$(cat "$spec")
EOF
}

# A worker never blocks on ambiguity — render_prompt's no-questions rule means it guesses and
# records the guess instead. A "local" guess merges on the gate alone, same as always. A "shared"
# guess (touches a public API, shared type, schema, or persisted data) gets a second, independent
# opinion before being trusted: a judge unit scores the reading against the spec. Score at or above
# threshold keeps the pass. Below it, the original worker is auto-resumed once with the judge's
# issues and the gate re-run — no human reads or approves any of this, per AUTONOMY.md's rule to
# prefer a mechanical gate over a person. A unit still weak after the auto-fix is marked
# assumption_unresolved, which merge.sh's existing pass-only filter already excludes from merging;
# nothing here blocks the rest of the run, and the recorded resume command is the next lever.
resolve_assumptions() {
  local orch="$1" plan="$2" threshold="${3:-7}"
  local f
  for f in "$orch"/results/*.json; do
    [[ -f "$f" ]] || continue
    local kind status
    kind=$(jq -r '.kind' "$f")
    status=$(jq -r '.status' "$f")
    [[ "$kind" == "impl" && "$status" == "pass" ]] || continue

    local shared; shared=$(jq -c '[.assumptions[]? | select(.blast_radius == "shared")]' "$f")
    [[ "$(jq 'length' <<<"$shared")" -gt 0 ]] || continue

    local id lane wt session gate spec
    id=$(jq -r '.id' "$f"); lane=$(jq -r '.lane' "$f"); wt=$(jq -r '.worktree' "$f")
    session=$(jq -r '.session' "$f"); gate=$(jq -r '.gate' "$f")
    spec=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .spec' "$plan")

    log "$id: $(jq 'length' <<<"$shared") shared-blast-radius assumption(s) — dispatching judge"

    local jin="$orch/prompts/$id.assume-input.md" jprompt="$orch/prompts/$id.assume-judge.md"
    local jlog="$orch/logs/$id.assume-judge.log" jmsg="$orch/logs/$id.assume-judge.answer.txt"
    {
      printf 'A worker implementing this unit hit ambiguity and had to guess rather than ask.\n'
      printf 'Score whether its chosen reading is the one the spec most likely intended.\n\n'
      printf -- '--- SPEC ---\n%s\n\n--- ASSUMPTIONS MADE ---\n%s\n' "$(cat "$orch/$spec")" "$shared"
    } > "$jin"
    render_judge_prompt "$jin" "$wt" "$jprompt"

    local jsession; jsession=$(uuidgen | tr 'A-Z' 'a-z')
    : > "$jmsg"
    lane_run "$lane" "$wt" "$jprompt" 30 "$jsession" "$jmsg" "" "high" > "$jlog" 2>&1 || true
    if [[ ! -s "$jmsg" ]]; then
      if [[ "$lane" == "grok" ]] && jq -er '.text' "$jlog" > "$jmsg" 2>/dev/null; then
        :
      else
        grep -v 'To resume this session' "$jlog" | tail -c 6000 > "$jmsg" || true
      fi
    fi

    local judgement; judgement=$(judgement_from_answer "$jmsg" || true)
    [[ -n "$judgement" ]] || judgement="null"
    local score; score=$(jq -r 'if . == null then 0 else .score end' <<<"$judgement")

    if (( score >= threshold )); then
      log "$id: assumption judged sound ($score/10) — keeping pass"
      jq --argjson j "$judgement" '.assumption_judgement = $j' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      continue
    fi

    log "$id: assumption judged weak ($score/10) — auto-resuming worker, no human involved"
    local verdict issues msg
    verdict=$(jq -r '.verdict // "no verdict"' <<<"$judgement")
    issues=$(jq -r '(.issues // []) | join("; ")' <<<"$judgement")
    msg="Independent review scored one of your recorded assumptions ${score}/10: ${verdict} Issues: ${issues}. Reconsider and fix if warranted, then confirm: $gate"

    lane_resume_run "$lane" "$wt" "$session" "$msg" \
      > "$orch/logs/$id.assume-resume.log" 2>&1 || true

    local gate_exit=0
    if [[ -n "$gate" && "$gate" != "null" ]]; then
      (cd "$wt" && bash -c "$gate") >/dev/null 2>&1 || gate_exit=$?
    fi
    git -C "$wt" add -N . >/dev/null 2>&1 || true

    if (( gate_exit == 0 )); then
      log "$id: gate still green after auto-fix"
      jq --argjson j "$judgement" '.assumption_judgement = $j' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
      log "$id: gate red after auto-fix — assumption_unresolved, excluded from merge, not blocking the rest"
      jq --argjson j "$judgement" \
        '.assumption_judgement = $j | .status = "assumption_unresolved"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  done
}

# --- per-unit execution (re-entrant: invoked by xargs) ----------------------

exec_unit() {
  local repo="$1" orch="$2" payload="$3"
  local unit; unit="$(printf '%s' "$payload" | base64 --decode)"

  local id slug lane gate max_turns spec kind subagents model effort commit
  id=$(jq -r '.id' <<<"$unit")
  commit=$(jq -r '.commit // ""' <<<"$unit")
  slug=$(jq -r '.slug' <<<"$unit")
  lane=$(jq -r '.lane' <<<"$unit")
  gate=$(jq -r '.gate // ""' <<<"$unit")
  max_turns=$(jq -r '.max_turns // 60' <<<"$unit")
  kind=$(jq -r '.kind // "impl"' <<<"$unit")
  subagents=$(jq -r 'if .subagents == false then "no" else "yes" end' <<<"$unit")
  spec="$orch/$(jq -r '.spec' <<<"$unit")"
  model=$(jq -r '.model // ""' <<<"$unit")
  effort=$(jq -r '.effort // ""' <<<"$unit")
  [[ -z "$effort" ]] && effort=$(default_effort "$kind")
  [[ "$effort" == "inherit" ]] && effort=""
  [[ "$lane" == "kimi" ]] && effort=""   # no effort flag; model alias is kimi's dial

  local wt branch="wip/$slug"
  local logf="$orch/logs/$id.$lane.log"
  local promptf="$orch/prompts/$id.md"
  local resultf="$orch/results/$id.json"
  local lastmsg="$orch/logs/$id.answer.txt"
  local session; session=$(uuidgen | tr 'A-Z' 'a-z')

  [[ -f "$spec" ]] || die "unit $id: spec not found: $spec"

  if [[ "$kind" == "recon" || "$kind" == "judge" ]]; then
    # Read-only: no worktree, no branch, no gate. Runs against the repo as it stands.
    wt="$repo"; branch=""; gate=""
    if [[ "$kind" == "judge" ]]; then
      render_judge_prompt "$spec" "$wt" "$promptf"
    else
      render_recon_prompt "$spec" "$wt" "$promptf"
    fi
  else
    wt="$repo/.wt/$slug"
    if [[ ! -d "$wt" ]]; then
      if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repo" worktree add "$wt" "$branch" >/dev/null 2>&1
      else
        git -C "$repo" worktree add "$wt" -b "$branch" >/dev/null 2>&1
      fi
    fi
    local note=""
    [[ "$subagents" == "yes" ]] && note="$(subagent_note "$lane")"
    render_prompt "$spec" "$wt" "$slug" "$gate" "$promptf" "$note"
  fi

  # A human kill switch is checked at the last possible moment before lane execution.
  if [[ -f "$ORCH_HOME/HALT" ]]; then
    log "$id [$lane] halted — HALT is present at $ORCH_HOME/HALT"
    local halt_status="halted"
    local halt_state
    halt_state=$(unit_state_from_status "$halt_status")
    jq -n \
      --arg id "$id" --arg slug "$slug" --arg lane "$lane" --arg branch "$branch" --arg kind "$kind" \
      --arg wt "$wt" --arg gate "$gate" --arg log "$logf" --arg model "$model" --arg effort "$effort" \
      --arg status "$halt_status" --arg state "$halt_state" \
      '{id:$id,slug:$slug,kind:$kind,lane:$lane,model:$model,effort:$effort,branch:$branch,worktree:$wt,
        worker_exit:0,gate:$gate,gate_exit:-1,gate_tail:"",files_changed:0,insertions:0,deletions:0,
        dirty_paths:0,seconds:0,tokens:0,cost_usd:0,session:"",resume:"",log:$log,answer:"",
        judgement:null,assumptions:[],assumption_judgement:null,status:$status,state:$state}' > "$resultf"
    return
  fi

  log "$id [$lane/$kind${effort:+/$effort}] dispatch → $wt"
  local start=$SECONDS worker_exit=0
  : > "$lastmsg"
  lane_run "$lane" "$wt" "$promptf" "$max_turns" "$session" "$lastmsg" "$model" "$effort" \
    > "$logf" 2>&1 || worker_exit=$?
  local elapsed=$(( SECONDS - start ))

  # codex writes its final message to a file; the others print it, trailed by a resume hint.
  if [[ ! -s "$lastmsg" ]]; then
    if [[ "$lane" == "grok" ]] && jq -er '.text' "$logf" > "$lastmsg" 2>/dev/null; then
      :
    else
      grep -v 'To resume this session' "$logf" | tail -c 6000 > "$lastmsg" || true
    fi
  fi

  local found; found=$(lane_session_from_log "$lane" "$logf")
  [[ -n "$found" ]] && session="$found"
  local tokens cost_usd
  tokens=$(lane_tokens "$lane" "$logf" "$session")
  cost_usd=$(lane_cost "$lane" "$logf")
  "$ORCH_HOME/spend.sh" record --repo "$repo" --lane "$lane" --unit "$id" \
    --usd "$cost_usd" --tokens "$tokens"

  local judgement="null"
  if [[ "$kind" == "judge" ]]; then
    judgement=$(judgement_from_answer "$lastmsg" || true)
    [[ -n "$judgement" ]] || judgement="null"
  fi

  local assumptions="[]"
  if [[ "$kind" != "recon" && "$kind" != "judge" ]]; then
    assumptions=$(assumptions_from_answer "$lastmsg")
  fi

  # The gate is the only claim that counts. Worker self-reports are advisory.
  local gate_exit=0 gate_tail="" gate_out="$orch/logs/$id.gate.log"
  if [[ -n "$gate" && "$gate" != "null" ]]; then
    (cd "$wt" && bash -c "$gate") > "$gate_out" 2>&1 || gate_exit=$?
    gate_tail=$(tail -40 "$gate_out")
  else
    gate_exit=-1
  fi

  # Workers create files without staging them, and `diff HEAD` cannot see untracked paths.
  # Intent-to-add makes new files visible to diff without committing anything.
  local stat="" changed ins del dirty
  if [[ "$kind" != "recon" && "$kind" != "judge" ]]; then
    git -C "$wt" add -N . >/dev/null 2>&1 || true
    stat=$(git -C "$wt" diff --shortstat HEAD 2>/dev/null || true)
  fi
  changed=$(grep -oE '[0-9]+ file' <<<"$stat" | grep -oE '[0-9]+' || echo 0)
  ins=$(grep -oE '[0-9]+ insertion' <<<"$stat" | grep -oE '[0-9]+' || echo 0)
  del=$(grep -oE '[0-9]+ deletion' <<<"$stat" | grep -oE '[0-9]+' || echo 0)
  dirty=$( [[ "$kind" == "recon" || "$kind" == "judge" ]] && echo 0 || git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  local status
  if (( worker_exit != 0 )); then
    status="worker_failed"
  elif [[ "$kind" == "recon" ]]; then
    status="answered"
  elif [[ "$kind" == "judge" ]]; then
    status="judged"
  elif (( gate_exit == 0 )); then
    status="pass"
  elif (( gate_exit == -1 )); then
    status="no_gate"
  else
    status="gate_failed"
  fi
  local state
  state=$(unit_state_from_status "$status")

  jq -n \
    --arg id "$id" --arg slug "$slug" --arg lane "$lane" --arg branch "$branch" --arg kind "$kind" \
    --arg wt "$wt" --arg gate "$gate" --arg log "$logf" --arg session "$session" \
    --arg resume "$(lane_resume_cmd "$lane" "$wt" "$session")" \
    --arg gate_tail "$gate_tail" --arg answer "$(cat "$lastmsg" 2>/dev/null || true)" \
    --arg model "$model" --arg effort "$effort" --arg commit "$commit" \
    --arg status "$status" --arg state "$state" \
    --argjson worker_exit "$worker_exit" --argjson gate_exit "$gate_exit" \
    --argjson changed "${changed:-0}" --argjson ins "${ins:-0}" --argjson del "${del:-0}" \
    --argjson dirty "${dirty:-0}" --argjson seconds "$elapsed" --argjson tokens "$tokens" \
    --argjson cost_usd "$cost_usd" \
    --argjson judgement "$judgement" \
    --argjson assumptions "$assumptions" \
    '{id:$id,slug:$slug,kind:$kind,lane:$lane,model:$model,effort:$effort,branch:$branch,worktree:$wt,
      worker_exit:$worker_exit,gate:$gate,gate_exit:$gate_exit,gate_tail:$gate_tail,
      commit:(if $commit == "" then null else $commit end),
      files_changed:$changed,insertions:$ins,deletions:$del,dirty_paths:$dirty,
      seconds:$seconds,tokens:$tokens,cost_usd:$cost_usd,session:$session,resume:$resume,log:$log,answer:$answer,
      judgement:$judgement,assumptions:$assumptions,assumption_judgement:null,
      status:$status,state:$state}' > "$resultf"

  log "$id [$lane] $(jq -r .status "$resultf") in ${elapsed}s"
}

if [[ "${1:-}" == "--exec-unit" ]]; then
  exec_unit "$2" "$3" "$4"
  exit 0
fi

# Test-only hooks, same re-entrant pattern as --exec-unit above: let a test invoke one function
# without running the full CLI (arg parsing, lane probe, worktree setup) around it.
if [[ "${1:-}" == "--parse-assumptions" ]]; then
  assumptions_from_answer "$2"
  exit 0
fi

if [[ "${1:-}" == "--resolve-assumptions" ]]; then
  resolve_assumptions "$2" "$3" "${4:-7}"
  exit 0
fi

# --- main -------------------------------------------------------------------

REPO=""; JOBS=""; PROBE=1; DRY=0; CLEAN=0; ONLY=""; UNITS_FILE=""

while (( $# )); do
  case "$1" in
    --repo)     REPO="$2"; shift 2 ;;
    --jobs|-j)  JOBS="$2"; shift 2 ;;
    --only)     ONLY="$2"; shift 2 ;;
    --no-probe) PROBE=0; shift ;;
    --dry-run)  DRY=1; shift ;;
    --clean)    CLEAN=1; shift ;;
    -h|--help)  sed -n '2,4p' "$0"; printf '\nusage: run.sh [--repo DIR] [-j N] [--only id,id] [--no-probe] [--dry-run] [--clean] [units.json]\n'; exit 0 ;;
    *)          UNITS_FILE="$1"; shift ;;
  esac
done

command -v jq >/dev/null || die "jq required"
[[ -z "$REPO" ]] && REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" ]] || die "not in a git repo; pass --repo"
REPO="$(cd "$REPO" && pwd)"

[[ -z "$UNITS_FILE" ]] && UNITS_FILE="$REPO/.orch/units.json"
[[ -f "$UNITS_FILE" ]] || die "no units file: $UNITS_FILE"
UNITS_FILE="$(cd "$(dirname "$UNITS_FILE")" && pwd)/$(basename "$UNITS_FILE")"
ORCH="$(dirname "$UNITS_FILE")"

mkdir -p "$ORCH"/{specs,logs,prompts,results}
rm -f "$ORCH"/results/*.json

# Keep orchestration scaffolding out of the user's tracked ignore file.
excl="$(git -C "$REPO" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null || echo "$REPO/.git/info/exclude")"
mkdir -p "$(dirname "$excl")" 2>/dev/null || true
for p in '.orch/' '.wt/'; do
  grep -qxF "$p" "$excl" 2>/dev/null || printf '%s\n' "$p" >> "$excl"
done

[[ -z "$JOBS" ]] && JOBS=$(jq -r '.jobs // 5' "$UNITS_FILE")
mapfile -t UNIT_IDS < <(jq -r '.units[].id' "$UNITS_FILE")
(( ${#UNIT_IDS[@]} )) || die "units[] empty"
validate_deps "$UNITS_FILE"

# Lane quotas are global across every session on this machine. A dead account
# discovered mid-unit costs minutes; discovered here it costs one trivial prompt.
LIVE=()
if (( PROBE )); then
  log "probing lanes…"
  for lane in "${LANES[@]}"; do
    if with_timeout 90 lane_probe "$lane" >/dev/null 2>&1; then
      LIVE+=("$lane"); log "  $lane live"
    else
      log "  $lane DEAD — dropped from rotation"
    fi
  done
  (( ${#LIVE[@]} )) || die "no live lanes; implement directly"
else
  LIVE=("${LANES[@]}")
fi

# Assign lanes: explicit wins, "auto" round-robins across live lanes by index.
PLAN="$ORCH/.plan.json"
jq --argjson live "$(printf '%s\n' "${LIVE[@]}" | jq -R . | jq -s .)" \
   --arg only "$ONLY" '
  ($live | length) as $n |
  [ .units | to_entries[]
    | .value as $u | .key as $i
    | $u + { lane: (if ($u.lane // "auto") == "auto" then $live[$i % $n] else $u.lane end) }
  ]
  | if $only == "" then . else map(select(.id as $id | ($only | split(",")) | index($id))) end
' "$UNITS_FILE" > "$PLAN"

printf '\n%-10s %-8s %-26s %s\n' ID LANE BRANCH GATE >&2
jq -r '.[] | [.id, .lane, ("wip/" + .slug), (.gate // "-")] | @tsv' "$PLAN" \
  | while IFS=$'\t' read -r a b c d; do printf '%-10s %-8s %-26s %s\n' "$a" "$b" "$c" "$d" >&2; done
printf '\n' >&2

if (( DRY )); then log "dry run — nothing dispatched"; exit 0; fi

if (( CLEAN )); then
  while read -r slug; do
    [[ -d "$REPO/.wt/$slug" ]] && git -C "$REPO" worktree remove --force "$REPO/.wt/$slug" || true
  done < <(jq -r '.[].slug' "$PLAN")
  git -C "$REPO" worktree prune
fi

if ! "$ORCH_HOME/spend.sh" check --repo "$REPO"; then
  die "budget check failed; refusing to dispatch"
fi

log "dispatching $(jq 'length' "$PLAN") units, $JOBS at a time"

declare -A IN_PLAN=() REMAINING=() RESOLVED=()
mapfile -t PLAN_IDS < <(jq -r '.[].id' "$PLAN")
for id in "${PLAN_IDS[@]}"; do
  IN_PLAN["$id"]=1
  REMAINING["$id"]=1
done

while (( ${#REMAINING[@]} > 0 )); do
  READY=()
  BLOCKED_NOW=()
  declare -A BLOCK_REASON=()

  for id in "${!REMAINING[@]}"; do
    ready=1
    blocked=0
    reason=""
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      if [[ -z "${IN_PLAN[$dep]:-}" ]]; then
        blocked=1
        reason="$dep"
        break
      fi
      if [[ -z "${RESOLVED[$dep]:-}" ]]; then
        ready=0
        continue
      fi
      if [[ "${RESOLVED[$dep]}" != "passed" ]]; then
        blocked=1
        reason="$dep"
        break
      fi
    done < <(jq -r --arg id "$id" '.[] | select(.id == $id) | ((.deps // []) | if type == "array" then .[] else empty end)' "$PLAN")

    if (( blocked )); then
      BLOCKED_NOW+=("$id")
      BLOCK_REASON["$id"]="$reason"
    elif (( ready )); then
      READY+=("$id")
    fi
  done

  if (( ${#READY[@]} == 0 && ${#BLOCKED_NOW[@]} == 0 )); then
    die "internal error: no ready or blocked units remaining (${!REMAINING[*]})"
  fi

  for id in "${BLOCKED_NOW[@]}"; do
    write_blocked_result "$REPO" "$ORCH" "$PLAN" "$id" "${BLOCK_REASON[$id]}"
    RESOLVED["$id"]="not_passed"
    unset 'REMAINING[$id]'
  done

  if (( ${#READY[@]} > 0 )); then
    WAVE="$ORCH/.wave.json"
    jq --argjson ids "$(printf '%s\n' "${READY[@]}" | jq -R . | jq -s .)" \
      'map(select(.id as $id | $ids | index($id)))' "$PLAN" > "$WAVE"
    jq -r '.[] | @base64' "$WAVE" \
      | xargs -P "$JOBS" -n1 "$ORCH_HOME/run.sh" --exec-unit "$REPO" "$ORCH" || true
    for id in "${READY[@]}"; do
      resultf="$ORCH/results/$id.json"
      if [[ -f "$resultf" ]] && [[ "$(jq -r '.state' "$resultf")" == "passed" ]]; then
        RESOLVED["$id"]="passed"
      else
        RESOLVED["$id"]="not_passed"
      fi
      unset 'REMAINING[$id]'
    done
  fi
done

REPORT="$ORCH/report.json"
# A unit that dies before writing its result (bad spec path, missing lane) leaves the glob empty;
# without this the run ends in a jq error instead of a report saying nothing ran.
shopt -s nullglob
RESULT_FILES=("$ORCH"/results/*.json)
shopt -u nullglob
(( ${#RESULT_FILES[@]} )) || die "no unit produced a result — check the errors above"

resolve_assumptions "$ORCH" "$PLAN"

# resolve_assumptions may flip status to assumption_unresolved without writing
# state; re-derive so the mapping cannot drift from the result file.
for f in "${RESULT_FILES[@]}"; do
  st=$(jq -r '.status' "$f")
  jq --arg state "$(unit_state_from_status "$st")" '.state = $state' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

jq -s --arg repo "$REPO" '{
  repo: $repo,
  units: .,
  summary: {
    total: length,
    pass: (map(select(.status == "pass")) | length),
    gate_failed: (map(select(.status == "gate_failed")) | length),
    worker_failed: (map(select(.status == "worker_failed")) | length),
    no_gate: (map(select(.status == "no_gate")) | length),
    answered: (map(select(.status == "answered")) | length),
    judged: (map(select(.status == "judged")) | length),
    halted: (map(select(.status == "halted")) | length),
    blocked: (map(select(.status == "blocked")) | length),
    assumption_unresolved: (map(select(.status == "assumption_unresolved")) | length),
    assumptions_flagged: (map(select((.assumptions // []) | length > 0)) | length),
    tokens: (map(.tokens) | add),
    cost_usd: (map(.cost_usd) | add),
    seconds: (map(.seconds) | max)
  }
}' "${RESULT_FILES[@]}" > "$REPORT"

printf '\n%-10s %-8s %-13s %-7s %-6s %s\n' ID LANE STATUS FILES TIME LOG >&2
jq -r '.units[] | [.id,.lane,.status,(.files_changed|tostring),((.seconds|tostring)+"s"),.log] | @tsv' "$REPORT" \
  | while IFS=$'\t' read -r a b c d e f; do printf '%-10s %-8s %-13s %-7s %-6s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" >&2; done
printf '\nreport: %s\n' "$REPORT" >&2
jq -r '.summary | "pass \(.pass)/\(.total)  gate_failed \(.gate_failed)  worker_failed \(.worker_failed)  assumption_unresolved \(.assumption_unresolved)"' "$REPORT" >&2
