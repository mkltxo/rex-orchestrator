#!/usr/bin/env bash
# Tests for install.sh in a throwaway HOME: dry run, install, idempotence, uninstall, refusal to clobber.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0

check() { # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi
}
inst() { env HOME="$T" PATH="/usr/bin:/bin" "$ROOT/install.sh" "$@"; }
links() { find "$T" -type l | wc -l | tr -d ' '; }

check "dry run plans 3 links" 3 "$(inst --dry-run | grep -c 'would link')"
check "dry run creates nothing" 0 "$(links)"

inst >/dev/null
check "install creates 3 links" 3 "$(links)"
check "CLI link target" "$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh" "$(readlink "$T/.local/bin/rex-orchestrator")"
check "claude skill link" "$ROOT/skills/rex-orchestrator" "$(readlink "$T/.claude/skills/rex-orchestrator")"
check "re-install is idempotent" 3 "$(inst | grep -c '^ok')"

check "uninstall removes 3 links" 3 "$(inst --uninstall | grep -c removed)"
check "nothing left" 0 "$(links)"

mkdir -p "$T/.local/bin" && touch "$T/.local/bin/rex-orchestrator"
inst --agents none >/dev/null 2>&1
check "refuses to replace a real file" 1 "$?"
check "real file kept" "file" "$([ -f "$T/.local/bin/rex-orchestrator" ] && [ ! -L "$T/.local/bin/rex-orchestrator" ] && echo file)"

inst --agents bogus >/dev/null 2>&1
check "unknown agent target exits 2" 2 "$?"

mkdir -p "$T/custom"
inst --agents none --skills-dir "$T/custom" >/dev/null 2>&1 || true
check "--skills-dir links the skill" "$ROOT/skills/rex-orchestrator" "$(readlink "$T/custom/rex-orchestrator")"

printf 'install_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
