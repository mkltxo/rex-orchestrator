#!/usr/bin/env python3
"""Best effort allowlisted archival; never follow links or copy config/auth."""
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

PATTERNS = {
 'claude': ['claude-config/projects/*.jsonl', 'home/.claude/projects/*.jsonl'],
 'codex': ['codex-home/sessions/*.jsonl'],
 'grok': ['home/.grok/sessions/*/chat_history.jsonl', 'home/.grok/sessions/*/updates.jsonl',
          'home/.grok/sessions/*/prompt_history.jsonl', 'home/.grok/sessions/*/terminal/*.log', 'home/.grok/logs/*.log'],
 'agy': ['home/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript*.jsonl',
         'home/.gemini/antigravity-cli/log/cli-*.log', 'home/.gemini/antigravity-cli/history.jsonl'],
}
# fnmatch's * includes separators, intentionally including nested subagent sessions.
def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def harvest(home, state):
    home, state = Path(home), Path(state)
    if home.is_symlink():
        raise OSError('cage home is a symlink')
    errors, meta = [], {}
    try:
        if not (home / 'run-meta.json').is_symlink():
            meta = json.loads((home / 'run-meta.json').read_text())
    except (OSError, ValueError) as exc:
        errors.append('run metadata unavailable: ' + str(exc))
    if not isinstance(meta, dict):
        errors.append('run metadata is not an object')
        meta = {}
    kind = str(meta.get('kind', home.name.split('.')[0]))
    family = 'agy' if kind.startswith('agy-') else kind
    label = str(meta.get('label', home.name))
    safe = re.sub(r'[^a-zA-Z0-9_-]', '_', label)[:100] or 'run'
    runs = state / 'runs'
    if runs.is_symlink():
        raise OSError('runs directory is a symlink')
    runs.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(runs, 0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    dest = runs / (safe + '-' + stamp)
    dest.mkdir(mode=0o700)
    manifest = {k: meta.get(k, 'unknown') for k in ('kind', 'account', 'label', 'block', 'DIR', 'start_time')}
    manifest.update(kind=kind, label=label, end_time=now(), files=[], errors=errors)
    if family not in PATTERNS:
        errors.append('unknown cage kind: ' + kind)
    def walk_error(error):
        errors.append(str(error))
    for root, dirs, files in os.walk(home, followlinks=False, onerror=walk_error):
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]
        for name in files:
            src = Path(root) / name
            rel = src.relative_to(home)
            if not any(fnmatch.fnmatchcase(str(rel), p) for p in PATTERNS.get(family, [])):
                continue
            if any(re.search(r'auth|credential|token|keychain|settings|\.env(?:$|\.)', p, re.I) for p in rel.parts):
                continue
            try:
                fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, 'rb') as inp:
                    if not stat.S_ISREG(os.fstat(inp.fileno()).st_mode):
                        continue
                    data = inp.read()
                target = dest / rel
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with target.open('xb') as out:
                    os.chmod(target, 0o600)
                    out.write(data)
                manifest['files'].append({'path': str(rel), 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
            except OSError as exc:
                errors.append(str(rel) + ': ' + str(exc))
    (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    os.chmod(dest / 'manifest.json', 0o600)
    for error in errors:
        print('rex-orchestrator: harvest: ' + error, file=sys.stderr)
    return dest


if __name__ == '__main__':
    try:
        harvest(sys.argv[1], sys.argv[2])
    except Exception as exc:
        print('rex-orchestrator: harvest failed: ' + str(exc), file=sys.stderr)
        sys.exit(1)
