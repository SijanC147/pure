#!/usr/bin/env python3
"""Exercise real prompt substitution, async redraw, and job state in a PTY.

PURE_ROOT may point to an untrusted candidate; this file can live outside it.
Only Python's standard library is required. No user configuration is sourced.
"""
import errno
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(os.environ.get('PURE_ROOT', Path(__file__).resolve().parent.parent)).resolve()
ZSH = os.environ.get('ZSH_BIN', shutil.which('zsh') or 'zsh')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')

with tempfile.TemporaryDirectory(prefix='pure-pty-') as directory:
    home = Path(directory)
    repo = home / 'repo'
    repo.mkdir()
    env = {key: value for key, value in os.environ.items()
           if key != 'FPATH' and not key.startswith(('GIT_', 'AWS_', 'ZSH_', 'CONDA', 'VIRTUAL_ENV', 'PURE_', 'PROMPT_PURE'))}
    env.update(HOME=str(home), ZDOTDIR=str(home), TERM='xterm-256color', LC_ALL='en_US.UTF-8')
    subprocess.run(['git', 'init', '-q', str(repo)], env=env, check=True)
    subprocess.run(['git', '-C', str(repo), 'checkout', '-qb', 'pty-branch'], env=env, check=True)
    subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Pure tests', '-c', 'user.email=pure@example.invalid',
                    'commit', '--allow-empty', '-qm', 'fixture'], env=env, check=True)
    marker = home / 'EXECUTED'
    (home / '.zshrc').write_text(f'''
setopt no_beep
fpath=({shlex.quote(str(ROOT))} $fpath)
PURE_GIT_PULL=0
PURE_PROMPT_SYMBOL='PURE_READY>'
AWS_VAULT_PL_CHAR=AWS
AWS_VAULT_PL_DEFAULT_PROFILE=default
ZSH_AUTOFN_CHAR=AUTO
AWS_VAULT=production
ZSH_AUTOFN='/tmp/project with spaces/.autofn'
CONDA_DEFAULT_ENV=venv
zstyle ':prompt:pure:title' show no
source {shlex.quote(str(ROOT / 'pure.zsh'))}
cd {shlex.quote(str(repo))}
''')
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(ZSH, [ZSH, '-di'], env)

    def read_prompt(after=None, initial=b''):
        data = initial
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.15)
            if readable:
                try:
                    data += os.read(fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
            elif b'PURE_READY>' in data:
                visible = ANSI.sub('', data.decode('utf-8', errors='replace')).replace('\r', '')
                if after is not None:
                    if after not in visible:
                        continue
                    visible = visible.split(after, 1)[1]
                    if 'PURE_READY>' not in visible:
                        continue
                return visible
        raise AssertionError(f'Prompt timeout or shell exited: {data!r}')

    sequence = 0

    def command(text):
        global sequence
        sequence += 1
        # The echoed command contains %s; only execution emits this exact marker.
        acknowledgement = f'__PURE_DONE_{sequence}__'
        barrier = f"; printf '\\n__PURE_DONE_%s__\\n' {sequence}"
        os.write(fd, (text + barrier).encode() + b'\n')
        return read_prompt(after=acknowledgement)

    def contains(output, expected):
        assert expected in output, f'Missing {expected!r} in PTY output {output!r}'

    try:
        output = read_prompt()
        contains(output, 'venv AWS production AUTO project with spaces PURE_READY>')
        # Async Git results must coexist with both custom lower-line segments.
        deadline = time.monotonic() + 10
        while 'pty-branch' not in output and time.monotonic() < deadline:
            output = command(':')
        contains(output, 'pty-branch')
        contains(output, 'venv AWS production AUTO project with spaces PURE_READY>')
        output = command('AWS_VAULT=default')
        contains(output, 'venv AWS AUTO project with spaces PURE_READY>')
        # Send printable escape notation, then confirm controls disappear in render.
        value = f'prod%F{{red}}$(touch {marker})`touch {marker}`'
        output = command('AWS_VAULT=' + shlex.quote(value) + "$'\\t\\n\\r\\e\\a\\177'")
        contains(output, 'venv AWS ' + value + ' AUTO project with spaces PURE_READY>')
        assert not marker.exists(), 'Prompt text was executed'
        output = command('unset AWS_VAULT ZSH_AUTOFN')
        contains(output, 'venv PURE_READY>')
        assert 'venv AWS' not in output, 'Removed segment persisted'
        output = command("prompt_pure_precustom() { psvar[22]=PREFIX; psvar[23]=SUFFIX; }")
        contains(output, 'PREFIX')
        contains(output, 'SUFFIX')
        # Real suspended job, not a fabricated jobstates associative array.
        job = "/bin/sh -c " + shlex.quote("echo $$ > " + shlex.quote(str(home / 'sleeper')) + "; exec /bin/sleep 60")
        os.write(fd, job.encode() + b'\n')
        deadline = time.monotonic() + 5
        job_output = b''
        while not (home / 'sleeper').exists() and time.monotonic() < deadline:
            # Drain the PTY while the foreground process starts; macOS has a
            # small terminal buffer and ZLE may otherwise block on echoed input.
            if select.select([fd], [], [], 0.02)[0]:
                job_output += os.read(fd, 65536)
        if not (home / 'sleeper').exists():
            raise AssertionError(f'Foreground job did not start: {job_output!r}')
        os.write(fd, b'\x1a')
        output = read_prompt(initial=job_output)
        contains(output, '\uf41c')
        output = command("PURE_SUSPENDED_JOBS_SYMBOL='PAUSED'")
        contains(output, 'PAUSED')
        output = command("PURE_SUSPENDED_JOBS_SYMBOL=''")
        assert '\uf41c' not in output and 'PAUSED' not in output, output
        output = command('unset PURE_SUSPENDED_JOBS_SYMBOL')
        contains(output, '\uf41c')
        command('kill -KILL %+; wait 2>/dev/null')
        print('fork PTY tests passed')
    finally:
        sleeper_file = home / 'sleeper'
        if sleeper_file.exists():
            try:
                os.kill(int(sleeper_file.read_text().strip()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        # Terminate only the test shell process group and its fixture jobs.
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(fd)
        os.waitpid(pid, 0)
