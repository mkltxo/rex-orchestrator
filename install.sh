#!/usr/bin/env bash
# Install rex-orchestrator by symlinking it into place, so `git pull` updates it.
#   ./install.sh [--agents LIST] [--skills-dir DIR]... [--bin-dir DIR] [--uninstall] [--dry-run]
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
NAME=rex-orchestrator
SKILL_SRC="$ROOT/skills/$NAME"
CLI_SRC="$SKILL_SRC/scripts/rex-orchestrator.sh"

bin_dir="$HOME/.local/bin"
agents="claude,agents"
extra_dirs=()
uninstall=0
dry=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Links the rex-orchestrator CLI and the $NAME skill. Nothing is copied.

  --agents LIST      Comma-separated skill targets (default: $agents):
                       claude  ~/.claude/skills   (Claude Code)
                       agents  ~/.agents/skills   (Codex, agy and other Agent Skills readers)
                       none    CLI only
  --skills-dir DIR   Also link the skill into DIR (repeatable), for any other agent
  --bin-dir DIR      Where to link the rex-orchestrator command (default: $bin_dir)
  --uninstall        Remove the links this script makes (only links that point here)
  --dry-run          Print what would change, change nothing
  -h, --help         This help

Agents without a skills folder: see docs/orchestrators.md for an instructions snippet.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agents) agents=${2:?--agents needs a value}; shift 2 ;;
    --skills-dir) extra_dirs+=("${2:?--skills-dir needs a value}"); shift 2 ;;
    --bin-dir) bin_dir=${2:?--bin-dir needs a value}; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'install.sh: unknown option %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

skill_dirs=()
IFS=, read -r -a targets <<<"$agents"
for a in "${targets[@]}"; do
  case "$a" in
    claude) skill_dirs+=("$HOME/.claude/skills") ;;
    agents) skill_dirs+=("$HOME/.agents/skills") ;;
    none | '') ;;
    *) printf 'install.sh: unknown agent target %s (use claude, agents or none)\n' "$a" >&2; exit 2 ;;
  esac
done
skill_dirs+=(${extra_dirs[@]+"${extra_dirs[@]}"})

# link SRC DEST: create a symlink, never replacing a real file or someone else's link.
link() {
  local src=$1 dest=$2
  if [ -L "$dest" ]; then
    [ "$(readlink "$dest")" = "$src" ] && { echo "ok         $dest"; return 0; }
    printf 'install.sh: %s is a link to %s; remove it first\n' "$dest" "$(readlink "$dest")" >&2
    return 1
  elif [ -e "$dest" ]; then
    printf 'install.sh: %s exists and is not a link; remove it first\n' "$dest" >&2
    return 1
  fi
  if [ "$dry" = 1 ]; then echo "would link $dest -> $src"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  echo "linked     $dest -> $src"
}

# unlink_ours DEST SRC: remove DEST only if it is our link.
unlink_ours() {
  local dest=$1 src=$2
  [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ] || return 0
  if [ "$dry" = 1 ]; then echo "would remove $dest"; else rm "$dest"; echo "removed    $dest"; fi
}

if [ "$uninstall" = 1 ]; then
  unlink_ours "$bin_dir/rex-orchestrator" "$CLI_SRC"
  for d in ${skill_dirs[@]+"${skill_dirs[@]}"}; do unlink_ours "$d/$NAME" "$SKILL_SRC"; done
  exit 0
fi

missing=()
for c in rex jq git python3; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
[ "$(uname -s)" = Darwin ] || echo "note: only macOS is tested; the cage (sandbox-exec) is macOS-only."
[ ${#missing[@]} -eq 0 ] || echo "note: not on PATH: ${missing[*]} (rex-orchestrator needs them at run time)."

status=0
link "$CLI_SRC" "$bin_dir/rex-orchestrator" || status=1
for d in ${skill_dirs[@]+"${skill_dirs[@]}"}; do link "$SKILL_SRC" "$d/$NAME" || status=1; done

case ":$PATH:" in *":$bin_dir:"*) ;; *) echo "note: add $bin_dir to PATH to run rex-orchestrator." ;; esac
if [ "$status" = 0 ] && [ "$dry" = 0 ]; then echo "done. Try: rex-orchestrator help"; fi
exit "$status"
