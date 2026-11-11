#!/usr/bin/env bash
# rex-orchestrator: launch and drive coding agents (claude, codex, grok, agy, muse) in Rex panes, from any agent that runs in
# a Rex pane itself. Usage: rex-orchestrator <command> [args]   (see SKILL.md or run with "help")
set -euo pipefail
# An exported CDPATH makes cd resolve a relative DIR elsewhere and print the path it took.
unset CDPATH

REX="${REX_ORCHESTRATOR_REX_BIN_DIR:+$REX_ORCHESTRATOR_REX_BIN_DIR/}rex"
# Some agents strip REX_* and PATH additions from their shells; fall back to the app bundle.
if [ "${1:-}" != clone ] && ! command -v "$REX" >/dev/null 2>&1; then
  for app in "/Applications/Rex Beta.app" "/Applications/Rex.app" "$HOME/Applications/Rex Beta.app" "$HOME/Applications/Rex.app"; do
    REX="$app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    [ -x "$REX" ] && break
    REX=""
  done
  [ -n "$REX" ] || { echo "rex-orchestrator: rex is not on PATH and no Rex app bundle was found; set REX_ORCHESTRATOR_REX_BIN_DIR" >&2; exit 2; }
fi
# One private place per user, whatever TMPDIR a caller has (sandboxed and other shells differ): the pane state, write
# claims, cage homes, harvested transcripts and the kill switches. REX_ORCHESTRATOR_STATE_DIR moves it.
STATE_DIR="${REX_ORCHESTRATOR_STATE_DIR:-}"
[ -n "$STATE_DIR" ] || [ -z "${XDG_STATE_HOME:-${HOME:-}}" ] || STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rex-orchestrator"
# One jq and one git for every call: Homebrew's, else the system's.
JQ=/opt/homebrew/bin/jq; [ -x "$JQ" ] || JQ=/usr/bin/jq
GIT=/opt/homebrew/bin/git; [ -x "$GIT" ] || GIT=/usr/bin/git
jq() { "$JQ" "$@"; }
git() { "$GIT" "$@"; }
# The footer row an agent draws below its input box once it takes a prompt (all but grok draw one at startup); a
# narrow pane shortens codex's to "? for   ⚠ 8 · f2".
READY_RE='for shortcuts|mode on|accept edits on|bypass permissions on|⏵⏵|⏸|^ *\? for( |$)'
TRUST_RE='Yes, I trust this folder'
# agy builds (sha256 of the running binary) whose cut permission msg (98 characters plus "…") wait --approve-in may
# act on. 34423fc9…: agy 1.4.12 (Homebrew cask antigravity-cli 1.4.12). Its msg and its dialog's path row name the
# cleaned path with links resolved (no "." or ".." left, a dir link shows its target), so a visible prefix inside DIR
# is the start of the real path. Add a build only after checking it the same way.
AGY_VERIFIED_SHA256="34423fc9b0af3841e7646aa72a2d40ffeab8218b22d1cb99eac7355f9eba31e3"
# Cage (sandbox-exec) assets; REX_ORCHESTRATOR_CAGE_* override them. SCRIPT_DIR is where this script (and cage.sb, cage/)
# live, resolved through any install symlink. claude needs a $CAGE_SECRETS/claude-<name>.env per account
# (claude_account picks one), and agy an agy home with its login, $CAGE_SECRETS/agy-home
# (REX_ORCHESTRATOR_CAGE_AGY_HOME names another).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
CAGE_PROFILE="${REX_ORCHESTRATOR_CAGE_PROFILE:-$SCRIPT_DIR/cage.sb}"
CAGE_TPL="${REX_ORCHESTRATOR_CAGE_TPL:-$SCRIPT_DIR/cage}"
CAGE_SECRETS="${REX_ORCHESTRATOR_CAGE_SECRETS:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/rex-orchestrator/cage-secrets}"
CAGE_AGY_HOME="${REX_ORCHESTRATOR_CAGE_AGY_HOME:-$CAGE_SECRETS/agy-home}"
# Designated orchestrators: the IDs (KIND or KIND:ACCOUNT, one per line, # comments) of the agents allowed to launch
# children. A missing or empty file lets every agent orchestrate. A policy, not a security boundary: an agent that
# can write the file can change it.
ORCH_FILE="${REX_ORCHESTRATOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/rex-orchestrator}/orchestrators"
# The default for launch's --cage/--no-cage: auto (cage every agent that has a cage recipe), on (fail for one that has
# none) or off.
CAGE_DEFAULT="${REX_ORCHESTRATOR_CAGE:-auto}"

die() { printf 'rex-orchestrator: %s\n' "$*" >&2; exit 2; }
fail() { printf 'rex-orchestrator: %s\n' "$*" >&2; exit 1; }
note() { printf 'rex-orchestrator: %s\n' "$*" >&2; }

# Whether a kill switch is set (killed [AGENT]): STATE_DIR/disabled, or STATE_DIR/disabled.AGENT. A dangling link
# counts.
killed() { [ -e "$STATE_DIR/disabled${1:+.$1}" ] || [ -L "$STATE_DIR/disabled${1:+.$1}" ]; }

# Set AGENT's kill switch (kill_switch AGENT WHY) and say so in red.
kill_switch() {
  (umask 077 && mkdir -p "$STATE_DIR" && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >>"$STATE_DIR/disabled.$1") ||
    note "could not write $STATE_DIR/disabled.$1"
  printf '\033[31mrex-orchestrator: stopped: %s; %s/disabled.%s is set: report it, never remove it yourself\033[0m\n' \
    "$2" "$STATE_DIR" "$1" >&2
}

# An option's value must follow it (optval "$@" in an option loop): a missing or empty one is a usage error, not
# "unbound" (and bash 3.2's cd "" stays in $PWD, which would scope --approve-in "" to it).
optval() { [ -n "${2:-}" ] || die "$1 needs a value"; }

# Whole seconds in a duration N, Ns, Nm or Nh (secs OPTION VALUE); anything else is a usage error. Call it as
# x=$(secs …) || exit 2, because die in the subshell only ends that.
secs() {
  local n="$2" u=1
  case "$n" in *s) n=${n%s} ;; *m) n=${n%m} u=60 ;; *h) n=${n%h} u=3600 ;; esac
  case "$n" in '' | *[!0-9]*) die "$1 takes a duration such as 90, 90s, 10m or 1h, not '$2'" ;; esac
  echo $((10#$n * u))
}

usage() {
  cat <<'EOF'
Drive coding agents (claude, codex, grok, Gemini/agy, muse) in Rex panes from an agent that runs in a Rex pane itself.

rex-orchestrator launch [-d DIR] [-l LABEL] [--split right|left|above|below] [--ratio PCT] [-b ANCHOR] [--tab NAME]
                     [--trust] [--focus] [--timeout DUR] [--agent CMD] [--kind KIND] [--cage|--no-cage]
                     [--account NAME] [--allow-edits] [--allow RULE]... [-- AGENT_ARGS...]
    Open a pane running the agent (default claude) in DIR (default: the current directory), labelled LABEL (default
    claude), and wait until it is ready for a prompt: no dialog on screen, a status that isn't working, and its
    footer below the input box or an idle status. Prints the block ID on stdout, also on exits 3, 12 and 124, where
    the pane stays open for you to read or close; interrupted or failing before that, launch closes the pane.
    Placement: a split of ANCHOR taking PCT percent of it (default 50; Rex's "autobalance splits" overrides it), or a
    new tab NAME with --tab (unfocused, 80x24). With neither -b nor --split, ANCHOR is the largest pane of your own
    window, split along its longer side, so all agents stay in one view.
    --trust answers the folder trust dialog with "Yes", only once the dialog names DIR (grok: only its exact
    "Yes, proceed y" / "No, quit n" form); without it launch stops there with exit 3.
    --agent CMD runs another agent or a wrapper script, the one your PATH finds. KIND (claude, codex, grok, gemini or
    muse; gemini is the agy CLI) picks its dialog handling, by default from CMD's name (claude-* and agy-* wrappers
    count as claude and gemini).
    Only a designated orchestrator may launch: when ORCH_FILE lists IDs (KIND or KIND:ACCOUNT), a caller not listed
    exits 2. ACCOUNT is named after the agent's config dir (~/.claude is default, ~/.claude-work is work).
    An uncaged child gets your CLAUDE_CONFIG_DIR and CODEX_HOME (on its command line, so paths only), a claude child
    also CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1, and nothing else of your environment; it runs on whatever account
    CMD uses.
    Cage: by default (REX_ORCHESTRATOR_CAGE=auto) an agent with a cage recipe runs under sandbox-exec (cage.sb): writes
    only to DIR and a throwaway config home, no reads of the secret stores and agent homes cage.sb lists, web ports
    only. codex and grok always have a recipe (they re-open only their login file: codex the auth.json of your
    CODEX_HOME or ~/.codex, grok ~/.grok/auth.json); claude once a credential file CAGE_SECRETS/claude-NAME.env
    (export CLAUDE_CODE_OAUTH_TOKEN=...) exists; agy once its cage home CAGE_SECRETS/agy-home holds a login. A caged
    child runs from the cage's own config templates, not your settings: pass a model and other settings after --.
    --account NAME picks claude-NAME.env (a caged claude only); without it the only credential is used, else the
    alphabetically first, and launch says which. --no-cage (or REX_ORCHESTRATOR_CAGE=off) runs uncaged; --cage (or
    REX_ORCHESTRATOR_CAGE=on) fails (exit 2) for an agent with no recipe. An agent that should be caged but can't be
    (missing profile, template or login) fails closed (exit 2), never uncaged. A caged DIR may not be, hold or sit in
    what runs or is read outside the cage (the state and cage-secrets folders, ~/.ssh, ~/.local/bin, ~/.agents,
    ~/Library/LaunchAgents, this tool's folder, /opt/homebrew, /Applications, every ~/.claude*, ~/.codex*, ~/.grok*,
    ~/.gemini*; nor be /, /Users, ~, ~/Library or ~/Repos).
    An uncaged claude never runs in bypass mode: --dangerously-skip-permissions,
    --allow-dangerously-skip-permissions, --permission-mode bypassPermissions or a "bypass permissions on" footer
    exit 2. claude only: --allow-edits lets the child read and edit inside DIR without asking (refused for a DIR
    whose path holds [ ] * ? { } ! ) or \); --allow adds a permission rule such as 'Bash(npm test:*)'. Both last
    for that session only and can't be combined with -- --settings.
    Exit: 0 ready; 1 rex error; 2 usage or refused (no CMD on your PATH, a cage that can't be built, a refused
    --account or DIR, a kill switch, bypass mode, a pane too small to show the trust dialog's options); 3 a dialog
    left for the user (trust without --trust or not naming DIR, a hooks review, another startup dialog; or --trust
    made the agent trust an ancestor of DIR, which sets its kill switch); 12 the agent exited during startup; 124 not
    ready after --timeout (default 90s).
rex-orchestrator clone REPO DEST [-b BRANCH]
    Make a standalone APFS copy-on-write checkout (git clone --local fallback); DEST must not exist. Prints DEST.
rex-orchestrator claims [--json]
    List live write claims (one launch per checkout), pruning dead pids and missing Rex blocks.
rex-orchestrator send [--force] BLOCK TEXT...   Type a prompt (newlines become spaces) and press Return.
rex-orchestrator send [--force] BLOCK -f FILE   Same, reading the prompt from FILE.
    A prompt that starts with "/" runs a slash command. One whose first non-blank character is "!" is refused (the
    agents run it as a shell command without asking). For claude, so is one that starts with a digit (its session
    survey would take it as a rating), and for an uncaged claude /permissions, /allowed-tools, /config, /settings,
    /add-dir, /hooks, /plugin, /mcp or a prefix of one. The Return goes only once the input box shows the text. An
    uncaged claude pane whose permission mode changed since launch is stopped.
    Exit: 0 sent, 1 rex error, 2 usage or refused (also a stopped pane), 4 not ready for input (working, a dialog, or
    the text typed but not shown: then it is typed but not submitted), 12 the agent exited.
rex-orchestrator wait [--force] BLOCK [--timeout DUR] [--ignore-background] [--bg-max DUR] [--approve-in DIR]
    Wait until the agent finishes the turn started by the last send/keys; prints the state. A turn that ends with more
    background work than at the send is held until that work finishes (at most --bg-max, default 300s), as counted in
    the agent's own status rows; --ignore-background ends it at once. codex reports working until its background
    terminals exit. --timeout defaults to 600s. A Claude Code prompt still up 10s after send/keys with no new report
    exits 10.
    --approve-in answers "Yes" once to a claude or agy file write/edit prompt for a plain file inside DIR, when the
    dialog on screen asks about that file with its one-time "1. Yes" selected. Links, hard links, dot files and dot
    folders, CLAUDE.md/AGENTS.md/GEMINI.md, a name with a non-ASCII character and every other prompt still exit 10;
    DIR can't be /, /Users, $HOME, ~/Library or ~/Repos. One approver per pane. A caged block's prompts go to the
    user: there it waits like a plain wait. An uncaged claude whose permission mode changes stops the pane (prints
    "stopped", exit 10); right after an approval it also sets disabled.claude.
    Exit: 0 done/idle, 10 blocked or stopped (needs the user), 11 error, 12 the agent exited, 124 timeout.
rex-orchestrator status BLOCK               One-line JSON: state, kind, msg, title, alive, cwd (and account, for a caged
                                            claude).
rex-orchestrator screen BLOCK [LINES]       The visible screen, last LINES lines (default 60).
rex-orchestrator keys [--force] BLOCK KEY...   Press keys (e.g. enter, down, escape, ctrl+c).
    At a dialog on an uncaged pane (a question excepted) only escape, ctrl+c, up and down pass, and enter or a digit
    alone in its call when the option it picks is a one-time Yes, No or Continue (never "always", "don't ask again",
    a session-wide grant or a folder trust). shift+tab is refused for claude. A stopped pane takes escape and ctrl+c.
    Exit: 0 pressed, 1 rex error, 2 usage or refused, 12 the agent exited.
rex-orchestrator ls                         Live agent panes in this Rex session, one per line: BLOCK, a tab, then the
                                            status JSON with label and mine (launched from your pane) added.
rex-orchestrator close [--force] BLOCK      Close the pane (ends its agent) and remove its state and cage home, also for a
                                            pane already closed in Rex given by its full ID. When rex can't close the pane
                                            the state stays (exit 1): run close again.

DUR is N, Ns, Nm or Nh. BLOCK is any form rex takes (full ID, short ID, label). The state is the agent's own (root)
status record. Any agent running in a Rex pane can be the orchestrator: launch, send, keys, close and wait
--approve-in need REX_SESSION and REX_BLOCK (set in every Rex pane; outside one, prefix the call with
REX_SESSION=... REX_BLOCK=...). send, keys, close and wait --approve-in act only on panes launched from your pane,
unless --force (only for a pane the user named).
Kill switches: a file STATE_DIR/disabled stops every launch, and every send and key but escape and ctrl+c;
STATE_DIR/disabled.AGENT stops AGENT's uncaged launches, approvals and typing into its uncaged panes (exit 2).
Anyone may set one; only the user removes one.
Environment:
  REX_ORCHESTRATOR_STATE_DIR      STATE_DIR (default ${XDG_STATE_HOME:-~/.local/state}/rex-orchestrator; mode 700, a link or a
                            directory that isn't yours is refused)
  REX_ORCHESTRATOR_CAGE_SECRETS   CAGE_SECRETS (default ${XDG_CONFIG_HOME:-~/.config}/rex-orchestrator/cage-secrets)
  REX_ORCHESTRATOR_CAGE           launch's cage default: auto (default), on or off
  REX_ORCHESTRATOR_CAGE_PROFILE, REX_ORCHESTRATOR_CAGE_TPL, REX_ORCHESTRATOR_CAGE_AGY_HOME   other cage assets
  REX_ORCHESTRATOR_REX_BIN_DIR    the folder holding the rex CLI, if it isn't on PATH
  REX_ORCHESTRATOR_CONFIG_DIR     the folder of ORCH_FILE, "orchestrators" (default
                                  ${XDG_CONFIG_HOME:-~/.config}/rex-orchestrator)
EOF
}

[ -x "$JQ" ] || die "jq is required ($JQ)"
# clone and claims need no caller session; claims carry their holders' sessions.
case "${1:-help}" in help | -h | --help) usage; exit 0 ;; esac
[ -n "${REX_SESSION:-}" ] || [ "${1:-}" = clone ] || [ "${1:-}" = claims ] || die "REX_SESSION is not set; run inside a Rex terminal (check with: rex whoami --json)"

# grep -q on a string (matches TEXT GREP_ARGS...). A here-string, because under pipefail `printf | grep -q` is false
# when grep exits at an early match of a long text and the writer dies of SIGPIPE.
matches() { local t="$1"; shift; grep -q "$@" <<<"$t"; }

# Create the state directory (700), and refuse one that is a link or not the user's: its files steer wait.
state_dir() {
  [ -n "$STATE_DIR" ] || die "no state dir: set HOME or REX_ORCHESTRATOR_STATE_DIR"
  [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ] || (umask 077 && mkdir -p "$STATE_DIR") 2>/dev/null || true
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] && [ -O "$STATE_DIR" ] ||
    die "refusing state dir $STATE_DIR: a link, not a directory, or not yours (REX_ORCHESTRATOR_STATE_DIR picks another)"
}

