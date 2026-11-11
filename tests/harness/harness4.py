#!/usr/bin/env python3
"""Public-command checks for write claims and independent task clones."""
import concurrent.futures, glob, json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as h
from harness import Run, result, fmt, CHILD, CL_READY, rec, launch_scn


def case(tag, screen=CL_READY, **kw):
    return Run('registry-' + tag, launch_scn([
        {'name': 'ready', 'records': [rec('idle', 1)], 'screen': screen}], **kw))


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.STDOUT, text=True).strip()


def repo(r):
    d = os.path.join(r.d, 'source'); os.makedirs(d)
    git('init', '-b', 'main', d)
    git('-C', d, '-c', 'user.name=Harness', '-c', 'user.email=harness@example.test',
        '-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-m', 'initial')
    return d


def launch(r, d):
    return r.sh('launch', '-d', d, '--label', 'claim-holder', '--timeout', '8')


def outside_rex(r, *args, no_rex=False):
    env = dict(r.env)
    env.pop('REX_SESSION', None); env.pop('REX_BLOCK', None)
    if no_rex: env['REX_ORCHESTRATOR_REX_BIN_DIR'] = os.path.join(r.d, 'no-rex-installation')
    p = subprocess.run([h.BASH, r.rc, *args], env=env, capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, timeout=30)
    return p


def claims(r):
    q = r.sh('claims', '--json')
    try:
        rows = json.loads(q['out'])
        if isinstance(rows, dict): rows = rows.get('claims', [rows])
    except ValueError:
        rows = [json.loads(s) for s in q['out'].splitlines() if s]
    return q, rows


def reopen_fixture(r):
    # This fake reuses one fixed ID for each split, whereas Rex assigns a new one.
    p = os.path.join(r.d, 'state.json'); state = json.load(open(p))
    state['blocks'].pop(CHILD, None)
    with open(p, 'w') as f: json.dump(state, f)


def pair(tag, paths, refused):
    r = case(tag); a, b = paths(r)
    one = launch(r, a); n = len(r.calls('split')); two = launch(r, b)
    ok = one['rc'] == 0 and two['rc'] == (2 if refused else 0)
    if refused:
        ok = ok and len(r.calls('split')) == n and all(s in two['err'] for s in ('claim-holder', CHILD, 'session:fake', 'clone'))
    result('claims: ' + tag, 'two launches', 'second refused without pane' if refused else 'both succeed',
           f'first {fmt(one)}; second {fmt(two)}', ok)


def t_claim_conflicts():
    def checkout(r):
        d = repo(r); sub = os.path.join(d, 'sub'); os.makedirs(sub); return d, sub
    pair('same-checkout', checkout, True)
    def independent(r):
        d = repo(r); b = os.path.join(r.d, 'clone'); git('clone', '--local', d, b); return d, b
    pair('independent-clone-same-branch', independent, False)
    def worktree(r):
        d = repo(r); b = os.path.join(r.d, 'worktree'); git('-C', d, 'worktree', 'add', '--force', b, 'main'); return d, b
    pair('shared-common-dir-same-branch', worktree, True)
    def nested(r):
        d = os.path.join(r.d, 'plain'); b = os.path.join(d, 'nested'); os.makedirs(b); return d, b
    pair('non-git-nested', nested, True)
    def reverse(r):
        a, b = nested(r); return b, a
    pair('non-git-containing', reverse, True)
    def mixed(r):
        d = repo(r); return r.d, d
    pair('non-git-parent-git-child', mixed, True)
    def mixed_reverse(r):
        a, b = mixed(r); return b, a
    pair('git-child-non-git-parent', mixed_reverse, True)
    def symlink(r):
        d = repo(r); b = os.path.join(r.d, 'alias'); os.symlink(d, b); return d, b
    pair('symlink-alias', symlink, True)
    if os.path.realpath('/tmp') == os.path.realpath('/private/tmp'):
        # Give the repo a link under /private/tmp and address that same link through both /tmp spellings; wherever the
        # checkout lives (it failed from ~/Repos when the link was put in the checkout).
        import tempfile
        try:
            base = tempfile.mkdtemp(prefix='rxreg-', dir='/private/tmp')
        except OSError as e:
            result('claims: tmp-private-tmp-alias', 'two distinct /tmp alias spellings', 'a link under /private/tmp',
                   f'cannot make the alias fixture: {e}', False)
        else:
            link = os.path.join(base, 'alias')
            try:
                def alias(r):
                    os.symlink(repo(r), link)
                    return link, '/tmp/' + link[len('/private/tmp/'):]
                pair('tmp-private-tmp-alias', alias, True)
            finally:
                if os.path.lexists(link): os.unlink(link)
                os.rmdir(base)


