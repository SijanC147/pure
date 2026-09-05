# Pure fork behavior contract

The fork integrates upstream `89c9e30` with the existing fork `ba0c0c7` using a real merge. Upstream owns slots 12–23 and its async Git, virtualenv/Conda/Nix, optional Node.js version, path styling, prefix/suffix hook, user/host, continuation, and Vim behavior. The fork adds the following behavior without repurposing those slots.

| Behavior | Contract |
| --- | --- |
| AWS Vault | Nonempty `AWS_VAULT` renders on the lower line in color 208 (`:prompt:pure:aws_vault`); literal default-profile equality (including under `GLOB_SUBST`) with `AWS_VAULT_PL_DEFAULT_PROFILE` shows the symbol alone, otherwise symbol plus profile. |
| autofn | Nonempty `ZSH_AUTOFN` renders its parent-directory basename on the lower line in color 39 (`:prompt:pure:zsh_autofn`); spaces remain intact and a root parent displays `/`. |
| Symbols | AWS/autofn use `AWS_VAULT_PL_CHAR` / `ZSH_AUTOFN_CHAR`, with U+F01A7 used for unset or empty values, preserving historical behavior. |
| Text | AWS/autofn profile, directory, and symbol text are literal: percent sequences, dollar expressions, backticks, and backslashes do not execute or become prompt formatting. Control characters are removed. |
| Allocation | `psvar[90]` is AWS; `psvar[91]` is autofn. Both refresh on every render, clear on removal, and participate in redraw fingerprints. |
| Ordering | Lower line is virtualenv, AWS, autofn, prompt symbol, with one separator after each present segment. |
| Suspended jobs | The default is U+F41C. `PURE_SUSPENDED_JOBS_SYMBOL` overrides it; explicitly empty hides it, and unsetting restores the default. Upstream owns the job-state slot. |
| Custom hooks | `prompt_pure_precustom` remains available with prefix/suffix slots 22/23. |

The tests exercise state and actual interactive terminal rendering. `tests/fork-customizations.zsh`, `tests/fork-pty.py`, and `tests/fork-package.py` accept `PURE_ROOT` pointing at a candidate checkout so a controller can hold trusted copies outside that checkout. Python tests accept `ZSH_BIN`; the unit runner and subprocesses use `zsh` from `PATH`. PTY tests create and terminate their own temporary shell/jobs and use an isolated Git repository with fetch disabled.

## Local validation

Development requires Node.js 24 or newer, Python 3.11 or newer, zsh, and pnpm. Runtime Pure remains zsh-only with no new production dependencies.

```sh
pnpm --ignore-workspace install --frozen-lockfile --ignore-scripts
npm run test:unit && npx tsc --noEmit
npm run test:pty
npm run test:package
npm run test:release
```

`--ignore-workspace` prevents an enclosing user workspace from capturing the checkout's development dependencies. Use an installed UTF-8 locale (macOS: `LC_ALL=en_US.UTF-8`). Unset malformed inherited `GIT_CONFIG_COUNT` for validation if the launcher supplies a count without the matching Git configuration keys; no persistent Git configuration change is needed.

CI runs the complete suites on Linux and macOS, plus a checksum-pinned zsh 5.2 build on Linux. Required native check names are `Pure validation (ubuntu-latest)` and `Pure validation (macos-latest)`; the minimum-version check is `Pure validation (zsh 5.2)`.

## Packaging

```sh
npm run package:pack -- --pack-destination /absolute/output/directory
```

Packaging copies release files and regular autoload aliases into a temporary directory and packs there. Checkout symlinks, source files, and Git state are preserved, including on failure. Direct `npm pack`/directory publishing is blocked with guidance to use this staging entrypoint. A generated archive can be reviewed and explicitly published separately. Tests inspect archive aliases and load the prompt from the extracted archive; they do not run installation hooks, publish, or alter system autoload directories.

The existing Homebrew release workflow remains unchanged. Source checks, remote CI, release tag/tarball, tap updates, installation, and runtime consumer verification remain distinct gates.