# Every registry access uses the same kernel lock; never unlink its inode.
registry_lock() {
  mkdir -p "$STATE_DIR/registry"
  exec 9>>"$STATE_DIR/registry.lock"
  /usr/bin/perl -e 'use Fcntl qw(:flock); open(my $f, ">&=", 9) or exit 1; flock($f, LOCK_EX) or exit 1' || fail "cannot lock write claims"
}
registry_unlock() { exec 9>&-; }
registry_prune() {
  local f p b sess rc
  for f in "$STATE_DIR/registry/"*.json; do
    [ -f "$f" ] || continue
    p=$(jq -er '.pid | tostring | select(test("^[1-9][0-9]*$"))' "$f") || fail "invalid claim: $f"
    if ! kill -0 "$p" 2>/dev/null; then rm -f "$f"; continue; fi
    b=$(jq -er '.block' "$f"); sess=$(jq -er '.session' "$f")
    rc=0; "$REX" block inspect -s "$sess" "$b" --json >/dev/null 2>&1 || rc=$?
    case "$rc" in 0) ;; 3) rm -f "$f" ;; *) fail "cannot check write claim for $b in $sess" ;; esac
  done
}
claim_identity() {
  local top="" common="" branch=""
  if top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    top=$(cd "$top" && pwd -P)
    common=$(git -C "$dir" rev-parse --git-common-dir)
    case "$common" in /*) ;; *) common="$dir/$common" ;; esac
    common=$(cd "$common" && pwd -P)
    branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || branch=""
  fi
  identity=$(jq -nc --arg dir "$dir" --arg given "$dir_given" --arg top "$top" --arg common "$common" --arg branch "$branch" '
    {dir:$given,canonical_dir:$dir,toplevel:$top,common_dir:$common,branch:$branch,
     key:(if $top == "" then [$dir] else [$top,$common,$branch] end)}')
}
registry_check() {
  local f holder
  registry_prune
  for f in "$STATE_DIR/registry/"*.json; do
    [ -f "$f" ] || continue
    if jq -e --argjson n "$identity" '
      def contains_path($a;$b): $a == $b or ($b | startswith(($a | rtrimstr("/")) + "/"));
      (.toplevel != "" and $n.toplevel != "" and
        (.toplevel == $n.toplevel or (.common_dir == $n.common_dir and .branch != "" and .branch == $n.branch))) or
      ((.toplevel == "" or $n.toplevel == "") and
        (contains_path(.canonical_dir;$n.canonical_dir) or contains_path($n.canonical_dir;.canonical_dir)))' "$f" >/dev/null; then
      holder=$(jq -r '"label \(.label), block \(.block), session \(.session)"' "$f")
      die "launch: DIR already has a live write claim ($holder); use rex-orchestrator clone for a separate checkout"
    fi
  done
}
registry_add() {
  local f="$STATE_DIR/registry/${block//[^A-Za-z0-9_-]/_}.json"
  case "$pid" in '' | *[!0-9]* | 0) fail "launch: cannot record agent pid for $block" ;; esac
  # shellcheck disable=SC2015  # fail when either step fails
  jq -nc --argjson identity "$identity" --arg block "$block" --arg session "$REX_SESSION" \
    --arg kind "$kind" --argjson pid "$pid" --arg label "$label" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$identity + {block:$block,session:$session,kind:$kind,pid:$pid,label:$label,created:$created}' >"$f.tmp$$" &&
    mv -f "$f.tmp$$" "$f" || fail "cannot write claim for $block"
}
registry_remove() {
  registry_lock
  rm -f "$STATE_DIR/registry/${1//[^A-Za-z0-9_-]/_}.json"
  registry_unlock
}
cmd_claims() {
  [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --json ]; } || die "claims: expected [--json]"
  registry_lock
  registry_prune
  local f
  for f in "$STATE_DIR/registry/"*.json; do
    [ -f "$f" ] || continue
    if [ "${1:-}" = --json ]; then jq -c . "$f"; else
      jq -r '[.block,.label,.session,.kind,(.pid|tostring),.canonical_dir] | @tsv' "$f"
    fi
  done
  registry_unlock
}
cmd_clone() {
  [ $# -ge 2 ] || die "clone: expected REPO DEST [-b BRANCH]"
  local repo="$1" dest="$2" branch=""; shift 2
  if [ $# -gt 0 ]; then
    [ $# -eq 2 ] && [ "$1" = -b ] && [ -n "$2" ] || die "clone: expected REPO DEST [-b BRANCH]"
    branch=$2
  fi
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || die "clone: DEST already exists: $dest"
  repo=$(cd "$repo" 2>/dev/null && pwd -P) || die "clone: no such REPO: $repo"
  [ -d "$repo/.git" ] || die "clone: REPO must have its own .git directory"
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || die "clone: not a git repository: $repo"
  if ! cp -c -R "$repo" "$dest" 2>/dev/null; then
    note "clone: cp -c failed; falling back to git clone --local"
    rm -rf -- "$dest"
    git clone --local -- "$repo" "$dest" >&2 || { rm -rf -- "$dest"; fail "clone failed"; }
  fi
  if [ -n "$branch" ]; then
    git -C "$dest" switch -c "$branch" >&2 || { rm -rf -- "$dest"; fail "clone: cannot create branch $branch"; }
  fi
  printf '%s\n' "$dest"
}

# A pane's state files, keyed by its canonical ID (block:<uuid> -> block_<uuid>): the mark (line 1 the root record's
# updated_at at the last send/keys, line 2 the background work then), .hold (a held turn: record, start, end of
# work), .own (from launch: line 1 the launcher's block, 2 the agent's pid, 3 its root record's owner pid, 4 its kind,
# 5 its DIR, 6 an uncaged claude's pinned permission mode, 7 the agent binary launch resolved), .cage (a caged pane: line 1 its cage home's leaf name, 2 a
# caged claude's account) and .stopped (a pane the mode pin stopped: why).
state_file() { printf '%s/%s' "$STATE_DIR" "${1//[^A-Za-z0-9_-]/_}"; }

# Line N of a pane's state file (state_line BLOCK SUFFIX N), or nothing: state_line "$block" own 2 is the agent pid.
state_line() { local f; f="$(state_file "$1")${2:+.$2}"; [ ! -f "$f" ] || sed -n "${3}p" "$f"; }

# Replace a state file with these lines atomically (put FILE LINE...): a concurrent reader sees the old or the new file.
put() { local f="$1"; shift; printf '%s\n' "$@" >"$f.tmp$$" && mv -f "$f.tmp$$" "$f"; }

# A block method's JSON object (rex_call BLOCK METHOD), retried briefly: a failed or unparsable read is unknown (rc 1),
# never data. rc 3 is rex's "no such block", not retried.
rex_call() {
  local out rc n=0
  while :; do
    rc=0; out=$("$REX" block call -s "$REX_SESSION" -b "$1" "$2" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then printf '%s\n' "$out"; return 0; fi
    [ "$rc" -ne 3 ] || return 3
    [ $((n += 1)) -lt 3 ] || return 1
    sleep 0.2
  done
}

# The canonical ID (block:<uuid>) of a BLOCK argument in any form rex takes: full ID, bare UUID, ID suffix or label.
# rc 3: no such block in this session, or an ambiguous label (rex says which); rc 1: rex did not answer.
resolve() {
  local out rc n=0
  # An empty or option-like BLOCK would let inspect fall back to REX_BLOCK or the focused block.
  case "$1" in '' | -*) return 3 ;; esac
  while :; do
    rc=0; out=$("$REX" block inspect -s "$REX_SESSION" "$1" --json) || rc=$?
    if [ "$rc" -eq 0 ] && out=$(jq -er '.block.block_id | strings | select(startswith("block:"))' <<<"$out" 2>/dev/null); then
      printf '%s\n' "$out"; return 0
    fi
    [ "$rc" -ne 3 ] || return 3
    [ $((n += 1)) -lt 3 ] || return 1
    sleep 0.2
  done
}

# Resolve a BLOCK argument into $block (canonical) and refuse the caller's own pane, whatever form of its ID was given.
# With "gone" (wait, close), a full block: ID rex no longer knows is kept: a pane closed since.
target() {
  local rc=0
  [ -n "${1:-}" ] || die "missing BLOCK"
  block=$(resolve "$1") || rc=$?
  case "$rc,${2:-},$1" in
    0,*) ;;
    3,gone,block:*) block=$1 ;;
    3,*) die "no such block in this session: $1" ;;
    *) fail "rex did not answer for block $1" ;;
  esac
  [ "$block" != "$me" ] || die "refusing to target your own pane ($1)"
}

# Whether block ls, read successfully, no longer lists BLOCK (gone BLOCK).
gone() { "$REX" block ls -s "$REX_SESSION" --json 2>/dev/null | jq -e --arg b "$1" '.blocks | all(.block_id != $b)' >/dev/null 2>&1; }

# Close a pane (close_block BLOCK): rc 0 once rex closed it or says it is gone (its "not found" is rc 3, or block ls no
# longer lists it), 1 while it may still be open. A failed close is tried once more.
close_block() {
  local rc n=0
  while :; do
    rc=0; "$REX" block close -s "$REX_SESSION" "$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in 0 | 3) return 0 ;; esac
    [ $((n += 1)) -lt 2 ] || break
    sleep 0.3
  done
  gone "$1"
}

# The block of the pane launch opened under its launch label (tagged TAG): a split's block label, a tab's window name.
tagged() {
  "$REX" block inspect -s "$REX_SESSION" "$1" --json 2>/dev/null |
    jq -er '.block.block_id | strings | select(startswith("block:"))' 2>/dev/null ||
    "$REX" window inspect -s "$REX_SESSION" "$1" --json 2>/dev/null |
    jq -er '[.. | .block_id? | strings] | unique | select(length == 1) | .[0]' 2>/dev/null
}

# Commands that act on a pane must know the caller's own one.
need_me() { [ -n "$me" ] || die "REX_BLOCK is not set: run inside a Rex pane, or prefix the call with REX_SESSION=… REX_BLOCK=…"; }

# send, keys, close and wait --approve-in drive only panes launched from this pane, unless --force (a pane the user named).
owned() {
  [ "$force" -eq 1 ] || { [ -n "$me" ] && [ "$(state_line "$block" own 1)" = "$me" ]; } ||
    die "$1: $block was not launched from this pane; pass --force only for a pane the user named"
}

# The visible screen, retried briefly; fails when rex can't capture it (unknown, not an empty screen).
screen_text() {
  local out n=0
  until out=$("$REX" capture -s "$REX_SESSION" -b "$1" --trim --unwrap 2>/dev/null); do
    [ $((n += 1)) -lt 3 ] || return 1
    sleep 0.2
  done
  printf '%s\n' "$out"
}

# Whether a screen shows a dialog: a numbered option list with a selection cursor, or a known dialog phrase, in the
# rows below the last horizontal rule, or on a screen without rules (codex) from the last prompt or cursor row down.
# The transcript above never counts, nor, for phrases, a prompt row's own text (codex's composer draft). With "typed"
# (send's look once its text is in the composer) only the numbered list counts: a typed slash command opens the
# agent's own completion popup there (agy: "/exit  Exit the CLI", "esc to cancel"), which is part of the input. A pane
# of a few rows can leave codex's hooks review or trust dialog one selected option and no title: that option's own
# text (its row joined with the next, which a narrow pane wraps it onto) counts alone.
dialog_on_screen() {
  awk -v typed="${2:-}" -v phrases='esc to cancel|enter to (select|confirm)|enter confirm|do you want to|would you like to|hooks? needs? review|do you trust|trust this folder' \
    -v options='review hooks|trust all and continue|continue without trusting|trust and continue' '
    index($0, "──────────") { n = 0; r = 1; m = 0; next }
    !r && /^[[:space:]]*(❯|›|>)/ { n = 0; m = 1 }
    { l[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        if (l[i] ~ /^[[:space:]]*(❯|›|>|⟩)[[:space:]]*[0-9]+\./) {
          c = 1; t = tolower(l[i] " " l[i + 1]); gsub(/[[:space:]]+/, " ", t)
          if (t ~ "[0-9]+\\. (" options ")") k = 1
        } else if (l[i] ~ /^[[:space:]]*[0-9]+\./) o = 1
        if (i > m && tolower(l[i]) ~ phrases) p = 1
      }
      exit !(c && o || k || p && typed == "")
    }' <<<"$1"
}

# A screen's dialog region: the rows below its last horizontal rule (Claude Code draws its dialogs and its input box
# under one), or all of a screen without rules, so a transcript quoting a dialog above the input box never counts.
# shortcut: codex draws no rules, so a resumed codex transcript can still quote a trust question; a sharper region
# would need codex's composer row.
dialog_region() { awk 'index($0, "──────────") { n = 0; next } { l[++n] = $0 } END { for (i = 1; i <= n; i++) print l[i] }' <<<"$1"; }

# The agent's state: its root record (no id), the newest whose app is set. Records with an id (sub-agents, background
# tasks) never decide, nor, once launch has stored the agent's owner pid, records reported under another pid. Prints {}
# when there is none; fails (rc 1) when program_status can't be read or parsed. codex, grok-build, antigravity and
# muse report too.
root_record() {
  local out
  out=$(rex_call "$1" program_status) || return 1
  jq -c --arg o "$(state_line "$1" own 3)" '[.records[]? | select(.id == null and (.effective_app // .app) != null)
    | select($o == "" or (.owner.pid | tostring) == $o)] | sort_by(.updated_at) | last // {}' <<<"$out"
}

# Background work in the agent's own status rows, never its transcript: the footer rows below its input box (under the
# box's lower rule, or under the prompt row on a screen without rules: Claude Code's "N shell(s)", agy's "N task(s)"),
# else the last item above the box's upper rule: Claude's turn line ("✻ … · N shells still running", all a narrow or
# short pane keeps; only it starts with "✻" in column 0, where a reply starts with "⏺" and a prompt with "❯") or
# grok's tasks pane ("▾ Tasks N"). Rows a narrow pane wrapped are joined first. Prints the match ("2 shells"); rc 1 for
# none, 2 when the screen can't be read (unknown).
background_tasks() {
  local s; s=$(screen_text "$1") || return 2
  awk '{ l[NR] = $0 }
    index($0, "──────────") { u = w; w = NR; next }
    !w && /^[[:space:]]*(❯|>)/ { p = NR }
    END {
      if (w || p) for (i = (w ? w : p) + 1; i <= NR; i++) f = f " " l[i]
      # A newer item (a row that starts in column 0) after the turn line leaves none; its wrapped rows are indented.
      for (i = 1; i < u; i++)
        if (l[i] ~ /^✻/) { t = l[i]; j = 1 }
        else if (l[i] ~ /^[^[:space:]]/) t = j = ""
        else if (l[i] !~ /[^[:space:]]/) j = ""
        else if (j) t = t " " l[i]
      # grok: the block of rows right above its box, headed "▾ Tasks N" while tasks run.
      for (i = u - 1; i > 0 && l[i] !~ /[^[:space:]]/; i--) ;
      for (; i > 0 && l[i] ~ /[^[:space:]]/; i--) g = l[i]
      gsub(/[[:space:]]+/, " ", f); gsub(/[[:space:]]+/, " ", t); f = f " "
      if (match(f, /[^[:alnum:]][0-9]+ (shells?|task\(s\))[^[:alnum:]]/)) c = substr(f, RSTART + 1, RLENGTH - 2)
      else if (match(t, /· [0-9]+ shells? still running/) && match(c = substr(t, RSTART, RLENGTH), /[0-9]+ shells?/))
        c = substr(c, RSTART, RLENGTH)
      else if (g ~ /^[[:space:]]*▾ Tasks [0-9]+[[:space:]]*$/) { c = g; gsub(/[^0-9]/, "", c); c = c " task(s)" }
      else exit 1
      print c
    }' <<<"$s"
}

# Whether the agent is gone, on evidence only: a read shows it exited or no child, block ls no longer lists the block,
# or the pane's child is not the agent launch recorded (a restarted Rex server reopens the block as a shell).
# rc 0 gone, 1 running, 2 unknown (rex could not tell).
exited() {
  local p
  if p=$(rex_call "$1" process); then
    jq -e --arg w "$(state_line "$1" own 2)" '.last_exit != null or .child == null or
      ($w != "" and (.child.pid | tostring) != $w)' <<<"$p" >/dev/null && return 0
    return 1
  fi
  gone "$1" && return 0
  return 2
}

# send and keys stop at an agent that is gone (12) or a pane rex can't read (1).
alive_or_exit() {
  local ex=0
  exited "$block" || ex=$?
  case "$ex" in 0) note "$1: the agent in $block has exited"; exit 12 ;; 2) fail "$1: cannot read $block's process; nothing was sent" ;; esac
}

# Remember the root record's timestamp (REC, or read now), so wait ignores reports from before this point, and the
# background work already running (a dev server), so wait holds a turn only for work started after it. Fails, writing
# nothing, when the status or the screen can't be read: a guessed baseline lets wait take the previous turn's done.
mark() {
  local rec="${2:-}" bg rc=0 sf
  [ -n "$rec" ] || rec=$(root_record "$1") || return 1
  bg=$(background_tasks "$1") || rc=$?
  [ "$rc" -ne 2 ] || return 1
  sf=$(state_file "$1")
  put "$sf" "$(jq -r '.updated_at // ""' <<<"$rec")" "$bg" || return 1
  rm -f "$sf.hold"
}

# Move only the report baseline (line 1 of the mark) to REC's timestamp (mark_since BLOCK REC): keys, and send once
# its text is typed. The background baseline and a carried hold stay the last send's. With no mark yet, a full mark.
mark_since() {
  local sf; sf=$(state_file "$1")
  [ -f "$sf" ] || { mark "$1" "$2"; return; }
  put "$sf" "$(jq -r '.updated_at // ""' <<<"$2")" "$(sed -n 2p "$sf")"
}

# TEXT with its rows joined and runs of spaces squeezed: a question or option the agent wrapped onto several rows (a
# narrow pane) reads as one phrase again.
squeeze() { tr -s ' \n' '  ' <<<"$1"; }

# The agent in $block (pane_kind [REC]): claude, codex, grok, agy or muse, as launch recorded it, else from REC's app.
pane_kind() {
  local k r="${1:-}"
  k=$(state_line "$block" own 4)
  [ -n "$k" ] || case "$(jq -r '.effective_app // .app // ""' <<<"${r:-null}" 2>/dev/null)" in
    claude-code) k=claude ;; antigravity) k=agy ;; grok-build) k=grok ;; codex) k=codex ;; muse) k=muse ;;
  esac
  printf '%s' "$k"
}

# The account an agent runs on, named after its config dir (account_label KIND DIR): no dir or the agent's own
# default (~/.claude for claude) is "default", ~/.claude-work is "work", any other dir its name without a leading dot.
account_label() {
  local d="${2%/}" b
  [ -n "$d" ] || { printf 'default'; return; }
  b=${d##*/}; b=${b#.}
  case "$b" in "$1") printf 'default' ;; "$1"-?*) printf '%s' "${b#"$1"-}" ;; *) printf '%s' "$b" ;; esac
}

