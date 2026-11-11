# Security policy

`rex-orchestrator` types into other agents' terminals and can run them in a sandbox, so bypasses matter. Please report:

- a way to make `send`, `keys` or `wait --approve-in` grant something persistent ("always", "don't ask again", a
  permission-mode switch, folder or hooks trust);
- a way to drive a pane the caller didn't launch, or the caller's own pane;
- a cage escape: a write outside DIR, a read of a denied path, a non-web connection, a denied mach service or tool;
- a planted file in DIR that runs unsandboxed later and isn't documented in [docs/cage.md](docs/cage.md).

**Do not open a public issue for these.** Use GitHub's private vulnerability reporting
(*Security* tab → *Report a vulnerability*) with steps to reproduce, the macOS, Rex and agent versions, and the output of the
failing command. You'll get an answer within a week.

Known limits that are documented and not considered vulnerabilities: HTTPS egress from the cage, build scripts in DIR
(`package.json`, `Makefile`, …), and terminal output written to other panes. See
[docs/cage.md](docs/cage.md#what-the-cage-does-not-cover).
