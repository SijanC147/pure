#!/usr/bin/env bash
# Behavioral fixtures: actual local commits, no real remote/network operations.
set -euo pipefail
unset GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
source_root=$(cd "$(dirname "$0")/.." && pwd)
real_git=$(command -v git)
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/pure-release-test.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"
export REAL_GIT="$real_git" TEST_LOG="$fixture_root/commands.log"
cat >"$fixture_root/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'git' >>"$TEST_LOG"; printf ' <%s>' "$@" >>"$TEST_LOG"; printf '\n' >>"$TEST_LOG"
case "$1" in
  fetch) [[ ${TEST_FAIL:-} != fetch ]]; exit ;;
  ls-remote)
    [[ ${TEST_FAIL:-} != ls-remote ]] || exit 1
    if [[ ${TEST_EXISTING_TAG:-} == 1 && "$2" == --tags ]]; then printf 'abc\trefs/tags/v1.2.4\n'; fi
    exit 0 ;;
  push) [[ ${TEST_FAIL:-} != push ]]; exit ;;
  commit) [[ ${TEST_FAIL:-} != commit ]] || exit 1 ;;
esac
exec "$REAL_GIT" "$@"
MOCK
cat >"$fixture_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh' >>"$TEST_LOG"; printf ' <%s>' "$@" >>"$TEST_LOG"; printf '\n' >>"$TEST_LOG"
case "$1 $2" in
  'auth status') [[ ${TEST_FAIL:-} != auth ]] ;;
  'run list')
    [[ ${TEST_FAIL:-} != ci-query ]] || exit 1
    case ${TEST_CI:-success} in
      success) printf '[{"headSha":"%s","event":"push","status":"completed","conclusion":"success"}]\n' "$TEST_HEAD" ;;
      wrong-sha) printf '[{"headSha":"bad","event":"push","status":"completed","conclusion":"success"}]\n' ;;
      pending) printf '[{"headSha":"%s","event":"push","status":"in_progress","conclusion":null}]\n' "$TEST_HEAD" ;;
      failure) printf '[{"headSha":"%s","event":"push","status":"completed","conclusion":"failure"}]\n' "$TEST_HEAD" ;;
      missing) printf '[]\n' ;;
    esac ;;
  'pr create') [[ ${TEST_FAIL:-} != pr ]] ;;
  'api --method')
    [[ ${TEST_FAIL:-} != create-tag ]] || exit 1
    printf '%s\n' "$TEST_HEAD" ;;
  'release create') [[ ${TEST_FAIL:-} != publish ]] ;;
  *) printf 'Unexpected gh invocation\n' >&2; exit 90 ;;
esac
MOCK
cat >"$fixture_root/bin/npm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm <%s> <%s>\n' "$1" "$2" >>"$TEST_LOG"
[[ "$1 $2" == 'run test:unit' && ${TEST_FAIL:-} != test ]]
MOCK
chmod +x "$fixture_root/bin/"*
export PATH="$fixture_root/bin:$PATH"
# Default make is informational and cannot call the release helper.
make -f "$source_root/Makefile" >"$fixture_root/default-help"
[[ ! -s "$TEST_LOG" ]]
count=0
setup() {
  count=$((count + 1))
  cd "$fixture_root"
  mkdir "repo-$count"
  cd "repo-$count"
  "$real_git" init -q -b main
  "$real_git" config user.email fixture@example.invalid
  "$real_git" config user.name 'Release fixture'
  "$real_git" config commit.gpgsign false
  printf '{"version":"1.2.3"}\n' >package.json
  printf '\tprompt_pure_state[version]="1.2.3"\n' >pure.zsh
  "$real_git" add .
  "$real_git" commit -qm 'fixture'
  "$real_git" remote add origin https://github.com/example/pure.git
  export TEST_HEAD=$("$real_git" rev-parse HEAD)
  "$real_git" update-ref refs/remotes/origin/main "$TEST_HEAD"
  unset TEST_FAIL TEST_CI TEST_EXISTING_TAG
  : >"$TEST_LOG"
}
run_ok() { bash "$source_root/bump.sh" "$@" >"$fixture_root/output" 2>&1 || { cat "$fixture_root/output"; exit 1; }; }
run_fail() { if bash "$source_root/bump.sh" "$@" >"$fixture_root/output" 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }
has() { grep -F -- "$1" "$TEST_LOG" >/dev/null || { printf 'Missing call: %s\n' "$1" >&2; cat "$TEST_LOG"; exit 1; }; }
lacks() { if grep -F -- "$1" "$TEST_LOG" >/dev/null; then printf 'Forbidden call: %s\n' "$1" >&2; cat "$TEST_LOG"; exit 1; fi; }
unchanged() { [[ $("$real_git" rev-parse HEAD) == "$TEST_HEAD" ]]; lacks 'git <push>'; lacks 'gh <pr> <create>'; lacks 'gh <release> <create>'; lacks 'gh <api>'; }