# KIND:ACCOUNT of the agent running in the caller's pane: KIND from the app Rex sees reporting there (agy reports as
# antigravity and is named gemini), else claude when Claude Code's own variable is set; ACCOUNT from that agent's
# config dir variable. rc 1 when the agent can't be told.
caller_id() {
  local app k=""
  app=$(root_record "$me" 2>/dev/null | jq -r '.effective_app // .app // ""' 2>/dev/null) || app=""
  case "$app" in
    claude-code) k=claude ;; codex) k=codex ;; grok-build) k=grok ;; antigravity) k=gemini ;; muse) k=muse ;;
    *) [ -z "${CLAUDECODE:-}" ] || k=claude ;;
  esac
  [ -n "$k" ] || return 1
  case "$k" in
    claude) printf '%s:%s' "$k" "$(account_label claude "${CLAUDE_CONFIG_DIR:-}")" ;;
    codex) printf '%s:%s' "$k" "$(account_label codex "${CODEX_HOME:-}")" ;;
    *) printf '%s:default' "$k" ;;
  esac
}

# Refuse launch (exit 2) unless the caller is a designated orchestrator: an ORCH_FILE entry equal to its KIND:ACCOUNT
# or to its KIND alone ("agy" counts as "gemini"). No entries: every agent may orchestrate.
orchestrator_check() {
  local list="" shown id e
  [ ! -f "$ORCH_FILE" ] ||
    list=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e 's/^agy$/gemini/' -e 's/^agy:/gemini:/' "$ORCH_FILE" | grep -v '^$' || true)
  [ -n "$list" ] || return 0
  shown=$(tr '\n' ' ' <<<"$list"); shown=${shown% }
  id=$(caller_id) || die "launch: can't tell which agent runs in your pane, and only $shown may orchestrate ($ORCH_FILE)"
  while IFS= read -r e; do
    if [ "$e" = "$id" ] || [ "$e" = "${id%%:*}" ]; then return 0; fi
  done <<<"$list"
  die "launch: $id is not a designated orchestrator; only $shown may launch children ($ORCH_FILE)"
}

# Replace line N of $block's .own with VALUE (own_set N VALUE), keeping the other six.
own_set() {
  local f i l=(); f="$(state_file "$block").own"
  for i in 1 2 3 4 5 6 7; do l+=("$(sed -n "${i}p" "$f" 2>/dev/null)"); done
  l[$1 - 1]=$2
  put "$f" "${l[@]}"
}

# Claude's permission mode on a screen (mode_pill SCREEN), from its footer below the last rule: "⏵⏵ auto mode on",
# "⏸ manual mode on", "⏵⏵ accept edits on", "⏵⏵ bypass permissions on", … A pill the pane cut prints nothing.
mode_pill() { { LC_ALL=C grep -oE '(⏵⏵|⏸) [a-z][a-z ]* on( |$)' <<<"$(dialog_region "$1")" || true; } | tail -n 1 | sed 's/ $//'; }

# The mode pin: an uncaged claude keeps the permission mode launch saw at ready (pin_ok SCREEN REC). rc 1, with
# the change in $pin_why, when a whole reading on SCREEN differs; a cut reading is never compared, and the first whole
# one pins the mode when launch saw none. A pane launch didn't record has no pin.
pin_ok() {
  local sf pin now; sf=$(state_file "$block")
  [ -f "$sf.own" ] && [ ! -f "$sf.cage" ] && [ "$(pane_kind "${2:-}")" = claude ] || return 0
  now=$(mode_pill "$1"); [ -n "$now" ] || return 0
  pin=$(state_line "$block" own 6)
  if [ -z "$pin" ]; then own_set 6 "$now" || true; return 0; fi
  [ "$now" != "$pin" ] || return 0
  pin_why="the permission mode changed from '$pin' to '$now'"
  return 1
}

# Stop $block for good (stop_pane WHY): no more presses, sends or keys but escape and ctrl+c.
stop_pane() { put "$(state_file "$block").stopped" "$1" || true; note "stopped: $1; report it"; }

# Why $block is stopped, or nothing.
stopped() { state_line "$block" stopped 1; }

# Whether a trust dialog's REGION names DIR (dir_named REGION WIDTH; launch's $dir and $dir_l), in one of its forms:
# physical, logical or ~/: a row (or consecutive rows, which a narrow pane wraps it onto) equal to one, after a label
# such as "Workspace:" or not, a row cut at the pane's right edge (WIDTH) whose visible part starts one, or a row with
# one "…" whose parts start and end one, its last component whole. LC_ALL=C: bytes, with UTF-8 continuation
# bytes not counted as columns.
dir_named() {
  local h hp; h=${HOME:-/nonexistent}; hp=$(cd "$h" 2>/dev/null && pwd -P) || hp=$h
  LC_ALL=C D1="$dir" D2="${dir_l:-$dir}" H1="$h" H2="$hp" W="${2:-0}" awk '
    function form_add(f, h) { form[++nf] = f; h = ENVIRON["H1"]; if (index(f, h "/") == 1) form[++nf] = "~" substr(f, length(h) + 1)
      h = ENVIRON["H2"]; if (index(f, h "/") == 1) form[++nf] = "~" substr(f, length(h) + 1) }
    function cols(s, t) { t = s; gsub(/[\200-\277]/, "", t); return length(t) }
    function hit(t, i, f, k, p, s, u) {
      # A label before it on the same row ("Workspace: DIR", muse 1.4 at 80 columns) is not part of it.
      u = t; sub(/^[A-Za-z][A-Za-z ]*:[[:space:]]+/, "", u)
      for (i = 1; i <= nf; i++) {
        f = form[i]
        if (t == f || u == f) return 1
        if (k = index(t, "…")) {
          p = substr(t, 1, k - 1); s = substr(t, k + 3)
          if (p != "" && s ~ /\// && !index(s, "…") && length(p) + length(s) < length(f) &&
            substr(f, 1, length(p)) == p && substr(f, length(f) - length(s) + 1) == s) return 1
        }
      }
      return 0
    }
    BEGIN { form_add(ENVIRON["D1"]); if (ENVIRON["D2"] != ENVIRON["D1"]) form_add(ENVIRON["D2"]) }
    { raw[++n] = $0; t = $0; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t); row[n] = t }
    END {
      for (i = 1; i <= n; i++) {
        if (row[i] == "") continue
        if (hit(row[i])) exit 0
        if (ENVIRON["W"] > 0 && cols(raw[i]) >= ENVIRON["W"] && row[i] ~ /^(\/|~\/)/)
          for (k = 1; k <= nf; k++) if (index(form[k], row[i]) == 1) exit 0
        j = row[i]
        for (k = i + 1; k <= n && row[k] != ""; k++) { j = j row[k]; if (hit(j)) exit 0 }
      }
      exit 1
    }' <<<"$1"
}

# launch's DIR check at a trust dialog: dir_named on its $region, the pane's width read once (cmd_launch's locals).
trust_dir_named() {
  if [ "$cols" -eq 0 ]; then
    cols=$(rex_call "$block" size | jq -r '.columns // 0' 2>/dev/null) || cols=0
    case "$cols" in '' | *[!0-9]*) cols=0 ;; esac
  fi
  dir_named "$region" "$cols"
}

# Before launch's first trust press in an uncaged pane, note which of DIR's ancestors are trusted already, for the
# check at ready that the press trusted none of them. A caged press needs none: the trust lands in the throwaway home.
trust_snapshot() {
  [ -z "$cage_tmp" ] || return 0
  [ "$snap" -eq 1 ] || { pre=$(trusted_above "$kind" pre); snap=1; }
}

# Whether grok's trust dialog is its exact two-option form: "Yes, proceed … y" and "No, quit … n".
grok_two_options() {
  matches "$1" -E '^[[:space:]]*Yes, proceed[[:space:]]+y[[:space:]]*$' &&
    matches "$1" -E '^[[:space:]]*No, quit[[:space:]]+n[[:space:]]*$'
}

# The folders KIND's own trust store marks trusted (trusted_in KIND [pre]), one per line, read as data: claude's
# ${CLAUDE_CONFIG_DIR:-~}/.claude.json .projects[].hasTrustDialogAccepted, codex's ${CODEX_HOME:-~/.codex}/config.toml
# [projects."…"] trust_level, grok's ~/.grok/trusted_folders.toml [folders."…"] trusted, agy's trustedWorkspaces in
# ~/.gemini/antigravity-cli/settings.json, muse's ~/.config/muse/trust.json .projects[].decision. With "pre", a claude
# child on another config dir also gets ~/.claude.json's entries: a wrapper may copy them at every start.
# shortcut: a TOML key with an escaped quote is skipped; read the TOML with a parser if a path ever holds one.
trusted_in() {
  local h="${HOME:-/nonexistent}" f=()
  toml_trusted() {
    awk -v sec="$2" -v want="$3" '
      /^\[/ { cur = ""; if (index($0, "[" sec ".\"") == 1 && $0 ~ /"\][[:space:]]*$/ && $0 !~ /\\"/) {
          cur = substr($0, length(sec) + 4); sub(/"\][[:space:]]*$/, "", cur) } next }
      cur != "" { l = $0; gsub(/[[:space:]]/, "", l); if (l == want) print cur }' "$1"
  }
  case "$1" in
    claude)
      f=("${CLAUDE_CONFIG_DIR:-$h}/.claude.json")
      [ -z "${2:-}" ] || [ -z "${CLAUDE_CONFIG_DIR:-}" ] || f+=("$h/.claude.json")
      jq -r '.projects // {} | to_entries[] | select(.value.hasTrustDialogAccepted == true) | .key' "${f[@]}" ;;
    codex) toml_trusted "${CODEX_HOME:-$h/.codex}/config.toml" projects 'trust_level="trusted"' ;;
    grok) toml_trusted "$h/.grok/trusted_folders.toml" folders 'trusted=true' ;;
    agy) jq -r '.trustedWorkspaces[]? | strings' "$h/.gemini/antigravity-cli/settings.json" ;;
    muse) jq -r '.projects // {} | to_entries[] | select(.value.decision == "trusted") | .key' "$h/.config/muse/trust.json" ;;
  esac 2>/dev/null || true
}

# The ancestors of DIR (up to /, of its physical and logical forms) that KIND's trust store marks trusted
# (trusted_above KIND [pre]), one per line. For codex DIR's git root counts as DIR, as codex trusts the root.
trusted_above() {
  local p t top=""
  [ "$1" != codex ] || top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
  t=$(trusted_in "$1" "${2:-}")
  for p in "$dir" "${dir_l:-$dir}"; do
    while [ "$p" != / ] && [ -n "$p" ]; do
      p=$(dirname "$p")
      if [ "$p" != "$top" ] && grep -qxF -- "$p" <<<"$t"; then printf '%s\n' "$p"; fi
    done
  done | sort -u
}

# Whether the agent's input box on SCREEN shows TEXT (typed_shown SCREEN TEXT APP):
# claude's, agy's and muse's box is the rows between the last two rules, grok's the "│ … │" rows of its last "╭ … ╰"
# box, codex's its last row that starts with "›" and the indented rows that wrap it. The box must hold the first or
# the last 20 printable ASCII characters of the text (claude scrolls a long one to its end) or a paste placeholder
# (codex's "[Pasted Content N chars]", claude's "[Pasted text …]"). Only a box found empty of all that is a no: with
# no box found (an unknown agent, a pane too short, a long text that pushes the upper rule off screen) it says yes, so
# it never refuses a send it can't check.
# shortcut: a text with no ASCII at all always passes; compare characters if such prompts ever matter.
typed_shown() {
  local box head tail t="$2"
  case "$3" in claude-code | antigravity | muse | grok-build | codex) ;; *) return 0 ;; esac
  box=$(awk -v app="$3" '
    { l[++n] = $0 }
    app != "grok-build" && index($0, "──────────") { r1 = r2; r2 = n }
    /^[[:space:]]*╭/ { gt = n } /^[[:space:]]*╰/ { gb = n } /^[[:space:]]*›/ { c = n }
    END {
      if (app == "grok-build") { if (gt && gb > gt) for (i = gt + 1; i < gb; i++) { t = l[i]; gsub(/│/, "", t); print t } else exit 1 }
      else if (app == "codex") { if (c) { print l[c]; for (i = c + 1; i <= n && l[i] ~ /^[[:space:]]+[^[:space:]]/; i++) print l[i] } else exit 1 }
      else if (r1) for (i = r1 + 1; i < r2; i++) print l[i]
      else exit 1
    }' <<<"$1") || return 0
  # Printable ASCII only on both sides (a text that isn't UTF-8 shows as U+FFFD), and slices first, as stripping is
  # quadratic in bash 3.2 on a long prompt.
  head=$(printf '%s' "${2:0:400}" | LC_ALL=C tr -cd '!-~' | LC_ALL=C cut -c1-20)
  [ ${#t} -le 400 ] || t=${t: -400}
  tail=$(printf '%s' "$t" | LC_ALL=C tr -cd '!-~' | LC_ALL=C rev | LC_ALL=C cut -c1-20 | LC_ALL=C rev)
  box=$(LC_ALL=C tr -cd '!-~' <<<"$box")
  [[ $box == *"$head"* ]] || [[ $box == *"$tail"* ]] || [[ $box == *"[PastedContent"* ]] || [[ $box == *"[Pastedtext"* ]]
}

# The option KEY would pick at the dialog on SCREEN (picked SCREEN KEY), from the rows below the last rule: for enter
# the selected row (the last one with a cursor), for a digit N option N, a numbered one's wrapped rows joined. rc 1:
# none.
picked() {
  awk -v k="$2" '
    index($0, "──────────") { n = 0; next }
    { l[++n] = $0 }
    END {
      for (i = 1; i <= n; i++)
        if (k == "enter") { if (l[i] ~ /^[[:space:]]*(❯|>|›|⟩)[[:space:]]*[^[:space:]]/) hit = i }
        else if (l[i] ~ "^[[:space:]]*((❯|>|›|⟩)[[:space:]]*)?" k "[.)]?[[:space:]]") hit = i
      if (!hit) exit 1
      t = l[hit]; num = sub(/^[[:space:]]*((❯|>|›|⟩)[[:space:]]*)?[0-9]+[.)]?[[:space:]]+/, "", t)
      if (!num) sub(/^[[:space:]]*(❯|>|›|⟩)[[:space:]]*/, "", t)
      # Only a numbered option wraps onto indented rows; in an unnumbered menu the next row is the next option.
      for (j = hit + 1; num && j <= n && l[j] ~ /^[[:space:]]+[^[:space:]]/ &&
           l[j] !~ /^[[:space:]]*((❯|>|›|⟩)[[:space:]]*)?[0-9]+[.)]?[[:space:]]/; j++) {
        u = l[j]; sub(/^[[:space:]]+/, "", u); t = t " " u
      }
      print t
    }' <<<"$1"
}

