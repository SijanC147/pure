#!/usr/bin/env zsh
# This acceptance suite may be copied outside the candidate checkout.
set -o pipefail
cd -- "${PURE_ROOT:-${0:A:h}/..}"
zstyle ':prompt:pure:title' show no
set +e
fpath=($PWD $fpath)
source ./pure.zsh
prompt_pure_async_tasks() { :; }
assert_equal() {
	[[ $1 == $2 ]] || { print -u2 -r -- "FAIL: $3 (expected ${(qqq)1}, got ${(qqq)2})"; exit 1; }
}
# Keep the real precmd/render path while making Git state deterministic.
prompt_pure_vcs_info=(branch feature action rebase)
psvar[13]=1
CONDA_DEFAULT_ENV=venv
AWS_VAULT_PL_CHAR=AWS
ZSH_AUTOFN_CHAR=AUTO
AWS_VAULT_PL_DEFAULT_PROFILE=default
AWS_VAULT=production
ZSH_AUTOFN='/tmp/project with spaces/.autofn.zsh'
prompt_pure_precmd
assert_equal 'AWS production' "$psvar[90]" 'AWS reserved slot'
assert_equal 'AUTO project with spaces' "$psvar[91]" 'autofn path containing spaces'
assert_equal 1 "$psvar[13]" 'username flag retained'
assert_equal feature "$psvar[14]" 'upstream Git branch retained'
assert_equal rebase "$psvar[16]" 'upstream Git action retained'
assert_equal venv "$psvar[20]" 'upstream environment retained'
setopt GLOB_SUBST
AWS_VAULT_PL_DEFAULT_PROFILE='*'
prompt_pure_precmd
assert_equal 'AWS production' "$psvar[90]" 'default profile equality remains literal with GLOB_SUBST'
unsetopt GLOB_SUBST
AWS_VAULT_PL_DEFAULT_PROFILE=default
ZSH_AUTOFN=/foo
prompt_pure_precmd
assert_equal 'AUTO /' "$psvar[91]" 'root parent directory remains visible'
ZSH_AUTOFN=/
prompt_pure_precmd
assert_equal 'AUTO /' "$psvar[91]" 'root path remains visible'
ZSH_AUTOFN='/tmp/project with spaces/.autofn.zsh'
AWS_VAULT=default
prompt_pure_precmd
assert_equal AWS "$psvar[90]" 'default profile only shows symbol'
AWS_VAULT=$'prod\t\n\r\e\a\177%F{red}$(touch SENTINEL)`touch SENTINEL`\\n'
ZSH_AUTOFN=$'/tmp/auto\t\n\r\e\a\177%F{blue}/.autofn'
prompt_pure_precmd
assert_equal 'AWS prod%F{red}$(touch SENTINEL)`touch SENTINEL`\n' "$psvar[90]" 'profile controls removed and literals preserved'
assert_equal 'AUTO auto%F{blue}' "$psvar[91]" 'autofn controls removed'
local text='%(90V.%90v .)%(91V.%91v .)'
assert_equal 'AWS prod%F{red}$(touch SENTINEL)`touch SENTINEL`\n AUTO auto%F{blue} ' "${(%)text}" 'percent values remain literal'
# Render fingerprint must include both owned slots.
local before=$prompt_pure_last_prompt
AWS_VAULT=changed
prompt_pure_precmd
[[ $before != $prompt_pure_last_prompt ]] || { print -u2 'FAIL: AWS fingerprint'; exit 1; }
before=$prompt_pure_last_prompt
ZSH_AUTOFN=/tmp/changed/.autofn
prompt_pure_precmd
[[ $before != $prompt_pure_last_prompt ]] || { print -u2 'FAIL: autofn fingerprint'; exit 1; }
unset AWS_VAULT ZSH_AUTOFN
prompt_pure_precmd
assert_equal '' "$psvar[90]" 'AWS removal clears slot'
assert_equal '' "$psvar[91]" 'autofn removal clears slot'
AWS_VAULT=default
ZSH_AUTOFN=/tmp/project/.autofn
unset AWS_VAULT_PL_CHAR ZSH_AUTOFN_CHAR
prompt_pure_precmd
assert_equal $'\UF01A7' "$psvar[90]" 'default AWS symbol'
assert_equal $'\UF01A7 project' "$psvar[91]" 'default autofn symbol'
# User custom hooks remain available alongside fork fields.
prompt_pure_precustom() { psvar[22]=prefix; psvar[23]=suffix; }
prompt_pure_precmd
assert_equal prefix "$psvar[22]" 'prefix hook'
assert_equal suffix "$psvar[23]" 'suffix hook'
print 'fork-customizations tests passed'
