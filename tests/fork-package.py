#!/usr/bin/env python3
"""Verify staged npm artifacts without installation or publishing."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

root = Path(os.environ.get('PURE_ROOT', Path(__file__).resolve().parent.parent)).resolve()
links = {name: os.readlink(root / name) for name in ('async', 'prompt_pure_setup')}
before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in ('pure.zsh', 'async.zsh', 'package.json')}
with tempfile.TemporaryDirectory(prefix='pure-package-test-') as directory:
    subprocess.run(['npm', 'run', 'package:pack', '--', '--pack-destination', directory], cwd=root, check=True)
    archives = list(Path(directory).glob('*.tgz'))
    assert len(archives) == 1, archives
    with tarfile.open(archives[0]) as archive:
        names = archive.getnames()
        for name, source in [('async', 'async.zsh'), ('prompt_pure_setup', 'pure.zsh')]:
            entry = archive.getmember('package/' + name)
            assert entry.isfile(), f'{name} must be a regular file in npm package'
            assert archive.extractfile(entry).read() == (root / source).read_bytes()
        assert not any(name.startswith('package/scripts/') for name in names), names
        for entry in archive.getmembers():
            parts = Path(entry.name).parts
            assert entry.isfile() and len(parts) == 2 and parts[0] == 'package' and parts[1] not in ('.', '..'), entry.name
            destination = Path(directory) / entry.name
            destination.parent.mkdir(exist_ok=True)
            destination.write_bytes(archive.extractfile(entry).read())
    blocked = subprocess.run(['npm', 'pack', '--pack-destination', directory], cwd=root, capture_output=True)
    assert blocked.returncode != 0, 'Direct packing must use the staging entrypoint'
    fake_bin = Path(directory) / 'bin'
    fake_bin.mkdir()
    fake_npm = fake_bin / 'npm'
    fake_npm.write_text('#!/bin/sh\nexit 21\n')
    fake_npm.chmod(0o755)
    stage_parent = Path(directory) / 'staging'
    stage_parent.mkdir()
    failed = subprocess.run([shutil.which('node'), str(root / 'scripts/pack.mts'), '--pack-destination', directory],
                            cwd=root, env=dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'], TMPDIR=str(stage_parent)),
                            capture_output=True)
    assert failed.returncode != 0, 'Packing failure must propagate'
    assert not list(stage_parent.iterdir()), 'Failed packing must clean its staging directory'
    env = dict(os.environ, PURE_PACKAGE=str(Path(directory) / 'package'), ZDOTDIR=directory)
    env.pop('FPATH', None)
    env['PURE_EXPECTED_VERSION'] = json.loads((root / 'package.json').read_text())['version']
    subprocess.run([os.environ.get('ZSH_BIN', shutil.which('zsh')), '-fc',
                    'fpath=($PURE_PACKAGE $fpath); autoload -Uz prompt_pure_setup; '
                    'prompt_pure_setup; (( $+functions[prompt_aws_vault_segment] )) && '
                    '[[ $prompt_pure_state[version] == $PURE_EXPECTED_VERSION ]]'], env=env, check=True)
assert {name: os.readlink(root / name) for name in links} == links
assert {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in before} == before
print('fork package tests passed')
