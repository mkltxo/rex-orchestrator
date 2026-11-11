#!/bin/bash
# Unit checks for two helpers of rex-orchestrator.sh that the fake-rex harness only reaches indirectly: real_path and
# background_tasks, read out of the script under test. Usage: <bash> unit.sh (REX_ORCHESTRATOR_SH: the script).
# Prints PASS/FAIL lines like harness.py, tagged with the findings they cover.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${REX_ORCHESTRATOR_SH:-$here/../../skills/rex-orchestrator/scripts/rex-orchestrator.sh}

# Define the named functions from the script: a one-line body, or one closed by a '}' in column 0.
for f in die note real_path background_tasks ere_escape sq names_ok; do
  eval "$(awk -v f="$f() {" 'index($0, f) == 1 { on = 1; one = /}[[:space:]]*$/ } on { print } on && (one || /^}/) { exit }' "$SCRIPT")"
  declare -F "$f" >/dev/null || { echo "FAIL  unit: no function $f in $SCRIPT"; exit 1; }
done

check() { # NAME IDS GOT WANT
  if [ "$3" = "$4" ]; then printf 'PASS  %s%s\t%s\n' "$1" "${2:+ [$2]}" "$3"; else printf 'FAIL  %s%s\tgot [%s], want [%s]\n' "$1" "${2:+ [$2]}" "$3" "$4"; fi
}

R=$(mktemp -d /tmp/rxu.XXXXXX); R=$(cd "$R" && pwd -P); trap 'rm -rf "$R"' EXIT
mkdir -p "$R/in/sub" "$R/in/has space" "$R/out"
: >"$R/in/sub/f.txt"; : >"$R/out/t.txt"
ln -s "$R/out" "$R/in/linkdir"; ln -s "$R/in/sub" "$R/in/linkdir_in"; ln -s "$R/in" "$R/alias"
ln -s "$R/out/t.txt" "$R/in/flink"; ln -s ../out/t.txt "$R/in/relink"; ln -s "$R/out/new.txt" "$R/in/dangling"
rp() { real_path "$1" 2>/dev/null || echo "(rc $?)"; }
check "real_path: existing file" "" "$(rp "$R/in/sub/f.txt")" "$R/in/sub/f.txt"
check "real_path: existing dir" "" "$(rp "$R/in/sub")" "$R/in/sub"
check "real_path: new file" "" "$(rp "$R/in/sub/new.txt")" "$R/in/sub/new.txt"
check "real_path: new path below new dirs" "" "$(rp "$R/in/new/deeper/f.txt")" "$R/in/new/deeper/f.txt"
check "real_path: dir link to outside" "" "$(rp "$R/in/linkdir/f.txt")" "$R/out/f.txt"
check "real_path: dir link inside" "" "$(rp "$R/in/linkdir_in/f.txt")" "$R/in/sub/f.txt"
check "real_path: symlinked ancestor" "" "$(rp "$R/alias/sub/f.txt")" "$R/in/sub/f.txt"
check "real_path: /tmp form of /private/tmp" "" "$(rp "${R#/private}/in/sub/new.txt")" "$R/in/sub/new.txt"
check "real_path: spaces" "" "$(rp "$R/in/has space/a b.txt")" "$R/in/has space/a b.txt"
check "real_path: trailing slash" "" "$(rp "$R/in/sub/")" "$R/in/sub"
check "real_path: leading // and doubled slashes" "T-static-unit-16" "$(rp "/$R//in//sub//f.txt")" "$R/in/sub/f.txt"
# A symlink as the last component must never come back as its own (inside) path: fail, or give the target.
for c in "file link to outside|$R/in/flink|$R/out/t.txt" "relative file link to outside|$R/in/relink|$R/out/t.txt" \
  "dangling link to outside|$R/in/dangling|$R/out/new.txt"; do
  IFS='|' read -r name path target <<<"$c"
  rc=0; got=$(real_path "$path" 2>/dev/null) || rc=$?
  verdict="rc $rc: $got"; { [ "$rc" -ne 0 ] || [ "$got" = "$target" ]; } && verdict=ok
  check "real_path: $name" "F07 T-harness-3 T-static-unit-1 T-live-permissions-5" "$verdict" ok
done

# ere_escape (cage): backslash-escape every ERE metacharacter so the cage profile's DIR-plant regexes match a DIR
# path literally whatever it holds; ordinary characters pass through. Non-metacharacters (/, -, a space, letters) stay.
check "ere_escape: plain path" "cage" "$(ere_escape /home/someone/proj)" "/home/someone/proj"
check "ere_escape: parentheses" "cage" "$(ere_escape '/a/pay(load)/x')" '/a/pay\(load\)/x'
check "ere_escape: plus and dot" "cage" "$(ere_escape '/a/v1.2+b')" '/a/v1\.2\+b'
check "ere_escape: brackets and braces" "cage" "$(ere_escape '/a/[x]{y}')" '/a/\[x\]\{y\}'
check "ere_escape: star question pipe caret dollar" "cage" "$(ere_escape '/a/*?|^$')" '/a/\*\?\|\^\$'
check "ere_escape: backslash" "cage" "$(ere_escape '/a/b\c')" '/a/b\\c'
check "ere_escape: space kept, no escape" "cage" "$(ere_escape '/a/b c-d')" '/a/b c-d'

# sq (cage): single-quote a value for the wrapper's assignment line, which bash reads back unchanged. printf %q on
# bash 3.2 left a "~" after ":" bare, so the line expanded it (a DIR or hooks folder "x:~/y" moved to x:$HOME/y).
for v in "it's" "a''b" 'x:~/y' '/p/d:~' '$(id) `id` & * ? [a] \ \\' "two
lines"; do
  eval "got=$(sq "$v")"; check "sq: round trip [$v]" "cage" "$got" "$v"
done

# names_ok (approve-in): no dot component below DIR, no protected basename. APFS compares names Unicode case-folded
# (ſ is s, the Kelvin sign k, the ligature ﬁ fi), which tr can't do: a basename with a character outside printable
# ASCII is never approved (B4); a folder name with one still is, since no character folds to a leading dot.
for c in "notes.txt|ok" "src/app/main.py|ok" "src/ñandú/notes.txt|ok" "AGENTS.md|no" "sub/claude.md|no" ".envrc|no" \
  "a/.git/config|no" "agentſ.md|no" "lefthooK.yml|no" "bunﬁg.toml|no" "ñandú.txt|no" "tab	name.txt|no"; do
  IFS='|' read -r name want <<<"$c"
  if names_ok "$name"; then got=ok; else got=no; fi
  check "names_ok: $name" "B4" "$got" "$want"
done

# Background work: the count in the agent's status rows ("" for none): the footer below the input box, else the last
# item above it (Claude's turn line, wrapped in a narrow pane; grok's tasks pane). Reply or prompt text never counts.
# Live: live-1-shell-20col and live-shell-ended-20col (claude 2.1.316 at 20x24); claude-1shell-NNcol and -80xN (one
# running shell, the pane resized: 26 columns cut the pill to "· 1", 22 drop it, 10 rows or fewer drop the footer rows,
# and 7 rows cut the box's lower rule, which leaves nothing to read: a documented limit); grok-1task, -working-1task and
# -woken-turn (grok 1.0.70); grok-done, -working and -after-woken (the same run, transcript rows shortened). Synthetic:
# narrow-1-shell-more-footer-rows and live-shell-ended-20col-noresume (from the 20-column capture),
# claude-reply-says-still-running, claude-old-turn-line-then-reply, grok-reply-mentions-tasks.
FX=""; screen_text() { cat "$here/fixtures/bg/$FX.txt"; }
for c in live-idle: live-1-shell:1 live-1-shell-narrow:1 live-shell-ended: live-1-shell-more-footer-rows:1 \
  helper-timeout-line::F08 claude-2shells:2 claude-ran1: claude-ran2-and-1running:1 \
  claude-reply-mentions-2-shell-scripts::"F08 T-static-unit-5" claude-reply-mentions-tasks: \
  claude-1shell-many-footer-rows:1:F08 claude-1shell-bottom-blank-rows:1 claude-11shells-eol:11 claude-v2shell: \
  agy-1task:1 agy-idle: real-layout-reply-mentions-2-shell-scripts::"F08 T-static-unit-5" \
  real-layout-reply-mentions-1-shell::"F08 T-static-unit-5" real-layout-prompt-echo-3-shells::"F08 T-static-unit-5" \
  live-1-shell-20col:1:R08 live-shell-ended-20col::R08 live-shell-ended-20col-noresume::R08 \
  narrow-1-shell-more-footer-rows:1:"R08 T-static-unit-6" claude-reply-says-still-running::"R08 F08" \
  claude-old-turn-line-then-reply::R08 grok-1task:1:R05 grok-working-1task:1:R05 grok-woken-turn::R05 grok-done::R05 \
  grok-after-woken::R05 grok-reply-mentions-tasks::"R05 F08" claude-1shell-26col:1:R08 claude-1shell-22col:1:R08 \
  claude-1shell-16col:1:R08 claude-1shell-80x9:1:R08 claude-1shell-80x7::R08; do
  IFS=: read -r FX want ids <<<"$c"
  rc=0; got=$(background_tasks block:x 2>/dev/null) || rc=$?
  n=$(grep -Eo '[0-9]+' <<<"$got" | head -n 1 || true)
  [ "$rc" -eq 0 ] && [ "${n:-0}" != 0 ] || n=""
  check "background_tasks: $FX" "$ids" "${n:-none}" "${want:-none}"
done

# Dialogs (contract 5): a numbered option list with a selection cursor, or a known dialog phrase, below the last rule
# (on a screen without rules, from the last prompt row down); the transcript and the input box never count. After
# typing (send's second look) only a numbered list counts: agy's completion popup is part of the input. A short pane
# can leave codex's hooks or trust dialog one option (R03): its own option text counts alone. Real captures except
# codex-approval, codex-numbered-echo, codex-composer-phrase, claude-transcript-dialog, codex-hooks-one-option (as
# launch's l55) and codex-typed-numbered.
eval "$(awk 'index($0, "dialog_on_screen() {") == 1 { on = 1 } on { print } on && /^}/ { exit }' "$SCRIPT")"
for c in claude-bash-prompt:yes claude-bash-prompt-wrapped:yes claude-question:yes agy-create-file:yes agy-trust:yes \
  codex-approval:yes agy-working-footer:yes claude-idle:no codex-idle:no grok-idle:no agy-queued-message:no \
  codex-numbered-echo:no codex-composer-phrase:no claude-transcript-dialog:no agy-slash-popup:yes \
  claude-bash-prompt:yes:typed agy-create-file:yes:typed codex-approval:yes:typed agy-slash-popup:no:typed \
  codex-trust-80x6:yes::R03 codex-trust-80x6:yes:typed:R03 codex-hooks-one-option:yes::R03 \
  codex-hooks-one-option:yes:typed:R03 codex-typed-numbered:no:typed codex-typed-numbered:no \
  codex-trust-19x4:yes::T4 codex-trust-19x4:yes:typed:T4 codex-hooks-15x4:yes::T4 codex-hooks-15x4:yes:typed:T4; do
  IFS=: read -r FX want typed ids <<<"$c"
  if ! declare -F dialog_on_screen >/dev/null; then got="no function dialog_on_screen"
  elif dialog_on_screen "$(cat "$here/fixtures/dialog/$FX.txt")" $typed; then got=yes; else got=no; fi
  check "dialog_on_screen: $FX${typed:+ (after typing)}" "${ids:-F02 T-harness-5}" "$got" "$want"
done

# approve-in's dialog check (contract 8) on real captures (claude 2.1.316; agy 1.4.12 in an 80-column pane, which cuts
# its path row): the question or the path row names the file, and the cursor is on a one-time option 1. With CUT the
# file is a cut agy msg's visible prefix; a cut row never confirms a whole path (no "  +N" after it).
eval "$(awk 'index($0, "dialog_for() {") == 1 { on = 1 } on { print } on && /^}/ { exit }' "$SCRIPT")"
AP=/private/tmp/claude-501/-Users-alice/00000000-0000-4000-8000-00000000000
for c in "claude-write-file|claude-code|/x/new.txt||ok" "claude-write-file|claude-code|/x/other.txt||no" \
  "claude-edit-file|claude-code|/x/existing.txt||ok" "claude-write-outside|claude-code|/y/outside.txt||ok" \
  "claude-bash-prompt|claude-code|/x/c.txt||no" "agy-create-file-cut|antigravity|$AP|1|ok" "agy-edit-file-cut|antigravity|$AP|1|ok" \
  "agy-create-file-cut|antigravity|${AP}0/scratc||no" "agy-edit-file-cut|antigravity|/elsewhere/a|1|no"; do
  IFS='|' read -r FX app file cut want <<<"$c"
  if ! declare -F dialog_for >/dev/null; then got="no function dialog_for"
  elif dialog_for "$(cat "$here/fixtures/dialog/$FX.txt")" "$app" "$file" "$cut" >/dev/null; then got=ok; else got=no; fi
  check "dialog_for: $FX ${file##*/}${cut:+ (cut msg)}" "F03 T-harness-4" "$got" "$want"
done

# --- self-repair phase 1 (use-time checks) ---
for f in matches typed_shown dir_named row_names picked one_time overlap mode_pill dialog_region; do
  eval "$(awk -v f="$f() {" 'index($0, f) == 1 { on = 1; one = /}[[:space:]]*$/ } on { print } on && (one || /^}/) { exit }' "$SCRIPT")"
  declare -F "$f" >/dev/null || { echo "FAIL  unit: no function $f in $SCRIPT"; exit 1; }
done
fx() { cat "$here/fixtures/$1.txt"; }

# U2: claude's option 1 must read exactly "Yes" (a synthetic variant of the real write dialog).
alt=$(fx dialog/claude-write-file | sed 's/❯ 1\. Yes$/❯ 1. Yes, allow once/')
if dialog_for "$alt" claude-code /x/new.txt "" >/dev/null; then got=ok; else got=no; fi
check "dialog_for: claude option 1 'Yes, allow once'" U2 "$got" no
check "dialog_for: claude prints the path row" U12 "$(dialog_for "$(fx dialog/claude-write-file)" claude-code /x/new.txt "")" new.txt
check "dialog_for: claude prints the path row, outside DIR" U12 \
  "$(dialog_for "$(fx dialog/claude-write-outside)" claude-code /y/outside.txt "")" ../out/outside.txt

# U12: claude's path row, relative to the launch DIR (../ outside it), absolute, ~/, or with one "…", names the path.
mkdir -p "$R/in/sub" "$R/out"
for c in "new.txt|$R/in/new.txt|ok" "sub/f.txt|$R/in/sub/f.txt|ok" "../out/x.txt|$R/out/x.txt|ok" "x.txt|$R/in/sub/x.txt|no" \
  "$R/in/a.txt|$R/in/a.txt|ok" "sub/../new.txt|$R/in/new.txt|ok" "../in/new.txt|$R/in/new.txt|ok" "|$R/in/a.txt|no" \
  "${R:0:9}…/in/a.txt|$R/in/a.txt|ok" "…/a.txt|$R/in/b.txt|no" "${R:0:9}…a.txt|$R/in/a.txt|no" "a…b…c|$R/in/a.txt|no" \
  "../out/a.txt|$R/in/a.txt|no"; do
  IFS='|' read -r row path want <<<"$c"
  if row_names "$row" "$path" "$R/in"; then got=ok; else got=no; fi
  check "row_names: [$row] for ${path#"$R"/}" "U12 R20" "$got" "$want"
done

# U4: the input box shows the start of the text: typed captures (real ones with the box row edited) and the real idle
# ones, whose transcript echoes the same prompt above an empty box.
CT="Use your Bash tool to run exactly: echo hi. Then reply with only its output."
XT="Run the shell command echo hi, then reply with only its output."
for c in "claude-typed|claude-code|$CT|yes" "claude-typed-wrapped|claude-code|$CT|yes" "claude-idle|claude-code|$CT|no" \
  "codex-typed|codex|$XT|yes" "codex-idle|codex|$XT|no" "grok-typed|grok-build|$XT|yes" "grok-idle|grok-build|$XT|no" \
  "agy-typed|antigravity|Create the file /private/tmp/x/proj/a.txt|yes" "agy-slash-popup|antigravity|/exit|yes" \
  "muse-typed|muse|Create the file /private/tmp/x/proj/a.txt|yes"; do
  IFS='|' read -r FX app text want <<<"$c"
  if typed_shown "$(fx "dialog/$FX")" "$text" "$app"; then got=yes; else got=no; fi
  check "typed_shown: $FX" "U4 R15" "$got" "$want"
done
# Live captures of 2026-11-02 (claude 2.1.316, codex 0.166.0, grok 1.0.70, agy 1.4.12, 80x24 tabs): a wrapped prompt,
# one with quotes and unicode, a 20 KB send -f (claude scrolls to its end, codex draws a placeholder after about 1s,
# agy pushes its upper rule off screen), and a pane that isn't an agent's.
MT="Create the file /private/tmp/rx-probe/codex/t1.txt whose entire content is the string ALPHA-codex (no trailing period, no newline). Then reply OK."
BIG=$(python3 -c "print('Context line, ignore it. ' * 820, end='')")
for c in "codex-typed-wrapped|codex|$MT|yes" "grok-typed-wrapped|grok-build|${MT//codex/grok}|yes" \
  "claude-typed-unicode|claude-code|- Write «x» 'y' \"z\" ñandú \$HOME now|yes" "claude-typed-20kb|claude-code|$BIG|yes" \
  "codex-pasted-20kb|codex|$BIG|yes" "codex-paste-pending|codex|$BIG|no" "agy-typed-20kb|antigravity|$BIG|yes" \
  "claude-idle||$CT|yes" "claude-idle|some-shell|$CT|yes"; do
  IFS='|' read -r FX app text want <<<"$c"
  if typed_shown "$(fx "dialog/$FX")" "$text" "$app"; then got=yes; else got=no; fi
  check "typed_shown: $FX${app:+ as $app}" "U4 R15" "$got" "$want"
done
for FX in agy-ready:antigravity muse-ready:muse; do
  if typed_shown "$(fx "launch/${FX%%:*}")" "Create the file /private/tmp/x/proj/a.txt" "${FX#*:}"; then got=yes; else got=no; fi
  check "typed_shown: ${FX%%:*} (empty box)" "U4 R15" "$got" no
done

# U3: a trust dialog names DIR: real captures, whose DIR is /private/tmp/x/proj unless named here.
A=/private/tmp/claude-501/-Users-alice/00000000-0000-4000-8000-000000000000/scratchpad/audit
for c in "claude-trust|/private/tmp/x/proj|80|yes" "claude-trust|/private/tmp/x|80|no" "claude-trust|/private/tmp/x/proj2|80|no" \
  "grok-trust|/private/tmp/x/proj|80|yes" "grok-trust-80x7|$A/verify-R07-trace/t3-grok-80x7|80|no" \
  "codex-trust|/private/tmp/x/proj|80|yes" "codex-trust-80x6|/private/tmp/x/proj|80|no" \
  "codex-trust-19x30|/private/tmp/h19|19|yes" "codex-trust-19x30|/private/tmp/h20|19|no" \
  "agy-trust|/private/tmp/x/proj|80|yes" "agy-trust-25x30|$A/review-launch/live-agy-1|25|yes" \
  "agy-trust-80x8|$A/verify-R07-trace/t4-agy-80x8|80|yes" "muse-trust|/private/tmp/x/proj|80|yes" \
  "muse-trust-20x30|/private/tmp/claude-501/x|20|yes" "muse-trust-20x30|/private/var/x|20|no" \
  "muse-trust-inline|/private/tmp/rx-dad632ka/muse|80|yes" "muse-trust-inline|/private/tmp/rx-dad632ka|80|no" \
  "claude-trust-80x9|$A/verify-R07-trace/t1-claude-80x9|80|yes" "claude-trust-26x40|$A/verify-R07-trace/t2-claude-26x40|26|yes"; do
  IFS='|' read -r FX dir w want <<<"$c"
  dir_l=$dir
  if dir_named "$(fx "launch/$FX")" "$w"; then got=yes; else got=no; fi
  check "dir_named: $FX names ${dir##*/}" "U3 R7" "$got" "$want"
done
# shellcheck disable=SC2034  # read by the functions taken from the script
dir=/home/u/proj dir_l=/home/u/proj
if HOME=/home/u dir_named " ~/proj" 80; then got=yes; else got=no; fi
check "dir_named: the ~/ form" "U3 R7" "$got" yes

# U5: the option a key picks, and whether it is one-time.
for c in "claude-write-file|enter|Yes|yes" "claude-write-file|3|No|yes" \
  "claude-write-file|2|Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)|no" \
  "codex-approval|enter|Yes, proceed (y)|yes" "codex-approval|2|Yes, and don't ask again for this command in this session (a)|no" \
  "codex-approval|3|No, and tell Codex what to do differently (esc)|yes" "agy-create-file|2|No, deny creation|yes" \
  "agy-trust|enter|Yes, I trust this folder|no"; do
  IFS='|' read -r FX key want once <<<"$c"
  got=$(picked "$(fx "dialog/$FX")" "$key" || echo "(none)")
  check "picked: $key at $FX" U5 "$got" "$want"
  if one_time "$got"; then got=yes; else got=no; fi
  check "one_time: $want" U5 "$got" "$once"
done
for t in "Continue without trusting (hooks won't run)|yes" "Trust and continue|no" "Use this and all future MCP servers|no" \
  "No, exit|yes" "Yes, allow all edits during this session|no" "Yes, and remember this decision|no"; do
  IFS='|' read -r text once <<<"$t"
  if one_time "$text"; then got=yes; else got=no; fi
  check "one_time: $text" U5 "$got" "$once"
done

# U8: claude's mode pill, whole readings only.
check "mode_pill: claude-ready" U8 "$(mode_pill "$(fx launch/claude-ready)")" "⏵⏵ auto mode on"
check "mode_pill: a cut pill" U8 "$(mode_pill "$(printf '%s\n' "──────────" "  ⏵⏵ auto mo")")" ""
check "mode_pill: the transcript doesn't count" U8 "$(mode_pill "$(printf '%s\n' "⏸ plan mode on" "──────────" "❯ ")")" ""

# U10: a caged DIR may not be, hold or sit in what runs or is read uncaged.
# shellcheck disable=SC2034  # read by the functions taken from the script
HOME=$R/home STATE_DIR=$R/home/.local/state/rex-orchestrator SCRIPT_DIR=$R/home/Repos/rx/skills/rex-orchestrator/scripts
CAGE_SECRETS=$R/home/.config/rex-orchestrator/cage-secrets
mkdir -p "$HOME/Repos/p" "$STATE_DIR" "$CAGE_SECRETS"
for c in "/|/" "/Users|/Users" "$HOME|$HOME" "$HOME/Library|$HOME/Library" "$HOME/Repos|$HOME/Repos" \
  "$HOME/.ssh/k|$HOME/.ssh" "$HOME/.config|$CAGE_SECRETS" "$CAGE_SECRETS/x|$CAGE_SECRETS" "$HOME/.claude-work/x|$HOME/.claude*" \
  "$HOME/.codex-alt|$HOME/.codex*" "$STATE_DIR/cage/x|$STATE_DIR" "$HOME/Repos/rx/tests|$HOME/Repos/rx" \
  "/opt/homebrew/bin|/opt/homebrew" "/Applications|/Applications" \
  "$HOME/Repos/p|" "$HOME/Library/Caches/other|" "$HOME/.local/state/other|" "$HOME/.clauderc-like|$HOME/.claude*"; do
  IFS='|' read -r d want <<<"$c"
  got=$(overlap "$d" || true)
  check "overlap: ${d#"$R"/}" "U10 R2" "${got#"$R"/}" "${want#"$R"/}"
done

# Designated orchestrators: account_label names an agent's account by its config dir; orchestrator_check lets launch
# go on only for an ID ORCH_FILE lists (KIND or KIND:ACCOUNT), and for everyone when the file is missing or empty.
for f in account_label orchestrator_check; do
  eval "$(awk -v f="$f() {" 'index($0, f) == 1 { on = 1; one = /}[[:space:]]*$/ } on { print } on && (one || /^}/) { exit }' "$SCRIPT")"
  declare -F "$f" >/dev/null || { echo "FAIL  unit: no function $f in $SCRIPT"; exit 1; }
done
check "account_label: no dir is default" orch "$(account_label claude '')" default
check "account_label: ~/.claude is default" orch "$(account_label claude "$HOME/.claude")" default
check "account_label: ~/.claude-work is work" orch "$(account_label claude "$HOME/.claude-work/")" work
check "account_label: another dir is its name" orch "$(account_label codex /x/team-codex)" team-codex
ORCH_FILE="$R/orchestrators"
oc() { (
  CALLER="$1"
  caller_id() { [ -n "$CALLER" ] && printf '%s' "$CALLER"; }
  orchestrator_check
) >/dev/null 2>&1 && echo ok || echo refused; }
check "orchestrator: no file, anyone" orch "$(oc codex:default)" ok
printf '# no one designated yet\n\n' >"$ORCH_FILE"
check "orchestrator: comments only, anyone" orch "$(oc grok:default)" ok
printf 'claude:default  # the main Claude account\n' >"$ORCH_FILE"
check "orchestrator: exact id allowed" orch "$(oc claude:default)" ok
check "orchestrator: other account refused" orch "$(oc claude:work)" refused
check "orchestrator: other agent refused" orch "$(oc codex:default)" refused
check "orchestrator: unknown caller refused" orch "$(oc '')" refused
printf 'codex\nagy\n' >"$ORCH_FILE"
check "orchestrator: bare kind allows every account" orch "$(oc codex:team)" ok
check "orchestrator: agy entry means gemini" orch "$(oc gemini:default)" ok