# Whether an option's text is a one-time answer (one_time TEXT): it starts with Yes, No or Continue and holds none of
# dialog_for's persist words, nor a folder or hooks trust, which is remembered ("Continue without trusting" is not).
one_time() {
  LC_ALL=C awk -v t="$1" 'BEGIN { t = tolower(t)
    exit !(t ~ /^(yes|no|continue)([^a-z]|$)/ &&
      t !~ /always|don[^ ]*t ask|ask again|persist|remember|session|conversation|all edits|auto mode|accept edits|bypass/ &&
      (t !~ /trust/ || t ~ /without trust/)) }'
}

# Whether the agent in $block takes its first prompt now (launch's reading of $text, $region and $rec): no dialog, a
# root record that isn't working or blocked, and its footer below the input box or an idle or done record (grok
# draws no footer row at startup). codex counts only once it reports, and only with its composer's footer in view:
# it draws its composer before its folder and hooks dialogs, reports nothing while they are up, and none of them
# draws that footer (a short pane can cut their titles and options). Agents that never report (older Claude Code):
# the footer alone.
launch_ready() {
  local st
  ! dialog_on_screen "$text" && [ -n "$rec" ] || return 1
  st=$(jq -r '.state // ""' <<<"$rec")
  case "$st" in
    '') [ "$kind" != codex ] || return 1 ;;
    blocked) return 1 ;;
    # codex reports working from its start until its first turn ends: only its working line means a turn runs.
    working) [ "$kind" = codex ] && ! matches "$text" -i 'esc to interrupt' || return 1 ;;
  esac
  { [ "$kind" != codex ] && { [ "$st" = idle ] || [ "$st" = "done" ]; }; } || matches "$region" -E "$READY_RE"
}

# Whether launch's reading shows a folder trust dialog, from its rows joined ($flat): Claude's own option, or its
# title above "No, exit" (in fewer than 10 rows its menu shows only the selected option); the other agents' question,
# their trusting option (codex's title is the first row a short pane cuts), or a root record blocked on the question
# (grok and agy report "Trust this folder?").
trust_shown() {
  if [ "$kind" = claude ]; then matches "$flat" -E "$TRUST_RE|Accessing workspace.*No, exit"; else
    matches "$flat" -Ei 'do you trust|trust this (folder|workspace)\?|1\.? trust and continue' ||
      jq -e '.state == "blocked" and (.msg // "" | test("trust"; "i"))' <<<"$rec" >/dev/null 2>&1
  fi
}

# Sets anchor and split (globals of cmd_launch) to the largest pane of your own window, split along its longer side
# (a cell is about twice as tall as wide). Leaves both unset when rex can't list or size the panes.
roomiest() {
  local win b sz best=0 c r
  win=$("$REX" block ls -s "$REX_SESSION" --json 2>/dev/null |
    jq -r --arg me "$me" '.blocks[] | select(.block_id == $me) | .window_id // empty') && [ -n "$win" ] || return 0
  for b in $("$REX" block ls -s "$REX_SESSION" -w "$win" -q --short=false 2>/dev/null); do
    sz=$(rex_call "$b" size 2>/dev/null | jq -r '"\(.columns | numbers) \(.rows | numbers)"' 2>/dev/null) || continue
    read -r c r <<<"$sz"; [ -n "$r" ] || continue
    if [ $((c * r)) -gt "$best" ]; then
      best=$((c * r)) anchor=$b
      if [ "$c" -ge $((2 * r)) ]; then split=right; else split=below; fi
    fi
  done
}

# Exit 2 (the EXIT trap closes the pane) when launch's pane is smaller than 80x24, the size the agents lay out their
# startup dialogs for (too_small WHAT): agy and muse cut the rows or columns that don't fit. A size rex can't read
# lets launch go on.
too_small() {
  local s
  s=$(rex_call "$block" size | jq -r 'select((.columns | numbers) < 80 or (.rows | numbers) < 24) | "\(.columns)x\(.rows)"') &&
    [ -n "$s" ] || return 0
  die "launch: $1 in the ${s} pane, which cuts it. Relaunch in a bigger pane (another -b or --split), or close idle panes; --tab (80x24) hides it from your view"
}

# launch's EXIT trap: a pane launch opened but never reported (a signal, errexit or a refusal) is closed with its state,
# and the cage home it built (CAGING) is removed, so nothing is left running or lying around unseen. A pane rex made but
# whose ID it never printed (rex died mid-call) is found by its launch label (TAG). A pane rex can't close keeps what
# close needs: its ownership and its cage home.
unlaunch() {
  # A second signal must not cut this short (bash would quit inside the trap): finish it whatever arrives.
  trap '' HUP INT TERM
  registry_unlock
  local n sf
  # Rex can make the pane a moment after its CLI died: look again for a second.
  for n in 1 2 3; do
    [ -z "${LAUNCHED:-}" ] && [ -n "${TAG:-}" ] || break
    LAUNCHED=$(tagged "$TAG") || { LAUNCHED=""; sleep 0.3; }
  done
  if [ -n "${LAUNCHED:-}" ]; then
    sf=$(state_file "$LAUNCHED")
    if close_block "$LAUNCHED"; then
      rm -rf "$sf" "$sf".*
      note "launch stopped before the agent was ready; closed $LAUNCHED"
    else
      [ -f "$sf.own" ] || put "$sf.own" "$me" "" "" || true
      [ -z "${CAGING:-}" ] || [ -f "$sf.cage" ] || put "$sf.cage" "${CAGING##*/}" || true
      CAGING=""
      note "launch stopped before the agent was ready and could not close $LAUNCHED; run close $LAUNCHED"
    fi
    registry_remove "$LAUNCHED"
  fi
  [ -z "${CAGING:-}" ] || rmcage "$CAGING" || note "could not remove $CAGING"
}

# Delete a throwaway cage home (rmcage DIR). A caged child, or a tool it ran (Go's module cache is read-only), can leave
# what rm -rf can't remove: folders without the owner's rwx, the uchg or uappnd flag, an ACL that denies the owner.
# Clear them, nested ones too (find fixes each folder before it reads it); chflags, chmod, find and rm follow no link
# inside, and the cage can't link a file from outside in. The agent may still be writing as it exits: retry once.
rmcage() {
  local n=0
  # Restore access to sealed transcript directories before reading them.
  { chflags -R nouchg,nouappnd "$1"; chmod -R -N "$1"; chmod -R u+rwX "$1"; } 2>/dev/null || true
  # Measurement never prevents cleanup, including when Python/storage fails.
  python3 -I "${SCRIPT_DIR:-${SDIR:-.}}/harvest.py" "$1" "${STATE_DIR:-${1%/cage/*}}" ||
    note "harvest failed for $1; continuing removal; storage failure may prevent a manifest"
  until { chflags -R nouchg,nouappnd "$1"; chmod -R -N "$1"; chmod -R u+rwX "$1"; rm -rf "$1"; } 2>/dev/null; do
    [ $((n += 1)) -lt 2 ] || { rm -rf "$1"; return; }
    find "$1" -type d -exec chflags nouchg,nouappnd {} \; -exec chmod -N {} \; -exec chmod u+rwx {} \; 2>/dev/null
    sleep 1
  done
}

# End launch with exit RC, the block ID on stdout and the pane left open for the caller, who closes it and its cage
# home (report RC).
report() { printf '%s\n' "$block"; LAUNCHED="" CAGING=""; exit "$1"; }

# $1 with every ERE metacharacter backslash-escaped, for the cage profile's DIR-plant regex rules (-D DIR_RE). seatbelt
# uses the regex as-is, so an unescaped ( ) + etc. in DIR would turn those locks off (they'd match nothing or wrongly).
ere_escape() { printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'; }

# $1 single-quoted for a bash script line. Not printf %q: bash 3.2 leaves a "~" after ":" bare, and an assignment
# expands it, so a hooks folder or DIR named like "x:~/y" would be locked or allowed at another path.
sq() { local q="'" e="'\\''"; printf "'%s'" "${1//$q/$e}"; }

# Write the per-launch cage wrapper for agent $1 to stdout: real binary $2, DIR $3, escaped DIR $4 (DIR_RE), cage temp
# $5, real home $6, AGENT_AUTH $7, AGENT_CFG_RO $8, HOOKSPATH $9, LOCK_RE ${10}, CAGE_SECRETS (physical) ${11}; for claude, CRED is its account's
# (cage_acct) claude-<acct>.env. Named like the agent so launch's dialog logic keys on it. The wrapper runs OUTSIDE the
# cage, so every value is single-quoted: a quote or $(...) in a path stays data. env -i drops REX_*, SSH_AUTH_SOCK and
# tokens; only the agent's own isolated config/home/temp and (codex/grok) its one auth file come through. set -e: a
# failed seeding step stops the agent from starting.
cage_emit() {
  local name="$1" agyset
  # agy's session --settings replace its settings file, so carry over only the cage home's chosen model (a string).
  agyset=$(jq -c '{allowNonWorkspaceAccess: false, permissions: {allow: []}} + (if (.model | type) == "string" then
    {model: .model} else {} end)' "$CAGE_AGY_HOME/.gemini/antigravity-cli/settings.json" 2>/dev/null) ||
    agyset='{"allowNonWorkspaceAccess":false,"permissions":{"allow":[]}}'
  printf '#!/bin/bash\n# rex-orchestrator cage wrapper for %s (generated each launch; do not edit).\nset -e\n' "$name"
  printf 'REAL=%s DIR=%s DRE=%s CT=%s RH=%s AUTH=%s CFGRO=%s HOOKS=%s LRE=%s SEC=%s PROF=%s TPL=%s CRED=%s RH_AGY=%s AGYSET=%s\n' \
    "$(sq "$2")" "$(sq "$3")" "$(sq "$4")" "$(sq "$5")" "$(sq "$6")" "$(sq "$7")" "$(sq "$8")" "$(sq "$9")" "$(sq "${10}")" "$(sq "${11}")" \
    "$(sq "$CAGE_PROFILE")" "$(sq "$CAGE_TPL")" "$(sq "${cage_acct:+$CAGE_SECRETS/claude-$cage_acct.env}")" \
    "$(sq "$CAGE_AGY_HOME")" "$(sq "$agyset")"
  # The one terminal the cage lets the child write to: this pane's own pty (the wrapper's stdin), looked up at run
  # time. Without one, an unused path in the cage home: no pty is writable then.
  # shellcheck disable=SC2016  # expanded by the wrapper at run time
  printf '%s\n' 'TTY=$(/usr/bin/tty 2>/dev/null) || TTY=' 'case "$TTY" in /dev/ttys[0-9]*) ;; *) TTY="$CT/.notty" ;; esac'
  # The rest is literal (quoted heredocs): $CT, $TERM and $@ expand in the wrapper at run time.
  case "$name" in
    codex) cat <<'EOF'
mkdir -p "$CT/codex-home" "$CT/tmpdir"
ln -sf "$AUTH" "$CT/codex-home/auth.json"
[ -f "$CT/codex-home/config.toml" ] || cp "$TPL/codex.toml" "$CT/codex-home/config.toml"
exec /usr/bin/env -i HOME="$RH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" \
  CODEX_HOME="$CT/codex-home" TMPDIR="$CT/tmpdir/" \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --dangerously-bypass-approvals-and-sandbox --no-daemon "$@"
EOF
      ;;
    grok) cat <<'EOF'
mkdir -p "$CT/home/.grok"
[ -f "$CT/home/.grok/config.toml" ] || cp "$TPL/grok.toml" "$CT/home/.grok/config.toml"
exec /usr/bin/env -i HOME="$CT/home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" \
  GROK_HOME="$CT/home/.grok" GROK_AUTH_PATH="$AUTH" TMPDIR="$CT/" \
  GROK_DISABLE_AUTOUPDATER=1 GROK_AUTH_EARLY_INVALIDATION_SECS=0 \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --always-approve "$@"
EOF
      ;;
    # Cage settings go in the isolated user settings.json (write-locked), not in a --settings flag: a second
    # --settings (launch --allow, or the caller's own) replaces the first. The env var keeps connectors off anyway.
    # CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1: claude strips its own credentials (the OAuth token) from the env of the
    # shells, hooks and MCP servers it starts, so a command the model runs cannot print or send the token.
    claude) cat <<'EOF'
mkdir -p "$CT/claude-config" "$CT/zdot"
[ -f "$CT/claude-config/.claude.json" ] || cp "$TPL/claude.json" "$CT/claude-config/.claude.json"
[ -f "$CT/claude-config/settings.json" ] || cp "$TPL/claude-settings.json" "$CT/claude-config/settings.json"
# CLAUDE_CODE_OAUTH_TOKEN for the child only, from its account's file (outside the cage), loaded silently: a malformed
# line would print itself, the token, on the child's screen.
. "$CRED" >/dev/null 2>&1 && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ||
  { echo "rex-orchestrator cage: $CRED sets no CLAUDE_CODE_OAUTH_TOKEN (its content is not shown)" >&2; exit 1; }
exec /usr/bin/env -i HOME="$RH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh ZDOTDIR="$CT/zdot" \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" \
  CLAUDE_CONFIG_DIR="$CT/claude-config" CLAUDE_CODE_TMPDIR="$CT" TMPDIR="$CT/" DISABLE_AUTOUPDATER=1 \
  ENABLE_CLAUDEAI_MCP_SERVERS=false CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
  CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --dangerously-skip-permissions --strict-mcp-config --no-chrome "$@"
EOF
      ;;
    # --settings is session-only for agy: no persisted allow rules, no access outside the workspace.
    agy | agy-*) cat <<'EOF'
mkdir -p "$CT/home"
# A one-time provisioned agy login (CAGE_AGY_HOME) is copied in so it is writable in the cage.
[ -n "$RH_AGY" ] && [ -d "$RH_AGY" ] || exit 70
[ -d "$CT/home/.gemini" ] || cp -R "$RH_AGY/." "$CT/home/"
exec /usr/bin/env -i HOME="$CT/home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" TMPDIR="$CT/" \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --dangerously-skip-permissions --mode auto \
    --settings "$AGYSET" "$@"
EOF
      ;;
  esac
}

# Whether $1 names a cage account: lowercase ASCII letters and digits only (it lands in a file name and in notes).
acct_ok() { case "$1" in '' | *[!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;; esac; }

# The account a caged claude runs on (sets cage_acct and cage_why): launch's --account (checked there), else the only
# $CAGE_SECRETS/claude-<name>.env, else the alphabetically first. rc 1: none, so claude has no cage recipe.
claude_account() {
  local f a accts=()
  if [ -n "${account:-}" ]; then cage_acct=$account cage_why="chosen with --account"; return 0; fi
  for f in "$CAGE_SECRETS"/claude-*.env; do
    a=${f##*/}; a=${a#claude-}; a=${a%.env}
    if acct_ok "$a" && [ -f "$f" ] && [ -r "$f" ]; then accts+=("$a"); fi
  done
  case ${#accts[@]} in
    0) return 1 ;;
    1) cage_acct=${accts[0]} cage_why="its only cage credential" ;;
    *) cage_acct=${accts[0]} cage_why="the alphabetically first of ${#accts[@]} cage credentials (--account picks another)" ;;
  esac
}