def t_claim_lifecycle():
    r = case('close'); d = repo(r); one = launch(r, d); q, rows = claims(r)
    result('claims: live JSON listing', 'claims --json', 'one claim with block, pid, label', f'{fmt(q)}; rows={rows}',
           one['rc'] == 0 and q['rc'] == 0 and len(rows) == 1 and rows[0].get('block') == CHILD and
           rows[0].get('label') == 'claim-holder' and int(rows[0].get('pid', 0)) > 0)
    outside = outside_rex(r, 'claims', '--json')
    result('claims: listing without caller session or block', 'unset REX_SESSION and REX_BLOCK', 'same live claim',
           f'rc={outside.returncode}; out={outside.stdout!r}; err={outside.stderr!r}',
           outside.returncode == 0 and outside.stdout.strip() == q['out'])
    plain = r.sh('claims')
    result('claims: human listing', 'claims', 'holder on one line', fmt(plain),
           plain['rc'] == 0 and len(plain['out'].splitlines()) == 1 and 'claim-holder' in plain['out'])
    close = r.sh('close', CHILD); q, rows = claims(r); reopen_fixture(r); two = launch(r, d)
    result('claims: close releases claim', 'close, claims, launch', 'empty claims, successful launch',
           f'close {fmt(close)}; rows={rows}; launch {fmt(two)}', close['rc'] == 0 and not rows and two['rc'] == 0)
    for stale in ('dead-pid', 'missing-block'):
        r = case(stale); d = repo(r); one = launch(r, d)
        if stale == 'dead-pid':
            for p in glob.glob(os.path.join(r.state_dir(), 'registry', '*.json')):
                row = json.load(open(p)); row['pid'] = 2147483647
                with open(p, 'w') as f: json.dump(row, f)
        else:
            p = os.path.join(r.d, 'state.json'); state = json.load(open(p)); state['blocks'][CHILD]['closed'] = True
            with open(p, 'w') as f: json.dump(state, f)
        q, rows = claims(r)
        if stale == 'missing-block': reopen_fixture(r)
        two = launch(r, d)
        result('claims: prunes ' + stale, 'stale holder, claims, launch', 'empty claims, successful launch',
               f'first {fmt(one)}; rows={rows}; second {fmt(two)}', one['rc'] == 0 and q['rc'] == 0 and not rows and two['rc'] == 0)
    for tag, kwargs in [('split-failure', {'create_rc': 1}), ('after-pane-failure', {})]:
        # After the pane opens: an uncaged claude whose footer shows bypass mode is refused at ready.
        r = case(tag, **kwargs) if kwargs else case(tag, CL_READY.replace('⏸ manual mode on', '⏵⏵ bypass permissions on'))
        d = repo(r)
        failed = launch(r, d); q, rows = claims(r)
        result('claims: ' + tag + ' leaves no claim', 'failed launch, claims', 'nonzero launch, empty claims',
               f'launch {fmt(failed)}; rows={rows}', failed['rc'] != 0 and q['rc'] == 0 and not rows and
               (bool(kwargs) or len(r.calls('split')) == 1 and len(r.calls('close')) == 1))


def t_claim_concurrent():
    r = case('concurrent', split_delay=0.2); d = repo(r)
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        out = list(pool.map(lambda _: launch(r, d), range(2)))
    q, rows = claims(r)
    result('claims: concurrent launch has one winner', 'simultaneous launches', 'one rc 0, one rc 2, one split, one claim',
           f'launches={[fmt(x) for x in out]}; splits={len(r.calls("split"))}; rows={rows}',
           sorted(x['rc'] for x in out) == [0, 2] and len(r.calls('split')) == 1 and len(rows) == 1)


def t_clone():
    r = case('clone'); source = repo(r); before = git('-C', source, 'status', '--porcelain=v1', '--branch')
    dest = os.path.join(r.d, 'destination'); q = r.sh('clone', source, dest, '-b', 'task')
    result('clone: independent metadata and new branch', 'clone REPO DEST -b task', 'DEST owns .git, source unchanged',
           fmt(q), q['rc'] == 0 and q['out'] == dest and os.path.isdir(os.path.join(dest, '.git')) and
           git('-C', dest, 'symbolic-ref', '--short', 'HEAD') == 'task' and git('-C', source, 'status', '--porcelain=v1', '--branch') == before)
    again = r.sh('clone', source, dest)
    result('clone: destination must not exist', 'clone into existing DEST', 'nonzero, clone intact', fmt(again),
           again['rc'] != 0 and git('-C', dest, 'symbolic-ref', '--short', 'HEAD') == 'task')
    dest2 = os.path.join(r.d, 'outside-destination')
    outside = outside_rex(r, 'clone', source, dest2, no_rex=True)
    result('clone: works without Rex or caller session', 'unset REX_SESSION and REX_BLOCK, unavailable REX_ORCHESTRATOR_REX_BIN_DIR',
           'clone succeeds with its own .git', f'rc={outside.returncode}; out={outside.stdout!r}; err={outside.stderr!r}',
           outside.returncode == 0 and outside.stdout.strip() == dest2 and os.path.isdir(os.path.join(dest2, '.git')))


if __name__ == '__main__':
    h.main([t_claim_conflicts, t_claim_lifecycle, t_claim_concurrent, t_clone], 'harness4')
