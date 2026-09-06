#!/usr/bin/env bash
# Hosted macOS only: no publication token is needed or inherited.
set -euo pipefail
artifact="$(cd "$1" && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:?}/pure-brew.XXXXXX")"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_CACHE="$work/cache" HOMEBREW_LOGS="$work/logs"
export ZDOTDIR="$work/zsh-config"
mkdir -p "$ZDOTDIR" "$HOMEBREW_CACHE" "$HOMEBREW_LOGS" "$work/source"
node --input-type=module - "$artifact" <<'JS'
import {readFileSync} from 'node:fs';
import {validateProof} from './scripts/homebrew-release.mts';
const dir = process.argv[2];
validateProof(JSON.parse(readFileSync(`${dir}/release.json`)), readFileSync(`${dir}/archive.tar.gz`), readFileSync(`${dir}/pure.rb`, 'utf8'));
JS
# Refuse unsafe paths before extraction, and require one archive root.
python3 - "$artifact/archive.tar.gz" "$work/source" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    roots = set()
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts:
            raise SystemExit('Unsafe archive path')
        roots.add(path.parts[0])
        if member.issym() or member.islnk():
            target = pathlib.PurePosixPath(member.linkname)
            if target.is_absolute() or '..' in target.parts:
                raise SystemExit('Unsafe archive link')
    if len(roots) != 1:
        raise SystemExit('Expected a single source archive root')
    archive.extractall(sys.argv[2], filter='data')
PY
source_root="$(find "$work/source" -mindepth 1 -maxdepth 1 -type d)"
node --input-type=module - "$artifact" "$source_root" <<'JS'
import {readFileSync} from 'node:fs';
const [artifact, source] = process.argv.slice(2);
const proof = JSON.parse(readFileSync(`${artifact}/release.json`));
const pkg = JSON.parse(readFileSync(`${source}/package.json`));
const runtime = readFileSync(`${source}/pure.zsh`, 'utf8').match(/^\s*prompt_pure_state\[version\]="([^"]+)"/m)?.[1];
if (pkg.version !== proof.sourceVersion || runtime !== proof.sourceVersion) throw new Error('Archive package/runtime mismatch');
JS
# Install/test the canonical formula, including its public archive URL and checksum.
brew tap-new pure-release/verification
formula_dir="$(brew --repository pure-release/verification)/Formula"
mkdir -p "$formula_dir"
cp "$artifact/pure.rb" "$formula_dir/pure.rb"
brew install --build-from-source --include-test pure-release/verification/pure
brew test pure-release/verification/pure
version="$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).version' "$artifact/release.json")"
installed="$(brew list --versions pure-release/verification/pure)"
[[ "$installed" == "pure $version" ]]
# Exercise Homebrew's own ordering implementation, not semver assumptions.
# Homebrew sanitizes the environment before Ruby; pass the version as an argument.
brew ruby -e 'require "version"; current = ARGV.fetch(0); base, stamp = current.split("+"); a = Version.new(base + "+20000101000000"); b = Version.new(base + "+20000101000001"); next_base = base.split(".").map(&:to_i); next_base[2] += 1; abort "Homebrew version ordering failed" unless a < b && b < Version.new(next_base.join(".")) && Version.new(current).to_s == current' -- "$version"
# Runtime uses only the installed formula and an isolated startup configuration.
prefix="$(brew --prefix pure-release/verification/pure)"
async_prefix="$(brew --prefix zsh-async)"
source_version="$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1])).sourceVersion' "$artifact/release.json")"
zsh -fc 'fpath=("$1/share/zsh/site-functions" "$2/share/zsh/site-functions" $fpath); autoload -Uz promptinit; promptinit; prompt pure; [[ ${prompt_pure_state[version]} == "$3" ]]' -- "$prefix" "$async_prefix" "$source_version"
printf 'Verified tagged archive, formula checksum, installed %s, runtime and version ordering.\n' "$version"
