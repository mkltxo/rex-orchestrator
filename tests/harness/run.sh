#!/bin/bash
# Run every harness scenario and unit check under /bin/bash (3.2) and, if present, /opt/homebrew/bin/bash (5.3),
# both bashes at once. Prints passed/total per bash and the failing checks; exits 1 if any failed.
#   tests/harness/run.sh [NAME_SUBSTRING ...]   (selects scenario functions, e.g. t_approve; unit checks always run)
# REX_ORCHESTRATOR_SH picks the script under test; HARNESS_RUNS keeps the runs somewhere known (default: a new temp dir).
set -u
here=$(cd "$(dirname "$0")" && pwd)
runs=${HARNESS_RUNS:-$(mktemp -d "${TMPDIR:-/tmp}/rex-orchestrator-harness.XXXXXX")}
bashes=/bin/bash
[ -x /opt/homebrew/bin/bash ] && bashes="$bashes /opt/homebrew/bin/bash"
# shellcheck disable=SC2016  # the inner bash expands it
ver() { "$1" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"'; }

for b in $bashes; do
  v=$(ver "$b")
  mkdir -p "$runs/bash-$v"
  (
    export HARNESS_BASH="$b" HARNESS_RUNS="$runs/bash-$v"
    python3 -I "$here/harness.py" "$@" || echo "FAIL  harness.py exited $?"
    python3 -I "$here/harness2.py" "$@" || echo "FAIL  harness2.py exited $?"
    python3 -I "$here/harness4.py" "$@" || echo "FAIL  harness4.py exited $?"
    "$b" "$here/unit.sh" || echo "FAIL  unit.sh exited $?"
  ) >"$runs/bash-$v.log" 2>&1 &
done
wait

fail=0
for b in $bashes; do
  v=$(ver "$b")
  log="$runs/bash-$v.log"
  p=$(grep -c '^PASS' "$log"); f=$(grep -c '^FAIL' "$log")
  echo "bash $v: $p/$((p + f)) passed"
  grep '^FAIL' "$log" | cut -f1 | sed 's/^FAIL  /  FAIL /' | sort
  [ "$f" -eq 0 ] && [ "$p" -gt 0 ] || fail=1
done
echo "logs and runs: $runs"
exit "$fail"
