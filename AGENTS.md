# Notes for coding agents working on this repository

This file is for agents *editing this repo*. To *use* the tool, read `skills/rex-orchestrator/SKILL.md`.

- Read `CONTRIBUTING.md` first. Run `tests/install_test.sh`, `tests/harness/run.sh` and `tests/cage/zt.sh` before
  proposing a change; they need no tokens and start no real agents.
- `skills/rex-orchestrator/scripts/rex-orchestrator.sh` must stay Bash 3.2 compatible and `shellcheck`-clean.
- Never relax a guard (ownership, dialog checks, the cage profile) without a test that shows why it is safe.
- Do not run live agents or spend tokens in tests. Do not touch Rex's server.
- Keep docs in sync: `rex-orchestrator help`, `SKILL.md` and `docs/commands.md` describe the same flags and exit codes.
