# Command reference

`rex-orchestrator help` prints the authoritative reference for your installed version. This page explains the same commands with
more context. Conventions:

- **BLOCK** is any form `rex` accepts (full ID, short ID, label); the tool works on the full ID it resolves to.
- **DUR** is `N`, `Ns`, `Nm` or `Nh`.
- Every command exits **2** on a usage error or a refusal and **1** when a `rex` call it needs fails.
- `launch`, `send`, `keys`, `close` and `wait --approve-in` need `REX_SESSION` and `REX_BLOCK` (Rex sets both in every pane).

## launch

```text
rex-orchestrator launch [-d DIR] [-l LABEL] [--split right|left|above|below] [--ratio PCT] [-b ANCHOR] [--tab NAME]
                  [--trust] [--focus] [--timeout DUR] [--agent CMD] [--kind KIND] [--cage|--no-cage]
                  [--account NAME] [--allow-edits] [--allow RULE]... [-- AGENT_ARGS...]
```

Opens a pane running the agent in `DIR` (default: current directory) and returns once it is ready for a prompt: no dialog
on screen, a status that isn't `working` or `blocked`, and its input footer or an idle status, seen twice in a row.

| Option | Meaning |
|---|---|
| `-d`, `--dir DIR` | Working directory of the child |
| `-l`, `--label LABEL` | Pane label (default `claude`) |
| `--agent CMD` | Agent command to run (default `claude`); any wrapper on your `PATH` works |
| `--kind KIND` | Dialog handling to use (`claude`, `codex`, `grok`, `agy` (Gemini), `muse`) when CMD's name doesn't say |
| `--split DIR`, `-b ANCHOR`, `--ratio PCT` | Split ANCHOR (default: your pane) in that direction, the new pane taking PCT % (default 50) |
| `--tab NAME` | Open a tab instead of a split (80x24 unless focused) |
| *(no placement flag)* | Split the largest pane of your window along its longer side, so every child stays in view |
| `--focus` | Focus the new pane (by default you keep focus) |
| `--trust` | Confirm the folder-trust dialog, only once it names DIR |
| `--timeout DUR` | How long to wait for readiness (default 90s) |
| `--cage` / `--no-cage` | Force or skip the macOS sandbox ([cage.md](cage.md)); default from `REX_ORCHESTRATOR_CAGE` (`auto`) |
| `--account NAME` | Credential for a caged claude: `$CAGE_SECRETS/claude-NAME.env` |
| `--allow-edits` | claude only: read and edit inside DIR without asking, for this session |
| `--allow RULE` | claude only, repeatable: add a permission rule such as `'Bash(npm test:*)'` |
| `-- ARGS` | Passed to the agent (`--model`, `--permission-mode default`, `--settings`, …) |

`--allow-edits` and `--allow` use `--settings`, so they can't be combined with `-- --settings` (put the rules in its
`permissions.allow` instead).

An uncaged child receives only `CLAUDE_CONFIG_DIR` and `CODEX_HOME` from your environment (paths, on its command line), plus
`CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1` for claude: Claude's session survey would otherwise take a one-character prompt as
its answer. It runs on whatever account its command uses.