# Set up a cage for agent $1 (real binary $2, already resolved on the caller's PATH; DIR $3, a physical path). rc 0:
# caged (sets globals cage_wrapper and cage_tmp, and for claude cage_acct and cage_why). rc 1: NO cage recipe for $1
# (caller runs it uncaged). rc 2: a recipe exists but setup failed, so launch must fail closed (never a silent uncaged
# fallback); the note says why.
cage_build() {
  local name="$1" real="$2" dir="$3" rh auth="" cfgro=.nolock tpl="" t base ct hooks="" dre adir hp top rp lre="" sec
  cage_acct="" cage_why=""
  # Recipe? codex/grok always; claude with a cage credential (an account); agy with a provisioned home; nothing else.
  case "$name" in
    codex) auth="${CODEX_HOME:-${HOME:-}/.codex}/auth.json"; cfgro=codex-home/config.toml; tpl=codex.toml ;;
    grok)  auth="${HOME:-}/.grok/auth.json"; tpl=grok.toml ;;
    claude) claude_account || return 1; cfgro=claude-config/settings.json; tpl="claude.json claude-settings.json" ;;
    agy)   [ -d "$CAGE_AGY_HOME" ] || return 1 ;;
    # agy-<name> (a wrapper for another agy account): caged from $CAGE_SECRETS/agy-<name>, running the real agy.
    agy-*) case "${name#agy-}" in '' | *[!a-z0-9]*) return 1 ;; esac
           [ -d "$CAGE_SECRETS/$name" ] && real=$(command -v agy) || return 1
           CAGE_AGY_HOME="$CAGE_SECRETS/$name" ;;
    *) return 1 ;;
  esac
  # From here $name has a recipe, so every failure is fail-closed (rc 2), never a silent uncaged fallback.
  # seatbelt matches physical paths: a -D path through a symlink (/var, /tmp) or with "//" never matches.
  rh=$(cd "${HOME:-/nonexistent}" && pwd -P) || { note "cage: cannot resolve HOME"; return 2; }
  # AGENT_AUTH is the one real-home credential re-opened in-cage (physical). The caller's CODEX_HOME picks codex's.
  if [ -n "$auth" ]; then
    adir=$(cd "$(dirname "$auth")" 2>/dev/null && pwd -P) || { note "cage: no $name login dir for $auth"; return 2; }
    auth="$adir/${auth##*/}"
    [ -r "$auth" ] || { note "cage: no $name login at $auth"; return 2; }
  fi
  for t in $tpl; do [ -r "$CAGE_TPL/$t" ] || { note "cage: missing template $CAGE_TPL/$t"; return 2; }; done
  [ -r "$CAGE_PROFILE" ] || { note "cage: profile not found: $CAGE_PROFILE (set REX_ORCHESTRATOR_CAGE_PROFILE)"; return 2; }
  # The DIR-plant regexes are built from DIR; a control char in it can't be expressed in a regex (decision 4).
  case "$dir" in *[[:cntrl:]]*) note "cage: $name's DIR path has a control character; use a plain folder name or --no-cage"; return 2 ;; esac
  dre=$(ere_escape "$dir")
  # LOCK_RE (cage.sb): what runs or is sourced outside the cage, write-locked even inside DIR: the cage secrets (the
  # claude wrapper sources claude-<name>.env), the state dir (kill switches, other panes' state) and this skill's folder
  # (the script, its profile and templates, SKILL.md). Each as given and as resolved, as seatbelt sees resolved paths
  # and the given form keeps a DIR that holds a link from swapping it.
  for t in "$CAGE_SECRETS" "${SCRIPT_DIR:+${SCRIPT_DIR%/*}}"; do
    [ -n "$t" ] || continue
    lre="$lre|$(ere_escape "$t")"
    rp=$(cd "$t" 2>/dev/null && pwd -P) || rp=$(real_path "$t") || continue
    [ "$rp" = "$t" ] || lre="$lre|$(ere_escape "$rp")"
  done
  lre="^(${lre#|})(/|\$)"
  # The cage secrets, read-denied by cage.sb wherever REX_ORCHESTRATOR_CAGE_SECRETS puts them (physical, as seatbelt matches).
  sec=$(cd "$CAGE_SECRETS" 2>/dev/null && pwd -P) || sec=$(real_path "$CAGE_SECRETS") ||
    { note "cage: cannot resolve $CAGE_SECRETS"; return 2; }
  # A repo's custom core.hooksPath that resolves inside DIR is write-locked too (read uncaged, read-only). git expands a
  # leading "~/" (--path) and takes a relative one from the worktree's top, which can be above DIR; the folder needn't
  # exist yet, or can be a dangling link a caged child would replace: then its parent's physical path is used.
  if command -v git >/dev/null 2>&1 && top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    hp=$(git -C "$dir" config --path --get core.hooksPath 2>/dev/null) || hp=""
    if [ -n "$hp" ]; then
      case "$hp" in /*) ;; *) hp="$top/$hp" ;; esac
      hp=$(printf '%s' "$hp" | tr -s /); case "$hp" in ?*/) hp=${hp%/} ;; esac
      rp=$(cd "$hp" 2>/dev/null && pwd -P) || { rp=$(real_path "$(dirname "$hp")") && rp="${rp%/}/${hp##*/}"; } || rp=""
      case "${rp:+$rp/}" in "$dir"/*) hooks="$rp"; note "cage: repo core.hooksPath points inside DIR ($rp); write-locking it" ;; esac
    fi
  fi
  # mktemp -d: a private (0700), unpredictable dir under STATE_DIR/cage; it holds the agent's isolated home.
  if ! { mkdir -p "$STATE_DIR/cage" && base=$(cd "$STATE_DIR/cage" && pwd -P) && [ -O "$base" ] &&
         ct=$(mktemp -d "$base/$name.XXXXXX") && mkdir "$ct/bin" &&
         cage_emit "$name" "$real" "$dir" "$dre" "$ct" "$rh" "${auth:-$ct}" "$ct/$cfgro" "${hooks:-$ct/.nohooks}" "$lre" "$sec" \
           >"$ct/bin/$name" &&
         chmod +x "$ct/bin/$name"; }; then
    note "cage: cannot set up a cage under $STATE_DIR/cage"; return 2
  fi
  # A caged codex can't save a folder-trust answer (config.toml is write-locked), so its dialog loops. With --trust
  # (cmd_launch's local), trust exactly DIR in this throwaway config. jq's JSON string is a valid TOML basic string,
  # so dots, spaces and quotes in the path are safe; codex -c splits keys on dots, so don't use that instead.
  if [ "$name" = codex ] && [ "${trust:-0}" -eq 1 ]; then
    { mkdir -p "$ct/codex-home" && cp "$CAGE_TPL/codex.toml" "$ct/codex-home/config.toml" &&
      printf '\n[projects.%s]\ntrust_level = "trusted"\n' "$(jq -n --arg d "$dir" '$d')" >>"$ct/codex-home/config.toml"; } ||
      note "cage: could not pre-trust $dir; codex will show its trust dialog"
  fi
  jq -n --arg kind "$name" --arg account "${cage_acct:-unknown}" --arg label "${label:-$name}" \
    --arg dir "$dir" --arg start "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{kind:$kind, account:$account, label:$label, DIR:$dir, start_time:$start, block:"unknown"}' >"$ct/run-meta.json" ||
    note "could not write cage run metadata"
  cage_wrapper="$ct/bin/$name"; cage_tmp="$ct"
}

# What a caged child's DIR must never overlap (overlap DIR, a physical path; prints the first hit, rc 1 for none): it
# is, holds or sits in what runs or is read outside the cage. The state folders and the cage credentials
# (the wrapper sources them, the kill switches live there), ssh, the bins and skills every session runs, launchd's
# agents, the root of the copy of this tool that runs, Homebrew and the apps, every agent home by prefix; and the
# folders so broad they hold all of that (/, /Users, ~, ~/Library, ~/Repos). cage.sb write-denies them as well.
overlap() {
  local d="$1" h p q
  h=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P) || h=${HOME:-/nonexistent}
  for p in / /Users "$h" "$h/Library" "$h/Repos"; do [ "$d" != "$p" ] || { printf '%s' "$p"; return 0; }; done
  for p in .claude .codex .grok .gemini; do case "$d" in "$h/$p"*) printf '%s' "$h/$p*"; return 0 ;; esac; done
  for p in "$STATE_DIR" "$CAGE_SECRETS" "$h/.ssh" "$h/.local/bin" "$h/.agents" \
    "$h/Library/LaunchAgents" "${SCRIPT_DIR%/*/*/*}" /opt/homebrew \
    /Applications "$h/.claude" "$h/.codex" "$h/.grok" "$h/.gemini"; do
    q=$(cd "$p" 2>/dev/null && pwd -P) || q=$p
    case "$d/" in "$q"/* | "$p"/*) printf '%s' "$p"; return 0 ;; esac
    case "$q/" in "$d"/*) printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}

cmd_launch() {
  need_me
  orchestrator_check
  local dir="$PWD" label="claude" split="" ratio=50 tab="" anchor="" kind=""
  local trust=0 focus=false timeout=90 agent=claude allow_edits=0 rules=() a cage="$CAGE_DEFAULT" account=""
  local acct_hint="an uncaged child runs on whatever account its --agent command uses"
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--dir) optval "$@"; dir="$2"; shift 2 ;;
      -l|--label) optval "$@"; label="$2"; shift 2 ;;
      --split) optval "$@"; split="$2"; shift 2 ;;
      --ratio) optval "$@"; ratio="$2"; shift 2 ;;
      --tab) optval "$@"; tab="$2"; shift 2 ;;
      -b|--anchor) optval "$@"; anchor="$2"; shift 2 ;;
      --trust) trust=1; shift ;;
      --agent) optval "$@"; agent="$2"; shift 2 ;;
      --kind) optval "$@"; kind="$2"; shift 2 ;;
      --focus) focus=true; shift ;;
      --timeout) optval "$@"; timeout=$(secs "$1" "$2") || exit 2; shift 2 ;;
      --allow-edits) allow_edits=1; shift ;;
      --allow) optval "$@"; rules+=("$2"); shift 2 ;;
      --cage) cage=on; shift ;;
      --no-cage) cage=off; shift ;;
      --account) [ -n "${2:-}" ] || die "launch: --account needs a value of lowercase letters and digits; $acct_hint"
                 account="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "launch: unknown option $1" ;;
    esac
  done
  case "$cage" in auto | on | off) ;; *) die "launch: REX_ORCHESTRATOR_CAGE takes auto, on or off, not '$cage'" ;; esac
  ! killed || die "launch: stopped: the kill switch $STATE_DIR/disabled is set; report it, never remove it yourself"
  # Neither -b nor --split: split the roomiest pane of your own window, so a work line's agents stay in one view.
  if [ -z "$tab" ] && [ -z "$anchor" ] && [ -z "$split" ]; then roomiest; fi
  anchor=${anchor:-$me} split=${split:-right}
  case "$split" in right | left | above | below) ;; *) die "launch: --split takes right, left, above or below, not '$split'" ;; esac
  case "$ratio" in *[!0-9]*) die "launch: --ratio takes a whole percentage, not '$ratio'" ;; esac
  [ "$kind" != gemini ] || kind=agy # Gemini runs as the agy CLI; agy stays the internal kind
  case "$kind" in '' | claude | codex | grok | agy | muse) ;; *) die "launch: --kind takes claude, codex, grok, gemini (agy) or muse, not '$kind'" ;; esac
  # shortcut: a Claude Code wrapper is known by its name only (claude-work: CLAUDE_CONFIG_DIR=… exec claude); --kind
  # claude covers one named otherwise.
  local name; name=$(basename "$agent")
  [ -n "$kind" ] || case "$name" in claude-*) kind=claude ;; agy-*) kind=agy ;; *) kind=$name ;; esac
  [ -d "$dir" ] || die "launch: no such directory: $dir"
  local dir_given="$dir" identity
  local dir_l; dir_l=$(cd "$dir" && pwd -L)
  dir=$(cd "$dir" && pwd -P)
  # Session-scoped allow rules through --settings: nothing is written to the user's settings files.
  if [ "$allow_edits" -eq 1 ] || [ ${#rules[@]} -gt 0 ]; then
    [ "$kind" = claude ] || die "launch: --allow-edits and --allow work with claude only"
    # claude keeps only the last --settings, so the caller's own one would silently drop these rules.
    for a in "$@"; do
      case "$a" in --settings | --settings=*) die "launch: --allow-edits and --allow can't be combined with -- --settings (claude keeps only the last one); put the rules in that JSON's permissions.allow" ;; esac
    done
    # Read/Edit rules are gitignore-style patterns: these characters in DIR would widen its rule or break it.
    [ "$allow_edits" -eq 0 ] || case "$dir$dir_l" in
      *[][*?{}!\\\)]*) die "launch: --allow-edits can't scope $dir (its path holds one of [ ] * ? { } ! ) \\); use wait --approve-in DIR instead" ;;
    esac
    # "//" marks an absolute path in a Claude Code permission rule.
    # Rules match the path as the agent writes it, so cover both the given and the physical form (/tmp, /private/tmp).
    [ "$allow_edits" -eq 0 ] || rules+=("Read(/$dir/**)" "Edit(/$dir/**)")
    [ "$allow_edits" -eq 0 ] || [ "$dir_l" = "$dir" ] || rules+=("Read(/$dir_l/**)" "Edit(/$dir_l/**)")
    set -- --settings "$(jq -cn '{permissions: {allow: $ARGS.positional}}' --args "${rules[@]}")" "$@"
  fi

  # Rex starts the agent from its server's login environment, not ours: our PATH picks the binary.
  local bin
  bin=$(type -P "$agent") || die "launch: no $agent on your PATH (give --agent a full path)"
  case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac

  # --account names a caged claude's cage credential, claude-ACCT.env; an uncaged child's account is its wrapper's.
  # Refused before any pane opens, and never answered by running uncaged instead.
  if [ -n "$account" ]; then
    acct_ok "$account" || die "launch: --account takes lowercase letters and digits, not '$account'; $acct_hint"
    [ "$name" = claude ] && [ "$cage" != off ] || die "launch: --account is for a caged claude only; $acct_hint"
    [ -f "$CAGE_SECRETS/claude-$account.env" ] && [ -r "$CAGE_SECRETS/claude-$account.env" ] ||
      die "launch: --account $account: no readable $CAGE_SECRETS/claude-$account.env; $acct_hint"
  fi

  # Cage first: codex and grok run inside a sandbox-exec cage unless --no-cage (claude once a cage credential
  # exists, agy once its home does). cage_build swaps in a wrapper named like the agent, so the dialog logic
  # keys on $name as before. Fail closed (exit 2, no pane) when an agent that should be caged can't be: no silent
  # uncaged fallback.
  local spawn=() cage_tmp="" cage_wrapper="" cage_acct="" cage_why="" cb=0 envs=() v
  if [ "$cage" != off ]; then
    cage_build "$name" "$bin" "$dir" || cb=$?
    case "$cb" in
      # Until launch reports, any exit removes the cage home again (unlaunch); a global, like LAUNCHED.
      0) spawn=("$cage_wrapper"); CAGING=$cage_tmp; trap unlaunch EXIT
         ! a=$(overlap "$dir") ||
           die "launch: refusing a caged $name in $dir: it is, holds or sits in $a, which runs or is read outside the cage; give the task its own folder, or pass --no-cage"
         if [ -n "$cage_acct" ]; then note "caged $name on account $cage_acct: $cage_why"
         else note "caged $name ($(basename "$CAGE_PROFILE"))"; fi ;;
      # --no-cage is no way out for --account, which it refuses: the account's own wrapper is.
      2) [ -z "$account" ] || die "cage: setup for $name failed (see above); fix the cage, or run the child uncaged through a wrapper for that account (--agent CMD) instead of --account"
         die "cage: setup for $name failed (see above); pass --no-cage to run it uncaged" ;;
      *) [ "$cage" != on ] || die "cage: no cage recipe for $name (claude needs a $CAGE_SECRETS/claude-<name>.env, agy a cage home: see docs/cage.md); pass --no-cage to run it uncaged"
         note "running $name uncaged: no cage recipe for it (pass --no-cage to silence)" ;;
    esac
  fi
  # Uncaged: run the caller's binary, handing over only CLAUDE_CONFIG_DIR and CODEX_HOME (paths, shown in ps,
  # never a token); Rex's login environment supplies nothing else. A caged child gets neither: its wrapper sets its own
  # homes. Claude Code's session survey takes a one-character prompt as its answer (send "2" rates the session, and the
  # "y" of the transcript question that can follow uploads the session), so no claude child shows it.
  if [ "${#spawn[@]}" -eq 0 ]; then
    ! killed "$kind" || die "launch: stopped: the kill switch $STATE_DIR/disabled.$kind is set, so no uncaged $kind starts; report it, never remove it yourself"
    # No bypass mode for an uncaged claude: the auto-mode classifier or manual approvals, never bypassPermissions.
    if [ "$kind" = claude ]; then
      v=""
      for a in "$@"; do
        case "$v=$a" in
          *=--dangerously-skip-permissions | *=--allow-dangerously-skip-permissions | *=--permission-mode=bypassPermissions | \
            --permission-mode=bypassPermissions)
            die "launch: refusing an uncaged claude in bypass permissions mode ($a); use the cage, or --permission-mode default or auto" ;;
        esac
        v=$a
      done
    fi
    for v in CLAUDE_CONFIG_DIR CODEX_HOME; do [ -z "${!v:-}" ] || envs+=("$v=${!v}"); done
    [ "$kind" != claude ] || envs+=(CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1)
    spawn=("$bin")
    if [ ${#envs[@]} -gt 0 ]; then
      # env takes every leading word with "=" for a variable, the agent's own path too.
      case "$bin" in *=*) die "launch: env can't run $bin, whose path holds '='; run the agent from a path without one" ;; esac
      spawn=(/usr/bin/env "${envs[@]}" "$bin")
    fi
  fi

  # rex's own exit codes mean something else here (its 3 is "not found", launch's is "a dialog is waiting").
  # A signal to this script while rex opens the pane waits for its ID, so the pane can still be closed. One that reaches
  # rex too (a Ctrl-C reaches the whole process group, and rex doesn't ignore it) can end rex after Rex made the pane
  # but before it printed the ID: the pane opens under a label of this launch's own (TAG, a global like LAUNCHED), by
  # which the exit trap still finds and closes it. It starts with LABEL, as a cleanup by label expects; the real label
  # (and a tab's name) is set once the ID is known.
  local out sig=""
  claim_identity
  trap unlaunch EXIT
  registry_lock
  registry_check
  TAG="$label.launch-$$-$RANDOM"
  trap 'sig=129' HUP; trap 'sig=130' INT; trap 'sig=143' TERM
  trap unlaunch EXIT
  if [ -n "$tab" ]; then
    out=$("$REX" window new -s "$REX_SESSION" "$TAG" -c "$dir" --keep-open --focus="$focus" --json -- "${spawn[@]}" "$@") ||
      { [ -z "$sig" ] || exit "$sig"; fail "launch: rex could not open the tab (its error is above)"; }
  else
    out=$("$REX" split -s "$REX_SESSION" ${anchor:+-b "$anchor"} --split="$split" --ratio "$ratio" \
      -c "$dir" --label "$TAG" --keep-open --focus="$focus" --json -- "${spawn[@]}" "$@") ||
      { [ -z "$sig" ] || exit "$sig"; fail "launch: rex could not open the pane (its error is above)"; }
  fi
  block=$(jq -er '.block_ids[0] | strings' <<<"$out" 2>/dev/null) || fail "launch: rex returned no block: $out"
  # Until launch reports (0, 3, 12, 124) every exit closes the pane: a signal, errexit or a refusal leaves no agent
  # running unseen. A global: bash 5 drops cmd_launch's locals before an errexit EXIT trap.
  LAUNCHED=$block TAG=""
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  [ -z "$sig" ] || exit "$sig"
  "$REX" block rename -s "$REX_SESSION" "$block" -- "$label" >/dev/null || note "could not label $block $label"
  [ -z "$tab" ] || "$REX" window rename -s "$REX_SESSION" "$(jq -r '.window_id // ""' <<<"$out")" -- "$tab" >/dev/null ||
    note "could not name the tab $tab"
  # Ownership (only this pane drives it) and the agent's pid (another program in the block later means exited).
  local sf pid proc
  sf=$(state_file "$block")
  proc=$(rex_call "$block" process) || proc=null
  pid=$(jq -r '.child.pid // ""' <<<"$proc")
  # An agent that already exited needs no live claim; preserve launch's exit-12 pane and diagnostics.
  if ! jq -e '.last_exit != null' <<<"$proc" >/dev/null; then registry_add; fi
  registry_unlock
  put "$sf.own" "$me" "$pid" "" "$kind" "$dir" "" "$bin" || note "could not save the state of $block"
  # The block, in the cage home's run metadata for the transcript harvest at close.
  if [ -n "$cage_tmp" ] && [ -f "$cage_tmp/run-meta.json" ]; then
    # shellcheck disable=SC2015  # note when either step fails
    jq --arg block "$block" '.block=$block' "$cage_tmp/run-meta.json" >"$cage_tmp/run-meta.tmp" &&
      mv "$cage_tmp/run-meta.tmp" "$cage_tmp/run-meta.json" || note "could not save harvest block"
  fi
  # The cage dir's leaf name, so close can delete it, and a caged claude's account, for status and ls (atomic).
  [ -z "$cage_tmp" ] || put "$sf.cage" "${cage_tmp##*/}" "$cage_acct" || note "could not save the cage marker of $block"
  note "launched $block in $dir"

  local start=$SECONDS answered=0 dialog_at="" text region flat rec owner n=0 down_at="" ready=0 r0 dialogs=0 d0 tshown seen
  local cols=0 named pre="" snap=0 post pill="" t
  # A trust answer is remembered, so it is never the parent's to give by hand.
  local untrusted="relaunch with --trust, or leave it to the user: report it; don't answer it by hand (the answer is remembered)"
  # A caged codex can't save a trust answer (its config is write-locked), so answering by hand only loops.
  [ -z "$cage_tmp" ] || [ "$name" != codex ] || untrusted="relaunch with --trust (a caged codex can't save an answer)"
  local nodir="left to the user: the trust dialog doesn't name $dir; report it, don't answer it"
  while :; do
    # A screen that can't be read is unknown, never "no dialog": that poll decides nothing but exited and the timeout.
    seen=1; text=$(screen_text "$block") || { text=""; seen=0; }
    region=$(dialog_region "$text"); flat=$(squeeze "$region")
    # A record that can't be read is unknown: never ready, and no trust question.
    rec=$(root_record "$block") || rec=""
    tshown=0; trust_shown && tshown=1
    # Both counts run only while their reading holds poll after poll.
    r0=$ready ready=0 d0=$dialogs dialogs=0
    if [ "$seen" -eq 0 ]; then :
    # Never trust an agent's hooks for the user, even after answering its folder dialog (codex shows both). A short
    # pane folds codex's title away ("[… 3 lines]"), so its options name the dialog too.
    elif [ "$kind" != claude ] &&
      matches "$(squeeze "$text")" -Ei 'hooks? needs? review|review hooks|trust all and continue|continue without trusting'; then
      note "$block is waiting at a hooks review; left to the user: report it, don't answer it (trusting hooks is remembered)"
      report 3
    # Once answered, the dialog text can stay on screen (muse): stop matching it and check readiness instead.
    elif [ "$kind" != claude ] && [ "$answered" -eq 0 ] && [ "$tshown" -eq 1 ]; then
      # Folder trust only with --trust.
      [ "$trust" -eq 1 ] || { note "$block is waiting at a trust dialog; $untrusted"; report 3; }
      # Press only at a dialog that names DIR, after noting which of DIR's ancestors are trusted.
      named=0; trust_dir_named && named=1
      # A key rex failed to send is tried again on the next poll.
      [ "$named" -eq 0 ] || case "$kind" in
        # grok's y only on its exact two-option form.
        grok) if grok_two_options "$region"; then trust_snapshot; printf y | "$REX" send -s "$REX_SESSION" -b "$block" && answered=1; fi ;;
        # agy, muse and codex preselect the trusting option; confirm only when it is shown selected.
        *) if matches "$flat" -E '(>|⟩|›) ?(Yes, I trust this folder|1\.? Trust and continue|1\. Yes, continue)'; then
             trust_snapshot; "$REX" send-key -s "$REX_SESSION" -b "$block" enter && answered=1
           fi ;;
      esac
      # Allow a few seconds for the dialog to finish drawing, then hand an unknown dialog to the user, or refuse a
      # pane that cuts it.
      [ -n "$dialog_at" ] || dialog_at=$SECONDS
      if [ "$answered" -eq 0 ] && [ $((SECONDS - dialog_at)) -ge 5 ]; then
        [ "$named" -eq 1 ] || { note "$block: $nodir"; report 3; }
        too_small "$kind's trust dialog shows no option to confirm"
        note "$block shows a trust dialog with no known answer for $kind; left to the user: report it, don't answer it"
        report 3
      fi
    elif [ "$kind" = claude ] && [ "$answered" -eq 0 ] && [ "$tshown" -eq 1 ]; then
      [ "$trust" -eq 1 ] || { note "$block is waiting at the workspace trust dialog; $untrusted"; report 3; }
      # The default is "No, exit" and the menu wraps: Enter only once "Yes" shows selected, and another down only if
      # "No" still shows 8 polls (~5s) after the last, so a slow redraw can't stack a second down that flips back.
      # Neither before the dialog names DIR, which it must within 5s.
      if ! trust_dir_named; then
        [ -n "$dialog_at" ] || dialog_at=$SECONDS
        [ $((SECONDS - dialog_at)) -lt 5 ] || { note "$block: $nodir"; report 3; }
      elif matches "$flat" -E "❯ ?$TRUST_RE"; then
        trust_snapshot; "$REX" send-key -s "$REX_SESSION" -b "$block" enter && answered=1
      elif [ -z "$down_at" ] || [ $((n - down_at)) -ge 8 ]; then
        trust_snapshot; "$REX" send-key -s "$REX_SESSION" -b "$block" down && down_at=$n
      fi
    # Two ready readings in a row: an agent can draw its composer a moment before a dialog. And not exited: a caged
    # codex that can't open its state DB (or any agent) can look ready a moment before it dies, so re-check before
    # reporting 0, or a ready-looking dead screen would report ready. If it exited, the exited check below reports 12.
    elif launch_ready; then
      if [ $((ready = r0 + 1)) -ge 2 ] && ! exited "$block"; then
        # From here on only root records under the agent's own pid count (root_record). Checked live: for
        # claude, codex, grok and agy the owner is the agent itself and keeps its pid across turns and tool runs.
        # muse and other agents are unchecked, so they get no owner check.
        case "$kind" in claude | codex | grok | agy) owner=$(jq -r '.owner.pid // ""' <<<"$rec") ;; *) owner="" ;; esac
        if [ -z "$cage_tmp" ]; then
          # The trust postcondition: pressing trust for DIR trusted none of DIR's ancestors.
          if [ "$snap" -eq 1 ]; then
            post=$(trusted_above "$kind")
            while IFS= read -r t; do
              [ -z "$t" ] || grep -qxF -- "$t" <<<"$pre" || {
                kill_switch "$kind" "launch --trust for $dir made $kind trust $t, an ancestor of it"; report 3; }
            done <<<"$post"
          fi
          # An uncaged claude never runs in bypass mode, and keeps the mode it starts in.
          if [ "$kind" = claude ]; then
            pill=$(mode_pill "$text")
            case "$pill" in *bypass*) die "launch: refusing an uncaged claude that started in bypass permissions mode ($pill: a settings default?); use the cage, or -- --permission-mode default or auto" ;; esac
          fi
        fi
        put "$sf.own" "$me" "$pid" "$owner" "$kind" "$dir" "$pill" "$bin" || note "could not save the state of $block"
        mark "$block" "$rec" || note "could not read the state of $block yet"
        report 0
      fi
    # Any other dialog at startup (Claude's "New MCP server found", a login menu) is the user's once it has stayed up
    # for 4 polls (~2s). A trust dialog still drawn after its answer is not another one.
    elif [ "$tshown" -eq 0 ] && dialog_on_screen "$text" && [ $((dialogs = d0 + 1)) -ge 4 ]; then
      note "$block shows a dialog at startup; left to the user: report it, and never answer it with a persistent option. Screen:"
      printf '%s\n' "$region" | tail -n 20 >&2
      report 3
    fi
    if exited "$block"; then
      note "$name exited during startup; screen:"
      { screen_text "$block" || true; } | tail -n 20 >&2
      report 12
    fi
    # -gt: SECONDS ticks on wall-clock seconds, so -ge could give up to 1s early.
    if [ $((SECONDS - start)) -gt "$timeout" ]; then
      note "not ready after ${timeout}s; screen:"
      printf '%s\n' "$text" | tail -n 20 >&2
      report 124
    fi
    n=$((n + 1))
    sleep 0.5
  done
}

