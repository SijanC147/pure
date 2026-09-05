# Manual releases

Release preparation and publication are separate actions. `make patch`, `make minor`,
`make major`, and the legacy `make release TYPE=patch` prepare a pull request. They
never push to `main`, create a tag, or publish a GitHub release.

## Prepare

Start with a clean `main` checkout matching `origin/main`. The helper requires Bash,
Git, jq, npm, and an authenticated GitHub CLI. `origin` must use a github.com HTTPS
or SSH URL, with the same fetch and push URL. All GitHub operations explicitly target
that repository, including when the CLI's default repository is upstream.

Run `make patch` (or `minor` / `major`). The helper:

1. Fetches `origin/main` and checks the clean checkout and package/prompt version parity.
2. Creates `release/vX.Y.Z` and updates both `package.json` and `pure.zsh`.
3. Runs `npm run test:unit`, commits the version changes, and pushes only that branch.
4. Opens a preparation PR against `main`.

Review the PR, require **Pure validation**, and merge through the normal PR process.
Failures stop immediately. Local changes or a pushed preparation branch may remain
for inspection; the helper never resets, deletes, or force-pushes them. Resolve the
reported problem before continuing manually. Do not rerun a bump over partial work.

## Publish explicitly

After the preparation PR is merged, update a clean local `main` checkout. Verify the
intended version and the full 40-character main commit SHA, then run:

```sh
make publish VERSION=1.24.0 COMMIT=<full-main-commit-sha>
```

The helper requires the requested version to match both version declarations, the
explicit commit to equal local and freshly fetched `origin/main`, and the newest
`validate.yml` push run for that exact main commit to be completed successfully.
It refuses an existing remote version tag and atomically creates the tag through the
GitHub API at the explicit commit, then publishes with `--verify-tag`. A concurrent
tag creation also fails; no tag is replaced. A failure to inspect CI or tags prevents
release. If tag creation succeeds but publication fails, the tag remains for
inspection and manual recovery. Do not delete or overwrite it to rerun the helper.

Publication triggers the existing Homebrew release workflow. This helper's checks do
not establish Homebrew tap, installation, runtime, or downstream consumer success;
verify those separately after publication. The helper does not edit the tap or the
Homebrew workflow.

Run `make test-release-safety` to test these safeguards with isolated local fixtures
and mocked network commands. Tests never push to GitHub or publish a release.
