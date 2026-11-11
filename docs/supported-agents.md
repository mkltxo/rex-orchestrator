# Agent notes

Every command works with any agent that reports Rex program status. `launch` picks dialog handling from the command's name
(`claude-*` and `agy-*` wrappers count as claude and Gemini); `--kind` names it for a command called otherwise.

## Claude Code (`claude`)

- Folder trust: "No, exit" is preselected; `--trust` moves to "Yes" and confirms. Below 10 rows Claude shows only the
  selected option; `launch` presses Down, then Enter once "Yes" shows.
- Its folder-trust dialog appears **before** Claude starts reporting status, so it has no status while it waits there.
- `send` refuses a prompt starting with a digit: Claude's session survey would take it as a rating.
- Background shells (`N shells` in the footer, or `✻ … · 1 shell still running`) hold `wait` until they end
  (see `--bg-max`). Below 8 rows Claude cuts its input box and the hold can't see the count: use a bigger pane.
- Draws on the alternate screen: `screen` shows only what is visible. Ask for results in a file at an absolute path (a
  Claude child may otherwise save it in its scratchpad).
- Startup dialogs such as "New MCP server found" (a project's `.mcp.json`) or a login menu are left to the user (exit 3).

## Codex (`codex`)

- Trust: Enter once the trusting option shows selected and the dialog names DIR.
- May stop at **"Hooks need review"**: `launch` exits 3 and `send` exits 4 there. Never trust hooks for the user.
- `launch` calls codex ready only once it reports a status and shows its composer footer (`? for shortcuts`).
- Reports `working` until every background terminal it started exits (`1 background terminal running · /ps to view`):
  `wait` holds with no `--bg-max` cap. Don't have a codex child start a long-running server, or read `screen` for the
  `Worked for …` line instead of waiting.
- As an **orchestrator**, Codex strips `REX_*` and Rex's PATH entry from its shell: the CLI falls back to the `rex` inside
  `Rex.app`/`Rex Beta.app` (or `REX_ORCHESTRATOR_REX_BIN_DIR`), and each call needs `REX_SESSION=… REX_BLOCK=…` in front, from the
  session-start text Rex's Codex hook prints.

## Grok (`grok`)

- Trust: `--trust` answers `y`, only on its exact "Yes, proceed y" / "No, quit n" form.
- Shows background commands in a tasks pane above its input (`▾ Tasks 1`); when one ends grok starts a turn by itself and
  reports nothing until `done`. `wait` holds while its footer shows a running turn, but `status`, `ls` and `send` still see
  the old `done`: `wait` before you `send` again.
- Uncaged, it runs in always-approve.

## Gemini (`agy` CLI)

- Trust: Enter once the trusting option shows selected.
- Uncaged, it asks before each file write (`wait` exits 10, `Approve WriteFile…`). Its edit dialog ignores Escape: refuse
  with `keys B 2`, or `keys B down` then `keys B enter` on "No, deny".
- In panes smaller than 80x24 it cuts dialog rows or columns; `launch` refuses (exit 2) when that hides the trust options.

## Muse (`muse`)

- Trust: Enter once the trusting option shows selected; small panes cut its dialog like Gemini's.
- An account without model access reports `error` with no message (`wait` exits 11): read the reason with `screen`.

## Adding an agent

An agent works out of the box if it reports OSC 7501 status. To support its dialogs (trust, startup prompts), add a `KIND`
in `rex-orchestrator.sh` (search for `pane_kind`), screen fixtures under `tests/harness/fixtures/`, and a fake agent in
`tests/harness/agents/`. See [CONTRIBUTING.md](../CONTRIBUTING.md).