# Exit 4 unless the agent in $block can take a prompt: not while its turn runs or a dialog is up, where typed text is
# dropped and the Enter picks the highlighted option ("1. Yes"). Sets $rec to the root record. With "typed" (the text
# is in the composer) a running turn no longer counts: the Enter then only queues the prompt. Sets $scr to the screen.
input_ready() {
  local why="" left="nothing was sent"
  [ -z "${1:-}" ] || left="the text is typed but not submitted"
  rec=$(root_record "$block") || fail "send: cannot read the state of $block; $left"
  scr=$(screen_text "$block") || fail "send: cannot read the screen of $block; $left"
  case "$(jq -r '.state // ""' <<<"$rec")" in
    blocked) why=$(jq -r '"blocked \(.kind // "unknown") \(.msg // "")"' <<<"$rec") ;;
    # codex reports working from its start until its first turn ends, unchanged while it idles at its composer: for
    # codex only its working line ("esc to interrupt") means a turn runs.
    working)
      if [ -z "${1:-}" ] &&
        { [ "$(jq -r '.effective_app // .app' <<<"$rec")" != codex ] || matches "$scr" -i 'esc to interrupt'; }; then
        why=working
      fi ;;
  esac
  if [ -z "$why" ] && dialog_on_screen "$scr" "${1:-}"; then why="a dialog is on screen"; fi
  [ -z "$why" ] || { note "send: $block is not ready for input ($why); $left. Look with screen; answer a dialog with keys"
    exit 4; }
}

# The kill switches also stop typing (kill_switch_stops VERB [REC], for $block): "disabled" stops send and every key but
# escape and ctrl+c (the ones that interrupt) in every pane; "disabled.AGENT" does for an UNCAGED pane of AGENT, as
# it does for its launches and approvals (a caged one is the cage's business). dies with exit 2.
kill_switch_stops() {
  local k
  ! killed || die "$1: stopped: the kill switch $STATE_DIR/disabled is set; report it, never remove it yourself"
  [ ! -f "$(state_file "$block").cage" ] || return 0
  k=$(pane_kind "${2:-}")
  [ -z "$k" ] || ! killed "$k" ||
    die "$1: stopped: the kill switch $STATE_DIR/disabled.$k is set, so nothing is typed into an uncaged $k; report it, never remove it yourself"
}

