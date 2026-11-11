# The cage (macOS sandbox)

On macOS, `launch` can run a child under `sandbox-exec` with the profile [`cage.sb`](../skills/rex-orchestrator/scripts/cage.sb).
It is a filesystem, network-port and privilege boundary for agents you don't fully trust with your machine.

## When a child is caged

`REX_ORCHESTRATOR_CAGE=auto` (the default) cages every agent that has a **cage recipe**:

| Agent | Recipe | Needs |
|---|---|---|
| `codex` | always | its normal login (`auth.json` in `CODEX_HOME` or `~/.codex`, re-opened read-only) |
| `grok` | always | its normal login (`~/.grok/auth.json`, read-only) |
| `claude` | when a credential exists | `$CAGE_SECRETS/claude-NAME.env` containing `export CLAUDE_CODE_OAUTH_TOKEN=…` |
| `agy` (Gemini) | when a cage home exists | `$CAGE_SECRETS/agy-home` holding an agy login |
| others | none | run uncaged with a note |

`CAGE_SECRETS` defaults to `${XDG_CONFIG_HOME:-~/.config}/rex-orchestrator/cage-secrets`. `--no-cage` (or
`REX_ORCHESTRATOR_CAGE=off`) runs uncaged; `--cage` (or `REX_ORCHESTRATOR_CAGE=on`) fails for an agent without a recipe.

**Fail closed:** when an agent that should be caged can't be (missing profile, template or login, a DIR path the profile
can't express), `launch` exits 2 and never runs it uncaged instead.

### Setting up claude and Gemini (agy)

```sh
mkdir -p ~/.config/rex-orchestrator/cage-secrets && chmod 700 ~/.config/rex-orchestrator/cage-secrets
# claude: a token that can only make model requests
claude setup-token        # then:
printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "<token>" > ~/.config/rex-orchestrator/cage-secrets/claude-work.env
chmod 600 ~/.config/rex-orchestrator/cage-secrets/claude-work.env
# Gemini (agy): log in into a dedicated home (answer Cancel to the keychain dialog so the token lands in a file)
HOME=~/.config/rex-orchestrator/cage-secrets/agy-home agy
```

With several `claude-*.env` files, `--account NAME` picks one; without it the only file is used, otherwise the
alphabetically first, and `launch` says which. `status` shows it as `account`.

## What a caged child gets

- A clean environment (`env -i`): no `REX_*`, no `SSH_AUTH_SOCK`, no tokens — only terminal and locale variables.
- A throwaway config home under `STATE_DIR/cage/` built from the templates in `scripts/cage/`, **not your settings**: pass a
  model and other options after `--`. It has none of your MCP servers, connectors, skills, plugins, hooks or memory.
- codex runs in bypass mode and grok in always-approve, with their own sandboxes off (seatbelt doesn't nest); a caged Gemini (agy)
  runs with `--dangerously-skip-permissions`. The cage is the boundary, so there are no approval dialogs.
- A caged claude gets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, so the shells, hooks and MCP servers it starts don't inherit its
  token; its tools are pre-allowed in the cage settings so it still runs without prompts.
- On `close`, transcripts and logs are harvested into `STATE_DIR/runs/<label>-<UTC>/` (mode 700) with a `manifest.json`
  (agent, account, paths, SHA-256 hashes). Credentials, env files, settings and links are never copied.

## What the cage denies

- **Writes** anywhere but DIR, the child's own cage home and terminal devices — also through symlinks, renames and hard
  links. Even inside DIR: the cage secrets, this tool's folder, `~/.ssh`, `~/.local/bin`, `~/.agents`,
  `~/Library/LaunchAgents`, `/opt/homebrew`, `/Applications` and every agent home.
- **Auto-run files inside DIR** that would execute unsandboxed later: `.git/hooks/`, `.git/config`, `.envrc`, `.mcp.json`,
  `.claude/`, `.codex/`, `.gemini/`, `.grok/`, `.cursor/`, `.zed/`, `.vscode/`, `.idea/`, `.husky/`, `.githooks/`,
  `.agents/`, and a repo's own `core.hooksPath`. (So `git init`/`git config` fail in the cage: create the repo first.)
- **Reads** of secret stores and agent homes: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config` (except `git`),
  `~/Library/Keychains`, shell histories, Messages, Mail, every `~/.claude*`, `~/.codex*`, `~/.grok*`, `~/.gemini*`, other
  agents' folders in `~/Library/Application Support`, other cage homes, other Claude sessions' temp files, and every repo
  under `~/Repos` except DIR's.
- **Network** on any port but 443, 80 and 53, loopback included; every unix socket but DNS's (so no Rex, no ssh-agent).
- **Mach services** outside a 7-name allowlist (TLS, DNS, user lookup): no LaunchServices, AppleEvents, clipboard,
  WindowServer, TCC; no `iokit-open`; no signals outside the cage; no `sudo`, `launchctl`, `osascript`, `open`, `ssh`,
  `scp`, `sftp`, `crontab`, `at`, `batch`.

`launch` also refuses a caged DIR that *is, holds or sits in* any of the protected locations above, or is `/`, `/Users`,
your home, `~/Library` or `~/Repos`: give each task its own folder.

## What the cage does NOT cover

- **Egress.** HTTPS to any host stays open for the model API, so a caged agent can send out anything it can read, its
  re-opened login token included.
- **DIR is attacker-written.** Build steps that run code (`package.json` scripts, `.npmrc`, `pyproject.toml`, `Makefile`,
  `.devcontainer/`, `.gitattributes` filters) aren't locked, nor are symlink or gitdir-file reroutes. **Review DIR's diff
  before running anything against it uncaged** — git (hooks fire on checkout/merge), direnv, an editor, another agent,
  `npm install`, a build.
- **TLS services** (`com.apple.SecurityServer`, `trustd.agent`) are reachable; safe only while keychain files stay
  read-denied.
- **Rex.** A caged agent can't reach Rex, so it can't orchestrate children itself; such a parent needs `--no-cage`.
- **Terminals.** `/dev/tty*` stays writable so tools that open a sub-pty work: a caged child could print onto another pane's
  screen (not type into it). Never trust a screen on its own.

## Harmless messages

codex's `⚠ 1 warning` at start (its worktree tools can't reach their local server) and a `git` `xcrun` cache "Operation not
permitted" line are expected inside the cage.
