# rex-orchestrator

**Let one coding agent run other coding agents in [Rex](https://www.superlogical.com/rex) panes — safely.**

`rex-orchestrator` is a small CLI (plus an [Agent Skill](https://agentskills.io)) that any agent with a shell — Claude Code, Codex,
Grok, Gemini (agy), or your own — can use to open other agents side by side in Rex, hand them work, wait for each turn to finish,
and read the result. It waits on the agents' own **program status** (Rex's [OSC 7501 protocol](https://www.superlogical.com/rex/docs/build/program-status))
instead of guessing from the screen, and it puts guard rails around every keystroke it sends.

```text
┌─────────────────────────────────────┬───────────────────────────────┐
│ orchestrator (any agent)            │ child: claude   ● working     │
│                                     │                               │
│ $ rex-orchestrator launch -d app \  ├───────────────────────────────┤
│     -l tests --trust                │ child: codex    ✓ done        │
│ $ rex-orchestrator send $B "…"      │                               │
│ $ rex-orchestrator wait $B          │                               │
└─────────────────────────────────────┴───────────────────────────────┘
```

> **Status:** early, community-built, not affiliated with Superlogical. Tested on macOS with Rex 0.1 previews.
> Rex may ship native agent orchestration later; this project exists to show what that could look like and to be useful meanwhile.

## Why

Rex already gives you the building blocks — `rex split`, `rex send`, `rex capture`, and live agent status. What's missing is the
glue an agent needs to delegate reliably:

- **Know when a turn is really over.** `wait` returns on the child's own `done`, `blocked` or `error`, never on a stale report,
  and holds while background shells the turn started are still running.
- **Never type into the wrong place.** `send` only types at an idle input box; it refuses while a permission prompt or menu is up
  (a stray Return would pick "Yes"), and it never targets your own pane or a pane you didn't launch.
- **Answer dialogs the safe way.** Folder-trust dialogs are confirmed only when they name the exact directory; `keys` can pick a
  one-time *Yes/No* but never *always*, *don't ask again* or a mode switch.
- **Keep parallel work apart.** Each launch claims its writable directory or git branch; overlapping launches are refused.
- **Optional sandbox.** On macOS, children can run inside a `sandbox-exec` cage: writes only inside their directory, secret
  stores unreadable, no local ports, no privilege tools.

## Requirements

- macOS (the cage uses `sandbox-exec`; the rest is POSIX-ish but only tested on macOS)
- [Rex](https://www.superlogical.com/rex) with its `rex` CLI on `PATH`
- `bash`, `jq`, `git`, `python3`
- At least one agent CLI that reports Rex program status: `claude`, `codex`, `grok`, `agy` (Gemini)

## Install

```sh
git clone https://github.com/mikelaizpurua/rex-orchestrator.git
cd rex-orchestrator
./install.sh                 # CLI into ~/.local/bin + skill for Claude Code and ~/.agents/skills
./install.sh --help          # pick agents, a prefix, or a custom skills folder
```

The installer only creates symlinks, so `git pull` updates everything. `./install.sh --uninstall` removes them.

## Pick your orchestrator

The orchestrator is simply **whichever agent runs `rex-orchestrator`** inside a Rex pane. Nothing assumes Claude.
To reserve the role for one agent or account (say, your main Claude account), list it in
`~/.config/rex-orchestrator/orchestrators`; everyone else's `launch` is refused. See
[docs/orchestrators.md](docs/orchestrators.md#designating-the-orchestrator).

| Orchestrator | How it learns the tool |
|---|---|
| Claude Code | Skill in `~/.claude/skills/rex-orchestrator` |
| Codex, Gemini (agy) and other Agent Skills readers | Skill in `~/.agents/skills/rex-orchestrator` |
| Any other agent | Add the snippet from [docs/orchestrators.md](docs/orchestrators.md) to its instructions (`AGENTS.md`, system prompt…) |

Children can be any supported agent too, on any account: `--agent CMD` runs whatever command you name (a wrapper script that sets
another account's config works).

## Quick start

From a shell **inside a Rex pane** (the orchestrator's pane):

```sh
B=$(rex-orchestrator launch -d ~/code/app -l fix-tests --trust)   # opens a pane to the side, prints its block ID
rex-orchestrator send "$B" 'Run the tests, fix the failing one, write a summary to /tmp/REPORT.md.'
rex-orchestrator wait "$B" --timeout 900                            # done | blocked … | error … (see exit codes)
rex-orchestrator screen "$B" 30                                     # look at it
cat /tmp/REPORT.md
rex-orchestrator close "$B"
```

Launch another agent instead of Claude with `--agent codex` (or `grok`, `agy` for Gemini, any command), pass flags to it after `--`, and
run several children at once — each in its own directory or clone (`rex-orchestrator clone REPO DEST -b BRANCH`).

## Commands

| Command | What it does |
|---|---|
| `launch` | Open an agent in a new pane (or tab), answer its trust dialog if allowed, return when it's ready |
| `send` | Type a prompt at the child's input box (refuses if the child isn't ready) |
| `wait` | Block until the turn ends; `--approve-in DIR` can approve one-time file edits inside DIR |
| `keys` | Press keys (answer a dialog, interrupt) with persistent-grant guards |
| `screen` / `status` / `ls` | Read a child's screen, its state as JSON, or every agent pane in the session |
| `close` | Close the pane, end the agent, release its claim |
| `clone` / `claims` | Make an isolated checkout; list live directory claims |

Full reference with flags and exit codes: [docs/commands.md](docs/commands.md).

## How it works

```text
orchestrator ──rex split──▶ child pane ──OSC 7501──▶ Rex server ──rex block call program_status──▶ rex-orchestrator wait
             ──rex send───▶ (typed only at an idle input box)
             ──rex capture▶ screen (dialogs are parsed only to confirm, never to decide state)
```

State lives in `${XDG_STATE_HOME:-~/.local/state}/rex-orchestrator` (mode 700). Details: [docs/how-it-works.md](docs/how-it-works.md).

## Safety model

Children run with **your** rights (Rex's server starts every pane), not inside the orchestrator's sandbox. The tool therefore:

- drives only panes it launched (`--force` for a pane the user names) and never the caller's own pane;
- leaves every non-routine dialog to you (launch exits 3, wait exits 10) instead of answering it;
- refuses persistent grants (*always allow*, *don't ask again*, permission-mode switches) at any dialog;
- refuses prompts that agents would run as shell commands (`!…`);
- can cage children (macOS) — see [docs/cage.md](docs/cage.md) for exactly what the cage blocks and **what it does not**.

Read [docs/safety.md](docs/safety.md) before letting an agent orchestrate unattended.

## Supported agents

| Agent | Status reporting | Trust dialog | Cage |
|---|---|---|---|
| Claude Code (`claude`) | ✅ | ✅ | ✅ with a cage credential |
| Codex (`codex`) | ✅ | ✅ | ✅ |
| Grok (`grok`) | ✅ | ✅ | ✅ |
| Gemini (`agy` CLI) | ✅ | ✅ | ✅ with a cage home |
| Muse (`muse`) | ✅ | ✅ | — |
| Anything else (`--agent CMD`) | if it reports OSC 7501 | left to you | — |

Per-agent quirks (background shells, hook reviews, edit dialogs): [docs/supported-agents.md](docs/supported-agents.md).

## Development

```sh
tests/harness/run.sh     # fake-rex harness, no tokens, no real agents
tests/cage/zt.sh         # cage profile checks, no tokens
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Bugs and ideas welcome in Issues; security reports per [SECURITY.md](SECURITY.md).

## Credits

Started from the MIT-licensed `rex-claude` skill in [davila7/claude-code-templates](https://github.com/davila7/claude-code-templates)
by Daniel (San) Ávila, then extended into a multi-agent, agent-agnostic orchestrator. Rex is a product of
[Superlogical](https://www.superlogical.com); this project is independent.

## License

[MIT](LICENSE)