cmd_send() {
  need_me; target "${1:-}"; owned send; kill_switch_stops send; shift
  local text rec upd scr why c w n
  if [ "${1:-}" = "-f" ]; then
    [ -f "${2:-}" ] || die "send: no such file: ${2:-}"
    text=$(cat "$2")
  else
    text="$*"
  fi
  # Byte-wise: CR, LF and TAB never occur inside a UTF-8 sequence, and a file that isn't UTF-8 passes too.
  text=$(printf '%s' "$text" | LC_ALL=C tr '\r\n\t' '   ')
  # A pattern, not ${text// /}, which bash 3.2 takes minutes over for a 30KB prompt.
  case $text in *[!\ ]*) ;; *) die "send: empty prompt" ;; esac
  # claude, codex, grok and agy run a prompt that starts with "!" as a shell command, without a permission prompt.
  # Anchored regex, linear in the text (stripping the leading spaces with ${text%%…} is quadratic in them).
  [[ ! $text =~ ^[[:space:]]*! ]] ||
    die "send: refusing a prompt that starts with '!': the agent would run it as a shell command without asking; reword it"
  alive_or_exit send
  input_ready
  # Nothing is typed into a pane the mode pin stopped, or once its claude's permission mode changed.
  why=$(stopped); [ -z "$why" ] || die "send: $block is stopped ($why); report it"
  pin_ok "$scr" "$rec" || { stop_pane "$pin_why"; exit 2; }
  if [ "$(pane_kind "$rec")" = claude ]; then
    # Claude's session survey takes a leading digit as a rating.
    [[ ! $text =~ ^[[:space:]]*[0-9] ]] ||
      die "send: refusing a prompt that starts with a digit: claude's session survey would take it as a rating; reword it"
    # Uncaged, the slash commands that widen what the child may do for the rest of the session, or a prefix of one,
    # which claude's completion would turn into it.
    w=${text:0:200}; read -r w _ <<<"$w"; w=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$w")
    [ -f "$(state_file "$block").cage" ] || case "$w" in /*)
      for c in /permissions /allowed-tools /config /settings /add-dir /hooks /plugin /mcp; do
        case "$c" in "$w"*) die "send: refusing $w for an uncaged claude: $c would change what it may do for the whole session; scope permissions at launch (--allow, --allow-edits) or leave it to the user" ;; esac
      done ;;
    esac
  fi
  mark "$block" "$rec" || fail "send: cannot read or save the state of $block; nothing was sent"
  # Through stdin, so a prompt that starts with "-" is not read as an option.
  printf '%s' "$text" | "$REX" send -s "$REX_SESSION" -b "$block" || fail "send: rex could not type into $block"
  sleep 0.5
  upd=$(jq -r '.updated_at // ""' <<<"$rec")
  input_ready typed
  # agy and codex report idle while the text sits in their composer: that report is the baseline, not a turn's end.
  [ "$(jq -r '.updated_at // ""' <<<"$rec")" = "$upd" ] || mark_since "$block" "$rec" || note "could not save the state of $block"
  # The Enter only once the input box shows the text: typed elsewhere, it would answer or start something else.
  # An agent can take a few seconds to draw a long paste (codex shows its placeholder after about 1s): look for 3s.
  n=0
  until ! dialog_on_screen "$scr" typed && typed_shown "$scr" "$text" "$(jq -r '.effective_app // .app // ""' <<<"$rec")"; do
    [ $((n += 1)) -le 6 ] || {
      note "send: $block's input box doesn't show the prompt; the text is typed but not submitted. Look with screen"
      exit 4; }
    sleep 0.5
    scr=$(screen_text "$block") || fail "send: cannot read the screen of $block; the text is typed but not submitted"
  done
  "$REX" send-key -s "$REX_SESSION" -b "$block" enter || { sleep 0.3; "$REX" send-key -s "$REX_SESSION" -b "$block" enter; } ||
    fail "send: the prompt is typed but not submitted (Return failed twice); check screen $block, then keys $block enter"
}

# Whether a finished turn (done/idle) is really over. A turn can end with work left in background tasks that resume
# the agent later: hold it while the footer counts more background work than at the send, up to bg_max, then 20s
# after it ends for the agent to resume. Uses cmd_wait's locals.
turn_over() {
  # --ignore-background ends a finished turn at once, a hold carried from an earlier wait included.
  [ "$ignore_bg" -eq 0 ] || return 0
  local now base s rc=0; now=$(date +%s)
  bg=$(background_tasks "$block") || rc=$?
  # A screen that can't be read is unknown: look again rather than end the turn.
  [ "$rc" -ne 2 ] || return 1
  base=${bg_base%% *}; case "$base" in '' | *[!0-9]*) base=0 ;; esac
  # shortcut: only the count is compared with the send's, so a turn that ends an old job and starts a new one isn't
  # held; telling jobs apart would need their IDs.
  if [ "$rc" -eq 0 ] && [ "${bg%% *}" -gt "$base" ]; then
    [ "$held" = "$upd" ] || { held="$upd"; held_at=$now; }
    bg_gone=""
    if [ $((now - held_at)) -ge "$bg_max" ]; then note "background work still running after ${bg_max}s ($bg)"; return 0; fi
    return 1
  fi
  bg=""
  [ -n "$held" ] && [ "$upd" = "$held" ] || return 0
  # grok reports nothing for the turn its finished background work wakes, until that turn's done: while its footer
  # shows a turn running ("Ctrl+c:cancel"), the agent has resumed, and the 20s start once it is gone.
  if [ "$(jq -r '.effective_app // .app // ""' <<<"$rec")" = grok-build ]; then
    s=$(screen_text "$block") || return 1
    if matches "$(squeeze "$(dialog_region "$s")")" -F 'Ctrl+c:cancel'; then bg_gone=""; return 1; fi
  fi
  [ -n "$bg_gone" ] || bg_gone=$now
  [ $((now - bg_gone)) -ge 20 ]
}

# The physical path of P through its deepest existing ancestor, so a link inside the task directory can't point a
# write outside it. Fails on a link it can't follow safely: P itself, or a dangling link on the way up.
real_path() {
  local p rest=""
  p=$(printf '%s' "$1" | tr -s /)
  [ ! -L "$p" ] || return 1
  while [ ! -e "$p" ]; do
    [ ! -L "$p" ] || return 1
    rest="/${p##*/}$rest"; p=$(dirname "$p")
  done
  [ -d "$p" ] || { rest="/${p##*/}$rest"; p=$(dirname "$p"); }
  p=$(cd "$p" && pwd -P) || return 1
  printf '%s%s' "${p%/}" "$rest"
}

# The path in a file write/edit prompt's msg, in the agent's own grammar (msg_path APP MSG); nothing may follow it.
# claude: "approve Write: /p" (Edit shows as Update or Create); agy: "Approve WriteFile: Write: /p", cut to 98
# characters plus "…" (kept, for the caller to see).
# shortcut: the path is the whole rest of the msg (names may hold spaces), so text a future build appended after it
# would read as part of the name; dialog_for's match on the dialog's own name or path row refuses that drift today.
msg_path() {
  case "$2" in *[[:cntrl:]]*) return 1 ;; esac
  case "$1:$2" in
    *…?* | claude-code:*…) return 1 ;;
    "claude-code:approve Write: /"* | "claude-code:approve Edit: /"* | "claude-code:approve Update: /"* | \
      "claude-code:approve Create: /"* | "claude-code:approve MultiEdit: /"* | "claude-code:approve NotebookEdit: /"*)
      printf '%s' "${2#*: }" ;;
    "antigravity:Approve WriteFile: Write: /"* | "antigravity:Approve EditFile: Write: /"*) printf '%s' "${2#*: Write: }" ;;
    *) return 1 ;;
  esac
}

# Names below DIR no agent may write unasked (names_ok PATH_BELOW_DIR): a dot component (.claude, .git, .envrc, …),
# the agents' instruction files, and the hook and tool configs Claude Code guards the same way. APFS ignores case.
names_ok() {
  local b
  case "/$1" in */.*) return 1 ;; esac
  b=$(printf '%s' "${1##*/}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  # APFS also folds Unicode case (ſ is s, the Kelvin sign k, ﬁ fi), which tr can't: a name with a byte outside
  # printable ASCII may open a protected file under another spelling, so it goes to the user.
  ! LC_ALL=C grep -q '[^ -~]' <<<"$b" || return 1
  case "$b" in
    claude.md | claude.local.md | agents.md | gemini.md | lefthook.yml | lefthook.yaml | bunfig.toml | \
      gradle-wrapper.properties | maven-wrapper.properties | pyrightconfig.json) return 1 ;;
  esac
}

# The part of P below DIR in P's own spelling, which may reach DIR through /tmp or a link (below P DIR).
below() {
  local p="$1" rest=""
  until [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$2" ]; do
    [ "$p" != / ] || return 1
    rest="/${p##*/}$rest"; p=$(dirname "$p")
  done
  printf '%s' "${rest#/}"
}

# Whether a write to P (as the agent names it) lands on a plain file inside DIR (path_ok P DIR): no "." or ".."
# component, P itself no link (dangling or not), not DIR, a file with one name only (a hard link can sit outside),
# and no protected name below DIR in either spelling (a .claude link to a plain folder still is .claude).
path_ok() {
  local real rel
  case "/$1/" in */./* | */../*) return 1 ;; esac
  [ ! -L "$1" ] && real=$(real_path "$1") || return 1
  case "$real" in "$2"/?*) ;; *) return 1 ;; esac
  [ ! -e "$real" ] || { [ -f "$real" ] && [ "$(stat -f %l "$real")" = 1 ]; } || return 1
  rel=$(below "$1" "$2") && names_ok "$rel" && names_ok "${real#"$2"/}"
}

# Whether the hidden rest of a cut agy path stays inside DIR (prefix_ok PREFIX DIR): the visible part's deepest
# existing directory is a real one inside DIR with no link anywhere below it (the agent resolved links and "..").
# shortcut: the hidden rest's names go unchecked (a dotfile deep in a long path); a wider pane shows the whole path.
prefix_ok() {
  local top="${1%/*}" link
  case "/$1/" in */./* | */../*) return 1 ;; esac
  while [ ! -e "$top" ] && [ ! -L "$top" ]; do top=$(dirname "$top"); done
  [ -d "$top" ] && [ ! -L "$top" ] && [ "$(cd "$top" && pwd -P)" = "$top" ] || return 1
  case "$1" in "$2"/?*) ;; *) return 1 ;; esac
  case "$top/" in "$2"/*) ;; *) return 1 ;; esac
  # find fails on a folder it can't read, whose links it can't see.
  names_ok "${1#"$2"/}" && link=$(find "$top" -type l -print -quit 2>/dev/null) && [ -z "$link" ]
}

# Whether the agent in $block runs an agy build listed in AGY_VERIFIED_SHA256. The hash is kept in STATE_DIR by the
# binary's path, size, mtime, inode and ctime: hashing 200MB on every prompt would take a second.
agy_verified() {
  local bin st sha="" c="$STATE_DIR/agy-sha256" cst="" cm="" ci="" cc="" csha="" cbin=""
  bin=$(rex_call "$block" process | jq -r '.child.path // ""') && [ -f "$bin" ] && st=$(stat -f '%z %m %i %c' "$bin") || return 1
  [ ! -f "$c" ] || read -r cst cm ci cc csha cbin <"$c" || true
  if [ "$cst $cm $ci $cc" = "$st" ] && [ "$cbin" = "$bin" ]; then sha=$csha
  else sha=$(shasum -a 256 "$bin" | awk '{ print $1 }') && put "$c" "$st $sha $bin" || return 1
  fi
  case " $AGY_VERIFIED_SHA256 " in *" $sha "*) [ -n "$sha" ] ;; *) return 1 ;; esac
}

# Whether the dialog on screen (the rows below the last horizontal rule) asks about FILE with its cursor on option 1,
# a one-time Yes (dialog_for SCREEN APP FILE CUT). claude's question (its last "Do you want to" row) names the
# file's basename, and its option 1 reads exactly "Yes"; it prints the path row under the title ("Create file"),
# for row_names. agy's first row is the path, "PATH  +N[ -M]". For a cut agy msg (CUT=1, FILE its visible
# prefix) it prints the whole path when that row is shorter than the rule (so the pane didn't cut it), else nothing.
dialog_for() {
  LC_ALL=C F="$3" A="$2" C="$4" awk '
    index($0, "──────────") { n = 0; w = gsub(/─/, "─"); next }
    { l[++n] = $0 }
    END {
      f = ENVIRON["F"]; b = f; sub(/.*\//, "", b); stat = "  [+-][0-9]+( [+-][0-9]+)?$"
      for (i = 1; i <= n; i++) {
        t = l[i]; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        if (t != "" && row && !prow) prow = t
        if (t != "" && !row) row = i
        if (t ~ /^Do you want to /) q = t
        if (t !~ /^(❯|>|›|⟩)[[:space:]]*[0-9]+\./) continue
        sel++; o = t; sub(/^(❯|>|›|⟩)[[:space:]]*/, "", o); num = o; sub(/\..*/, "", num); sub(/^[0-9]+\.[[:space:]]*/, "", o)
        # Option text wrapped onto the next rows belongs to it.
        for (j = i + 1; j <= n && l[j] ~ /[^[:space:]]/ && l[j] !~ /^[[:space:]]*((❯|>|›|⟩)[[:space:]]*)?[0-9]+\./; j++) {
          u = l[j]; sub(/^[[:space:]]+/, "", u); o = o " " u
        }
      }
      if (ENVIRON["A"] == "claude-code") {
        ok = sub(/^Do you want to (create|overwrite|write to|make this edit to|insert this cell into|delete this cell from) /, "", q) &&
          q == b "?" && o == "Yes"
        shown = prow
      } else if (row) {
        t = l[row]; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        if (index(t, f) == 1) {
          r = substr(t, length(f) + 1)
          if (!ENVIRON["C"]) { if (r ~ "^" stat) { ok = 1; shown = f } }
          else if (length(l[row]) < w && match(r, stat)) { ok = 1; shown = f substr(r, 1, RSTART - 1) }
          else ok = 1
        }
      }
      # Bytes here (LC_ALL=C): "don[^ ]*t" also takes the 3-byte typographic apostrophe both agents print.
      good = w && ok && sel == 1 && num == 1 && o ~ /^(Yes|Allow|Approve)/ &&
        tolower(o) !~ /always|don[^ ]*t ask|ask again|persist|remember|session|conversation|all edits|auto mode|accept edits|bypass/
      if (good) printf "%s", shown
      exit !good
    }' <<<"$1"
}