for bump in patch minor major; do
  setup
  case "$bump" in patch) expected=1.2.4 ;; minor) expected=1.3.0 ;; major) expected=2.0.0 ;; esac
  run_ok "$bump"
  [[ $(jq -r .version package.json) == "$expected" ]]
  grep -F "prompt_pure_state[version]=\"$expected\"" pure.zsh >/dev/null
  [[ $("$real_git" branch --show-current) == "release/v$expected" ]]
  [[ $("$real_git" rev-parse main) == "$TEST_HEAD" ]]
  [[ -z $("$real_git" status --porcelain) ]]
  has 'npm <run> <test:unit>'
  has "git <push> <--set-upstream> <origin> <HEAD:refs/heads/release/v$expected>"
  has 'gh <pr> <create> <--repo> <example/pure> <--base> <main>'
  lacks 'gh <release> <create>'
done
setup; run_fail invalid; unchanged
setup; run_fail; unchanged
setup; "$real_git" remote set-url --push origin https://github.com/elsewhere/pure.git; run_fail patch; unchanged
setup; "$real_git" remote set-url origin https://example.invalid/pure.git; run_fail patch; unchanged
setup; "$real_git" branch release/v1.2.4; run_fail patch; unchanged
setup; "$real_git" remote set-url origin git@github.com:example/pure.git; run_ok patch; has 'gh <pr> <create> <--repo> <example/pure>'
setup; printf '{"version":"1.2.3-beta"}\n' >package.json; "$real_git" add .; "$real_git" commit -qm prerelease; export TEST_HEAD=$("$real_git" rev-parse HEAD); "$real_git" update-ref refs/remotes/origin/main "$TEST_HEAD"; run_fail patch; unchanged
setup; run_fail patch extra; unchanged
setup; printf 'dirty\n' >>pure.zsh; run_fail patch; unchanged
setup; "$real_git" checkout -qb feature; run_fail patch; unchanged
setup; sed 's/1.2.3/1.2.2/' pure.zsh >changed; mv changed pure.zsh; "$real_git" add .; "$real_git" commit -qm mismatch; export TEST_HEAD=$("$real_git" rev-parse HEAD); "$real_git" update-ref refs/remotes/origin/main "$TEST_HEAD"; run_fail patch; unchanged
setup; printf 'stale\n' >extra; "$real_git" add .; "$real_git" commit -qm ahead; export TEST_HEAD=$("$real_git" rev-parse HEAD); run_fail patch; unchanged
for failure in auth fetch ls-remote test commit push pr; do
  setup; export TEST_FAIL=$failure; run_fail patch
  lacks 'gh <release> <create>'
  [[ $("$real_git" rev-parse main) == "$TEST_HEAD" ]]
  case "$failure" in auth|fetch|ls-remote|test|commit) unchanged ;; push) lacks 'gh <pr> <create>' ;; esac
done
setup; export TEST_EXISTING_TAG=1; run_fail patch; unchanged
setup; run_ok publish 1.2.3 "$TEST_HEAD"
has "gh <release> <create> <v1.2.3> <--repo> <example/pure> <--verify-tag> <--target> <$TEST_HEAD> <--generate-notes>"
has "gh <api> <--method> <POST> <repos/example/pure/git/refs> <--raw-field> <ref=refs/tags/v1.2.3> <--raw-field> <sha=$TEST_HEAD> <--jq> <.object.sha>"
has 'gh <run> <list> <--repo> <example/pure> <--workflow> <validate.yml> <--branch> <main>'
lacks 'git <push>'; lacks 'gh <pr> <create>'; lacks 'git <tag>'
setup; run_fail publish 1.2.4 "$TEST_HEAD"; unchanged
setup; run_fail publish 1.2.3 "${TEST_HEAD:0:7}"; unchanged
for state in wrong-sha pending failure missing; do
  setup; export TEST_CI=$state; run_fail publish 1.2.3 "$TEST_HEAD"; unchanged
done
for failure in fetch ci-query ls-remote; do
  setup; export TEST_FAIL=$failure; run_fail publish 1.2.3 "$TEST_HEAD"; unchanged
done
setup; export TEST_EXISTING_TAG=1; run_fail publish 1.2.3 "$TEST_HEAD"; unchanged
setup; export TEST_FAIL=create-tag; run_fail publish 1.2.3 "$TEST_HEAD"; lacks 'gh <release> <create>'
setup; export TEST_FAIL=publish; run_fail publish 1.2.3 "$TEST_HEAD"; has 'gh <api> <--method> <POST>'; lacks 'git <push>'; lacks '<DELETE>'
printf 'Passed %s isolated release safety scenarios.\n' "$count"
