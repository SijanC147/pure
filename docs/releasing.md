# Releases

## Automatic fork releases and Homebrew publication

The private upstream maintainer publishes an immutable `vX.Y.Z+yyyyMMddHHmmss`
GitHub release after a validated upstream sync. The base comes from the latest
upstream release, and the timestamp uses Europe/Malta. Package and prompt runtime
versions remain coherent and may be ahead of that latest release when upstream
main has advanced. An App installation token creates the release so GitHub
delivers its `release: published` event.

`release.yml` binds to that exact published tag and its commit, checks that the
commit remains an ancestor of source main, downloads its archive, and generates a
formula with the complete explicit version and archive SHA-256. It never resolves
the latest release. A separate hosted macOS job verifies the archive and source
versions, installs the formula in a temporary verification tap with isolated shell
configuration and caches, installs test dependencies with `--include-test`, runs
`brew test`, checks the installed version and prompt runtime,
and exercises Homebrew's own version ordering across builds and the next base.
The formula retains its existing external `zsh-async` dependency.

Only the final Ubuntu publisher receives `PERSONAL_ACCESS_TOKEN`. It regenerates
the formula and checks every artifact byte, then rechecks the release/tag/commit
and public archive. It creates an immutable tag-keyed branch and a PR changing
only `Formula/pure.rb` in `SijanC147/homebrew-formulas`. Normal GitHub PR merge
enforces repository protections; no direct main push or bypass is used. The
publisher checks the PR head, base, current tap main, checks and merged formula.
A changed base, conflicting branch, same-version content mismatch, or downgrade
stops it. Matching completed publication is idempotent. All workflow runs serialize.
Pending or failed tap checks stop publication; retry after they pass. Zero checks
are accepted only when the tap has no active Actions workflows, as in the current
tap. Repository-required checks remain enforced by GitHub's normal merge endpoint.

If a published release needs a retry, dispatch the workflow on that exact tag:

```sh
gh workflow run release.yml --repo SijanC147/pure \
  --ref v1.28.3+20260906070809 -f tag=v1.28.3+20260906070809
```

Use the actual existing tag. Dispatching on the tag keeps the workflow run's SHA
bound to the source release, including when main has advanced. Inspect a conflicting
partial tap PR before retrying; the workflow never force-pushes or deletes it.

If the workflow itself needs a repair, merge and validate the repair on source
main, then explicitly dispatch from current main while retaining the existing tag:

```sh
gh workflow run release.yml --repo SijanC147/pure \
  --ref main -f tag=v1.28.3+20260906071326
```

This manual repair path checks the executing workflow SHA against live source
main in both preparation and publication. A stale main run, any other branch,
or a release event on main is rejected. The release tag, original source commit,
archive checksum and verification artifacts remain bound to the original release;
no release or tag is recreated. The workflow run SHA identifies the reviewed
repair commit, so inspect its release proof to confirm the original source SHA.

## Manual base-version preparation

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

The legacy manual publisher creates plain base-version tags, which the Homebrew
workflow also accepts when the tag matches the coherent package/runtime version.
The maintainer always creates timestamped fork tags. This helper's
checks do not establish Homebrew tap, installation, runtime, or downstream consumer
success; verify those separately after publication.

Run `make test-release-safety` to test these safeguards with isolated local fixtures
and mocked network commands. Tests never push to GitHub or publish a release.