# Whether claude's dialog path row ROW names PATH (row_names ROW PATH DIR, DIR the child's launch DIR): ROW, which
# claude writes relative to DIR (../ for a file outside it), absolute or with ~/, resolved, is PATH; with one "…", its
# parts start and end PATH's absolute, ~/ or DIR-relative spelling, its last component whole.
row_names() {
  local row="$1" p="$2" d="$3" a pre suf f c out=() parts=()
  [ -n "$row" ] && [ -n "$d" ] || return 1
  case "$row" in
    *…*…*) return 1 ;;
    *…*)
      pre=${row%%…*} suf=${row#*…}
      case "$suf" in */*) ;; *) return 1 ;; esac
      for f in "$p" "~${p#"${HOME:-/nonexistent}"}" "${p#"$d"/}"; do
        case "$f" in "~$p") continue ;; esac
        [ ${#f} -gt $((${#pre} + ${#suf})) ] || continue
        case "$f" in "$pre"*"$suf") return 0 ;; esac
      done
      return 1 ;;
  esac
  # shellcheck disable=SC2088  # a literal "~/" in the row
  case "$row" in /*) a=$row ;; "~/"*) a="${HOME:-/nonexistent}/${row#"~/"}" ;; *) a="$d/$row" ;; esac
  # "." and ".." folded lexically, as claude means them.
  IFS=/ read -ra parts <<<"$a"
  for c in "${parts[@]}"; do
    case "$c" in '' | .) ;; ..) [ ${#out[@]} -eq 0 ] || unset "out[$((${#out[@]} - 1))]" ;; *) out+=("$c") ;; esac
  done
  a=$(IFS=/; printf '/%s' "${out[*]:-}")
  a=$(real_path "$a") && f=$(real_path "$p") && [ "$a" = "$f" ]
}

# Answer "Yes" once to a file write/edit prompt inside DIR (approve_once REC DIR, for $block): rc 0 answered (now, or
# before by another approver), 1 left to the user (wait exits 10), 2 another approver is at it or the prompt just
# changed (look again). One approver at a time per block, and each record once (its updated_at).
# The lock is a flock(2) on the lock file, taken in one step with no check-then-create window: the open file
# description is this shell's fd 8 (opened by the group's redirection); perl, which has no flock(1) here, locks that
# same description and exits, and the lock stays until the group ends or this shell dies. The kernel drops it then,
# so there is no stale lock to detect or steal. The file itself is never removed here (an inode swap would let two
# approvers in); close removes it with the pane's other state.
approve_once() {
  local lock rc=0 ran=0 got
  lock="$(state_file "$block").lock"
  {
    ran=1
    got=0; /usr/bin/perl -e 'use Fcntl qw(:flock); open(my $f, ">&=", 8) or exit 3; flock($f, LOCK_EX | LOCK_NB) or exit 2' \
      2>/dev/null || got=$?
    case "$got" in
      0) approve_locked "$@" || rc=$? ;;
      2) rc=2 ;;
      *) note "--approve-in left this to you: cannot take the approval lock of $block"; rc=1 ;;
    esac
  } 8>>"$lock" || [ "$ran" -eq 1 ] || { note "--approve-in left this to you: cannot open the approval lock of $block"; return 1; }
  return "$rc"
}

approve_locked() {
  local rec="$1" dir="$2" msg app upd path cut="" shown="" ok n=0 why
  why=$(stopped); [ -z "$why" ] || { note "--approve-in left this to you: $block is stopped ($why)"; return 1; }
  ! killed "$(pane_kind "$rec")" ||
    { note "--approve-in left this to you: the kill switch $STATE_DIR/disabled.$(pane_kind "$rec") is set"; return 1; }
  msg=$(jq -r '.msg // ""' <<<"$rec"); app=$(jq -r '.effective_app // .app // ""' <<<"$rec")
  upd=$(jq -r '.updated_at // ""' <<<"$rec"); ok="$(state_file "$block").ok"
  if [ -z "$upd" ] || ! path=$(msg_path "$app" "$msg"); then
    note "--approve-in left this to you: not a file write or edit prompt it knows"; return 1
  fi
  [ ! -f "$ok" ] || ! grep -qxF -- "$upd" "$ok" || return 0
  path=$(printf '%s' "$path" | tr -s /)
  case "$path" in *…) cut=1; path=${path%…} ;; esac
  [ -z "$cut" ] || agy_verified || { note "--approve-in left this to you: agy cut the path, and this agy build is not a verified one"; return 1; }
  # The dialog can be drawn a moment after its record: look again for up to 2s.
  until shown=$(dialog_for "$(screen_text "$block" || true)" "$app" "$path" "$cut"); do
    [ $((n += 1)) -lt 9 ] || { note "--approve-in left this to you: the dialog on screen is not this prompt's one-time Yes"; return 1; }
    sleep 0.25
  done
  if [ "$app" = claude-code ]; then
    row_names "$shown" "$path" "$(state_line "$block" own 5)" ||
      { note "--approve-in left this to you: the dialog's path row (${shown:-none}) doesn't name $path"; return 1; }
    shown=""
  fi
  if [ -n "$cut" ] && [ -z "$shown" ]; then
    prefix_ok "$path" "$dir" || { note "--approve-in left this to you: agy cut the path in its status and in its dialog (the pane is narrow), and the part shown can't keep it inside $dir"; return 1; }
  else
    path_ok "${shown:-$path}" "$dir" || { note "--approve-in left this to you: not a plain file inside $dir, or a protected one (dot files, agent instructions, a name with a non-ASCII character)"; return 1; }
  fi
  # Still the same record: the dialog just checked is its own.
  [ "$(root_record "$block" || true)" = "$rec" ] || return 2
  "$REX" send-key -s "$REX_SESSION" -b "$block" enter || { note "--approve-in could not press Enter in $block"; return 1; }
  note "approved once: $msg"; pressed=1
  # Before the lock goes: the record can stay up a moment after the Enter, and no approver may press for it again.
  put "$ok" "$(tail -n 19 "$ok" 2>/dev/null || true)" "$upd" || note "could not save the state of $block"
}

cmd_wait() {
  local arg="${1:-}" block rc=0; [ -n "$arg" ] || die "missing BLOCK"; shift
  local timeout=600 ignore_bg=0 bg_max=300 approve_in="" f
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) optval "$@"; timeout=$(secs "$1" "$2") || exit 2; shift 2 ;;
      --ignore-background) ignore_bg=1; shift ;;
      --bg-max) optval "$@"; bg_max=$(secs "$1" "$2") || exit 2; shift 2 ;;
      --approve-in) optval "$@"; approve_in=$(cd "$2" 2>/dev/null && pwd -P) || die "wait: no such directory: $2"
        # So broad that a "Yes" would cover the user's whole home or all their repos.
        for f in / /Users "${HOME:-/}" "${HOME:-}/Library" "${HOME:-}/Repos"; do
          [ "$approve_in" != "$(cd "$f" 2>/dev/null && pwd -P)" ] || die "wait: --approve-in $2 is too broad; give the task's own directory"
        done
        shift 2 ;;
      --force) force=1; shift ;;
      *) die "wait: unknown option $1" ;;
    esac
  done
  # A full ID rex no longer knows is a closed pane: keep it, and the loop reports exited.
  target "$arg" gone
  [ -z "$approve_in" ] || { need_me; owned "wait --approve-in"; }
  local sf; sf=$(state_file "$block")
  # A caged child runs without permission prompts (the cage is the boundary); any prompt it still raises goes to the
  # user, never a key press from here. So --approve-in is a plain wait on a caged block.
  [ -z "$approve_in" ] || [ ! -f "$sf.cage" ] || { note "wait: --approve-in is ignored for a caged block (its prompts go to the user)"; approve_in=""; }
  local since="" bg_base="" rec state="" upd="" start=$SECONDS since_at=$SECONDS worked=0 idle_at="" bg="" held="" held_at=""
  local bg_gone="" saved why="" ar scr pressed=0
  [ -f "$sf" ] && { read -r since; read -r bg_base; } <"$sf" || true
  # A hold left by a wait that timed out (124) or was killed: continue it rather than start over.
  [ -f "$sf.hold" ] && read -r held held_at bg_gone <"$sf.hold" || true
  saved="$held $held_at $bg_gone"
  while :; do
    # Only evidence ends the wait as exited (a block that is gone, or no longer runs the agent); unknown polls again.
    if exited "$block"; then
      echo "exited"; rc=12; break
    fi
    # A status that can't be read is unknown: this poll decides nothing.
    if rec=$(root_record "$block"); then
      # The mode pin: a change right after this wait approved means option 1 wasn't one-time, so the agent's
      # approvals stop (its kill switch); any other change stops the pane.
      if [ -n "$approve_in" ] && [ -z "$(stopped)" ] && scr=$(screen_text "$block") && ! pin_ok "$scr" "$rec"; then
        [ "$pressed" -eq 0 ] ||
          kill_switch claude "an approval by wait --approve-in in $block was followed by $pin_why, so its option 1 was not one-time"
        stop_pane "$pin_why"; echo "stopped"; rc=10; break
      fi
      state=$(jq -r '.state // ""' <<<"$rec")
      upd=$(jq -r '.updated_at // ""' <<<"$rec")
      [ "$state" = working ] && worked=1
      [ "$state" = idle ] || idle_at=""
      # Reports from before the last send or keys don't count, except this turn's done held for background work.
      if [ -n "$state" ] && { [ "$upd" != "$since" ] || { [ -n "$held" ] && [ "$upd" = "$held" ]; }; }; then
        case "$state" in
          done) if turn_over; then echo "$state"; rc=0; break; fi ;;
          # agy and codex report idle while a typed prompt sits in their composer, and send takes that report as the
          # baseline; for one that comes later, count idle only after work was seen, or once it has held for 8s.
          idle)
            [ -n "$idle_at" ] || idle_at=$SECONDS
            if turn_over && { [ "$worked" -eq 1 ] || [ -n "$held" ] || [ $((SECONDS - idle_at)) -ge 8 ]; }; then
              echo "$state"; rc=0; break
            fi ;;
          blocked)
            ar=1
            [ -z "$approve_in" ] || [ "$(jq -r '.kind // ""' <<<"$rec")" != permission ] || { ar=0; approve_once "$rec" "$approve_in" || ar=$?; }
            case "$ar" in
              0) since="$upd"; since_at=$SECONDS ;;
              2) ;;
              *) jq -r '"blocked \(.kind // "unknown") \(.msg // "")"' <<<"$rec"; rc=10; break ;;
            esac ;;
          error) printf '%s\n' "$rec" | jq -r '"error \(.msg // "")"'; rc=11; break ;;
        esac
      # A key that left its dialog up (a menu move, one part of a multi-part question) brings no new report: after
      # 10s the dialog is the user's again. Only for Claude Code, checked live to re-report at once when a key resolves
      # its prompt (the other agents are unmeasured); never for working, which is a turn still running.
      elif [ "$state" = blocked ] && [ "$(jq -r '.effective_app // .app' <<<"$rec")" = claude-code ] &&
        [ $((SECONDS - since_at)) -gt 10 ]; then
        note "no new report since send/keys: the prompt is still up"
        jq -r '"blocked \(.kind // "unknown") \(.msg // "")"' <<<"$rec"; rc=10; break
      fi
    fi
    # Save the hold as it changes, so a wait that times out or is killed leaves it for the next one.
    [ "$held $held_at $bg_gone" = "$saved" ] || { saved="$held $held_at $bg_gone"; put "$sf.hold" "$saved" || note "could not save the hold"; }
    # -gt: SECONDS ticks on wall-clock seconds, so -ge could end the wait up to 1s early.
    if [ $((SECONDS - start)) -gt "$timeout" ]; then
      # Nothing reported since the last send or keys: the input may not have been taken (look at the screen).
      [ -z "$state" ] || [ "$upd" != "$since" ] || [ "$upd" = "$held" ] || why=", no new report since send/keys"
      echo "timeout (state=${state:-none}${bg:+, background: $bg}$why)"
      rc=124; break
    fi
    sleep 0.5
  done
  # A hold outlives only a 124: one that ended, or a turn that reported anything else, must not end the next wait.
  [ "$rc" -eq 124 ] || rm -f "$sf.hold"
  return "$rc"
}

cmd_status() { target "${1:-}"; status_json "$block"; }

# A pane's one-line status. A read that fails leaves its fields null (unknown); alive is false once the block runs
# another program than the agent launch recorded. account, only for a caged claude, is the account launch chose.
status_json() {
  local rec proc title
  rec=$(root_record "$1") || rec=null
  proc=$(rex_call "$1" process) || proc=null
  title=$(rex_call "$1" title) && title=$(jq -r '.title // ""' <<<"$title") || title=""
  jq -nc --argjson r "$rec" --argjson p "$proc" --arg t "$title" --arg w "$(state_line "$1" own 2)" \
    --arg a "$(state_line "$1" cage 2)" \
    '{state: ($r.state // null), kind: ($r.kind // null), msg: ($r.msg // null), title: $t,
      alive: (if $p == null then null else $p.last_exit == null and $p.child != null and
        ($w == "" or ($p.child.pid | tostring) == $w) end),
      cwd: ($p.foreground.cwd // $p.child.cwd // null)} + (if $a == "" then {} else {account: $a} end)'
}

cmd_screen() {
  target "${1:-}"
  case "${2:-60}" in '' | *[!0-9]*) die "screen: LINES takes a whole number, not '$2'" ;; esac
  local text; text=$(screen_text "$block") || fail "rex could not capture $block"
  # Drop the empty rows below the content first, or a short screen tails to blank lines.
  awk '{l[NR]=$0} NF{n=NR} END{for(i=1;i<=n;i++)print l[i]}' <<<"$text" | tail -n "${2:-60}"
}

cmd_keys() {
  need_me; target "${1:-}"; shift
  [ $# -gt 0 ] || die "keys: no keys given"
  owned keys
  alive_or_exit keys
  local rec scr k kind why safe=1
  rec=$(root_record "$block") || fail "keys: cannot read the state of $block; no key was pressed"
  for k in "$@"; do case "$k" in escape | esc | ctrl+c) ;; *) safe=0 ;; esac; done
  # escape and ctrl+c always pass; anything else waits for the refusals.
  if [ "$safe" -eq 0 ]; then
    kill_switch_stops keys "$rec"
    kind=$(pane_kind "$rec")
    why=$(stopped); [ -z "$why" ] || die "keys: $block is stopped ($why): only escape and ctrl+c; report it"
    # shift+tab cycles claude's permission mode, into accept edits or bypass.
    [ "$kind" != claude ] || for k in "$@"; do
      case "$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$k")" in shift+tab | btab | backtab | s-tab)
        die "keys: refusing $k for claude: it switches the session's permission mode; leave that to the user" ;; esac
    done
    scr=$(screen_text "$block") || fail "keys: cannot read the screen of $block; no key was pressed"
    pin_ok "$scr" "$rec" || { stop_pane "$pin_why"; exit 2; }
    # At a dialog on an uncaged pane (a question excepted), a key may only refuse, move, or pick a one-time answer:
    # never a persistent option ("always", "don't ask again", a session-wide grant, a remembered trust).
    if [ ! -f "$(state_file "$block").cage" ] && [ "$(jq -r '.kind // ""' <<<"$rec")" != question ] &&
      { dialog_on_screen "$scr" || jq -e '.state == "blocked" and (.kind == "permission" or .kind == "auth")' <<<"$rec" >/dev/null; }; then
      for k in "$@"; do
        case "$k" in
          escape | esc | ctrl+c | up | down) ;;
          enter | [0-9])
            [ $# -eq 1 ] || die "keys: at a dialog, press $k in a call of its own, after looking at the screen"
            { why=$(picked "$scr" "$k") && one_time "$why"; } ||
              die "keys: refusing $k at the dialog in $block: it would pick '${why:-no option it can read}', not a one-time Yes, No or Continue; leave it to the user" ;;
          *) die "keys: refusing $k at the dialog in $block: only escape, ctrl+c, up, down, and enter or a digit on a one-time answer; leave it to the user" ;;
        esac
      done
    fi
  fi
  # Keys answer inside a turn: only the report baseline moves. The background baseline and a carried hold stay the
  # send's, because a dialog hides Claude's footer and agy's shows the turn's own tasks.
  mark_since "$block" "$rec" || fail "keys: cannot save the state of $block; no key was pressed"
  # After "--": a key list that starts "-b BLOCK" must not move the keys to another pane.
  "$REX" send-key -s "$REX_SESSION" -b "$block" -- "$@" || fail "keys: rex could not press the keys in $block"
}

# Whether a root record was written by a program that still runs (live_record REC PROCESS): Rex keeps an idle, done or
# error record after its writer exits (agy, then /exit, in a shell pane). A record without an owner pid counts.
live_record() {
  local o; o=$(jq -r '.owner.pid // "" | tostring' <<<"$1")
  [ "$1" != "{}" ] && { [ -z "$o" ] || kill -0 "$o" 2>/dev/null ||
    jq -e --arg o "$o" 'any(.child.pid, .foreground.pid; tostring == $o)' <<<"$2" >/dev/null; }
}

cmd_ls() {
  local out id lbl proc rec mine
  out=$("$REX" block ls -s "$REX_SESSION" --json) || fail "rex could not list the blocks"
  # Terminal blocks only (a block with no flavor is skipped).
  out=$(jq -r '.blocks[]? | select((.flavor // "") | test("terminal")) | [.block_id, .label // ""] | @tsv' <<<"$out" 2>/dev/null) ||
    fail "rex returned a block list that isn't JSON"
  while IFS=$'\t' read -r id lbl; do
    [ -n "$id" ] && [ "$id" != "$me" ] || continue
    proc=$(rex_call "$id" process) || continue
    # Live panes only; an agent with a live status record, or a known agent that doesn't report (older Claude Code).
    jq -e '(.last_exit == null) and (.child != null)' <<<"$proc" >/dev/null || continue
    rec=$(root_record "$id") || rec="{}"
    if live_record "$rec" "$proc" || jq -e 'any(.foreground.argv0, .child.argv0;
        . != null and (split("/") | last | IN("claude", "codex", "grok", "agy", "muse")))' <<<"$proc" >/dev/null; then
      mine=false; [ -z "$me" ] || [ "$(state_line "$id" own 1)" != "$me" ] || mine=true
      printf '%s\t%s\n' "$id" "$(status_json "$id" | jq -c --arg l "$lbl" --argjson m "$mine" '. + {label: $l, mine: $m}')"
    fi
  done <<<"$out"
}

cmd_close() {
  # A pane the user already closed in Rex (a full ID rex no longer knows) still has its state and cage home removed.
  need_me; target "${1:-}" gone; owned close
  local sf leaf base; sf=$(state_file "$block")
  # Its agent may still run after a failed close: keep the state (ownership, the cage home) for a plain retry.
  close_block "$block" || fail "rex could not close $block; its state is kept: run close again"
  registry_remove "$block"
  # Remove the throwaway cage home first (its leaf name is in .cage): only a plain name directly under STATE_DIR/cage.
  if [ -f "$sf.cage" ]; then
    leaf=$(sed -n 1p "$sf.cage"); base=$(cd "$STATE_DIR/cage" 2>/dev/null && pwd -P) || base=""
    # A home that won't go is noted; the pane and its state still go.
    case "$leaf" in ''|*/*|.*) ;; *) [ -z "$base" ] || rmcage "${base:?}/${leaf:?}" || note "could not remove the cage home $base/$leaf" ;; esac
  fi
  # All of the pane's state: the mark, .hold, .own, .cage and anything else under its name.
  rm -rf "$sf" "$sf".*
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift
force=0 me=""
case "$cmd" in
  launch | send | wait | status | screen | keys | ls | close | claims)
    state_dir
    case "$cmd" in send | wait | keys | close) [ "${1:-}" != --force ] || { force=1; shift; } ;; esac
    # The caller's own pane, canonical. A REX_BLOCK rex doesn't know can't be any target; one rex can't look up could be.
    if [ "$cmd" != claims ] && [ -n "${REX_BLOCK:-}" ]; then
      rc=0; me=$(resolve "$REX_BLOCK" 2>/dev/null) || rc=$?
      case "$rc" in 0) ;; 3) me=$REX_BLOCK ;; *) fail "rex did not answer for REX_BLOCK $REX_BLOCK" ;; esac
    fi ;;
esac
case "$cmd" in
  clone) cmd_clone "$@" ;;
  claims) cmd_claims "$@" ;;
  launch) cmd_launch "$@" ;;
  send) cmd_send "$@" ;;
  wait) cmd_wait "$@" ;;
  status) cmd_status "$@" ;;
  screen) cmd_screen "$@" ;;
  keys) cmd_keys "$@" ;;
  ls) cmd_ls ;;
  close) cmd_close "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
