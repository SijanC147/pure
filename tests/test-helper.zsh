#!/usr/bin/env zsh

set -euo pipefail

cd -- "${0:A:h}/.."

fpath=($PWD $fpath)
# Prompt setup runs in interactive shells, which normally disable nounset/errexit.
set +eu
if ! source ./pure.zsh >/dev/null 2>&1; then
	print -u2 -- 'Pure setup failed in unit test helper'
	exit 1
fi
# Unit cases call functions directly; PTY tests cover the installed hooks.
add-zsh-hook -d precmd prompt_pure_precmd
add-zsh-hook -d preexec prompt_pure_preexec
set -eu

prompt_pure_preprompt_render() {
	:
}

assert_equal() {
	local expected=$1
	local actual=$2
	local message=$3

	if [[ $expected != $actual ]]; then
		print -u2 -- "Assertion failed: $message"
		print -u2 -- "Expected: $expected"
		print -u2 -- "Actual:   $actual"
		return 1
	fi
}

assert_empty() {
	local actual=$1
	local message=$2

	if [[ -n $actual ]]; then
		print -u2 -- "Assertion failed: $message"
		print -u2 -- "Expected empty value"
		print -u2 -- "Actual: $actual"
		return 1
	fi
}