| Exit | Meaning |
|---|---|
| 0 | Ready for a prompt (block ID on stdout) |
| 1 | `rex` failed; no pane to use |
| 2 | Usage error or refusal; no pane left open. Examples: no `REX_BLOCK`, a caller that isn't a designated orchestrator, unknown agent, a cage that can't be built, an overlapping write claim, a kill switch, an uncaged claude in bypass mode, a pane too small to show the trust dialog's options |
| 3 | A dialog left for the user: trust without `--trust`, a trust dialog that doesn't name DIR, Codex's hook review, an MCP-server or login prompt; or `--trust` made the agent trust an *ancestor* of DIR (this also sets the agent's kill switch) |
| 12 | The agent exited during startup (end of its screen on stderr) |
| 124 | Not ready within `--timeout` (end of its screen on stderr) |

On 3, 12 and 124 the pane stays open and its ID is printed. If `launch` is interrupted or fails before reporting, it closes
its pane and removes its state.

## send

```text
rex-orchestrator send [--force] BLOCK TEXT...
rex-orchestrator send [--force] BLOCK -f FILE
```

Types the prompt at the child's input box and presses Return. Newlines become spaces. A leading `/` runs a slash command.

It **refuses** (exit 2): an empty prompt; one starting with `!` (agents run it as a shell command without asking); for claude,
one starting with a digit (Claude's survey would take it as a rating); for an uncaged claude, `/permissions`,
`/allowed-tools`, `/config`, `/settings`, `/add-dir`, `/hooks`, `/plugin`, `/mcp` or a prefix of one (each widens what the
child may do for the rest of the session — scope permissions at launch instead).

It types **only at an idle input box**: while the child works or shows a dialog, a Return would pick the highlighted option.

| Exit | Meaning |
|---|---|
| 0 | Sent |
| 4 | Not ready for input (working, a dialog, or the text typed but not shown — then typed, not submitted) |
| 12 | The agent exited |

## wait

```text
rex-orchestrator wait [--force] BLOCK [--timeout DUR] [--ignore-background] [--bg-max DUR] [--approve-in DIR]
```

Waits for the turn started by the last `send` or `keys` and prints the final state. Only reports made after that point
count, so a previous turn's `done` can't end it — start `wait` after `send` returns, never before.

A turn that ends with **more background work than at the send** (Claude's `N shells`, Gemini's `N tasks`, grok's tasks pane)
is held until that work ends and the agent has had 20s to resume, at most `--bg-max` (default 300s).
`--ignore-background` returns as soon as the turn ends.

| Exit | Output | Meaning |
|---|---|---|
| 0 | `done` / `idle` | The turn finished |
| 10 | `blocked permission approve Write: /path`, or `stopped` | Waiting on a person (permission, question, login), or the pane was stopped |
| 11 | `error …` | The agent reported an error |
| 12 | `exited` | The agent is gone |
| 124 | `timeout (state=working)` | Still running: wait again or look at the screen |

`--approve-in DIR` is covered in [safety.md](safety.md#wait---approve-in).

## keys

```text
rex-orchestrator keys [--force] BLOCK KEY...
```

Presses keys: `enter`, `escape`, `up`, `down`, `tab`, `ctrl+c`, digits… At a dialog on an uncaged pane, only `escape`,
`ctrl+c`, `up` and `down` always pass; `enter` or a digit passes only alone in its call and only when the option it picks is a
one-time Yes, No or Continue. `shift+tab` (which cycles Claude's permission mode) is refused for claude. See
[safety.md](safety.md).

## screen, status, ls

- `screen BLOCK [LINES]` — the last LINES visible rows (default 60). Agents draw on the alternate screen, so only what is
  visible now is available: ask children to write results to a file.
- `status BLOCK` — one-line JSON: `state`, `kind`, `msg` (the pending prompt), `title`, `alive`, `cwd`, and `account` for a
  caged claude.
- `ls` — live agent panes in the session: block ID, a tab, the status JSON plus `label` and `mine` (launched from your pane).

## close

```text
rex-orchestrator close [--force] BLOCK
```

Closes the pane (ending its agent), harvests a caged child's transcripts into `STATE_DIR/runs/`, and removes its state and
cage home. Works for a pane already closed in Rex, given its full ID. If `rex` can't close it, `close` exits 1 and keeps the
state: run it again.

## clone, claims

Every launch claims its writable DIR across Rex sessions; an overlapping launch exits 2 and names the holder.
Git checkouts conflict on the same checkout root, or the same repository and branch; other folders when one contains the
other. Claims are released by `close` and pruned when the pane or the agent process is gone.

- `clone REPO DEST [-b BRANCH]` — a standalone checkout (APFS copy-on-write, falling back to `git clone --local`), `.git`
  inside DEST. Prefer it to `git worktree` for caged children: a worktree's metadata lives outside DIR, where the cage can't write.
- `claims [--json]` — live claims across sessions.

Neither needs a Rex pane.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `REX_ORCHESTRATOR_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/rex-orchestrator` | Pane state, claims, kill switches, harvested runs (mode 700) |
| `REX_ORCHESTRATOR_CAGE_SECRETS` | `${XDG_CONFIG_HOME:-~/.config}/rex-orchestrator/cage-secrets` | Cage credentials ([cage.md](cage.md)) |
| `REX_ORCHESTRATOR_CAGE` | `auto` | Cage default: `auto`, `on` or `off` |
| `REX_ORCHESTRATOR_CAGE_PROFILE`, `REX_ORCHESTRATOR_CAGE_TPL`, `REX_ORCHESTRATOR_CAGE_AGY_HOME` | beside the script | Other cage assets |
| `REX_ORCHESTRATOR_REX_BIN_DIR` | `rex` on `PATH`, else the Rex app bundle | Where the `rex` CLI lives |
| `REX_ORCHESTRATOR_CONFIG_DIR` | `${XDG_CONFIG_HOME:-~/.config}/rex-orchestrator` | Holds `orchestrators`, the designated orchestrators ([orchestrators.md](orchestrators.md)) |

## Kill switches

A file `STATE_DIR/disabled` stops every launch and every `send`/`keys` but `escape` and `ctrl+c`.
`STATE_DIR/disabled.AGENT` stops that agent's uncaged launches, approvals and typing into its uncaged panes. The tool sets
one itself when an agent's trust store or permission mode changes unexpectedly. Anyone may create one; only a person
should remove one.
