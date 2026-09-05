#!/usr/bin/env bash
# Prepare a release PR, or explicitly publish an already validated main commit.
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage: %s <patch|minor|major>\n       %s publish <version> <full-commit-sha>\n' "$0" "$0" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
mode=$1
case "$mode" in
  patch|minor|major) [[ $# -eq 1 ]] || usage ;;
  publish) [[ $# -eq 3 ]] || usage ;;
  *) usage ;;
esac
for tool in git gh jq; do
  command -v "$tool" >/dev/null || fail "Required command not found: $tool"
done
cd "$(git rev-parse --show-toplevel)"
status=$(git status --porcelain)
[[ -z "$status" ]] || fail 'Start with a clean working tree.'
[[ $(git symbolic-ref --quiet --short HEAD) == main ]] || fail 'Start from the main branch.'

# Always target the fork configured as origin, even when gh defaults to upstream.
origin=$(git remote get-url origin)
case "$origin" in
  https://github.com/*) repository=${origin#https://github.com/} ;;
  git@github.com:*) repository=${origin#git@github.com:} ;;
  *) fail 'origin must be a github.com HTTPS or SSH repository URL.' ;;
esac
repository=${repository%.git}
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid origin repository.'
[[ $(git remote get-url --push origin) == "$origin" ]] || fail 'origin fetch and push URLs must match.'
gh auth status >/dev/null
# Fetch only main: preparing a release never changes tags.
git fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
head=$(git rev-parse HEAD)
[[ "$head" == "$(git rev-parse refs/remotes/origin/main)" ]] || fail 'Local main must equal origin/main.'
version=$(jq -er '.version | select(type == "string")' package.json)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Expected a stable major.minor.patch package version.'
[[ $(grep -c '^[[:space:]]*prompt_pure_state\[version\]=' pure.zsh) == 1 ]] || fail 'Expected exactly one prompt version assignment.'
prompt_version=$(sed -n 's/^[[:space:]]*prompt_pure_state\[version\]="\([^"]*\)"$/\1/p' pure.zsh)
[[ "$version" == "$prompt_version" ]] || fail 'package.json and pure.zsh versions must agree.'

if [[ "$mode" == publish ]]; then
  [[ "$2" == "$version" ]] || fail 'Requested version does not match main.'
  [[ "$3" =~ ^[0-9a-f]{40}$ && "$3" == "$head" ]] || fail 'COMMIT must be the full SHA of current origin/main.'
  # Require the newest push validation for this exact main commit to pass.
  runs=$(gh run list --repo "$repository" --workflow validate.yml --branch main \
    --commit "$head" --event push --limit 1 --json headSha,status,conclusion,event)
  jq -e --arg sha "$head" 'length == 1 and .[0].headSha == $sha and .[0].event == "push" and .[0].status == "completed" and .[0].conclusion == "success"' <<<"$runs" >/dev/null \
    || fail 'The current main commit needs a successful completed validate.yml push run.'
  tag="v$version"
  remote_tags=$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")
  [[ -z "$remote_tags" ]] || fail "Tag $tag already exists; never overwrite a release tag."
  # Atomic create refuses a concurrently created tag, even at the same SHA.
  created_sha=$(gh api --method POST "repos/$repository/git/refs" \
    --raw-field "ref=refs/tags/$tag" --raw-field "sha=$head" --jq '.object.sha')
  [[ "$created_sha" == "$head" ]] || fail 'GitHub did not confirm the expected tag commit.'
  gh release create "$tag" --repo "$repository" --verify-tag --target "$head" --generate-notes
  exit 0
fi

command -v npm >/dev/null || fail 'Required command not found: npm'
IFS=. read -r major minor patch <<<"$version"
case "$mode" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
next_version="$major.$minor.$patch"
branch="release/v$next_version"
# Check branch collisions before editing either file.
! git show-ref --verify --quiet "refs/heads/$branch" || fail "Local branch $branch already exists."
remote_branches=$(git ls-remote --heads origin "refs/heads/$branch")
[[ -z "$remote_branches" ]] || fail "Remote branch $branch already exists."
remote_tags=$(git ls-remote --tags origin "refs/tags/v$next_version")
[[ -z "$remote_tags" ]] || fail "Tag v$next_version already exists."
git checkout -b "$branch"
package_tmp=$(mktemp ./package.json.XXXXXX)
prompt_tmp=$(mktemp ./pure.zsh.XXXXXX)
trap 'rm -f "$package_tmp" "$prompt_tmp"' EXIT
jq --arg version "$next_version" '.version = $version' package.json >"$package_tmp"
sed "s/^\([[:space:]]*prompt_pure_state\[version\]=\).*/\1\"$next_version\"/" pure.zsh >"$prompt_tmp"
# Copy through the existing files to preserve their modes.
cat "$package_tmp" >package.json
cat "$prompt_tmp" >pure.zsh
rm -f "$package_tmp" "$prompt_tmp"
npm run test:unit
git add -- package.json pure.zsh
git commit -m "chore: prepare release v$next_version"
git push --set-upstream origin "HEAD:refs/heads/$branch"
gh pr create --repo "$repository" --base main --head "$branch" \
  --title "chore: prepare release v$next_version" \
  --body "Prepare v$next_version with matching package and prompt versions. Merge after Pure validation passes. Publishing remains a separate manual step from the validated main commit; see docs/releasing.md."
