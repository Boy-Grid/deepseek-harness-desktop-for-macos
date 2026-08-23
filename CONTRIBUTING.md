# Contributing

Thanks for looking. Issues and pull requests are welcome.

## Getting set up

You need macOS 14+, the Xcode command line tools (`xcode-select --install`), and
Node.js for the test fixtures. `shellcheck` is optional but the test suite runs
it when present (`brew install shellcheck`).

```sh
./build.sh --output /tmp/dsh-desktop-dev.app   # build without touching ~/Applications
bash tests/run.sh                              # the whole suite
bash tests/run.sh t-04                         # just the files matching t-04
```

The suite needs neither DeepSeek Harness nor dsh-mfw installed: `tests/fixtures/`
provides stand-ins for both, plus one for "somebody else's server". Cases that
genuinely cannot run in your environment print SKIP and are listed again in the
summary — a skip is never counted as a pass.

## Where things live

`launcher` owns everything about instance lifetime — starting, stopping, status,
the two backends, and where state goes. The Swift side drives the window and
calls that script; it does not reimplement any of those decisions. If you find
yourself computing a state directory in Swift, ask the script instead (it prints
the one it resolved in `status`).

## What is most useful

- **Verifying against a new upstream release.** dsh is a dev preview and moves
  quickly. Reports of "this breaks with dsh X" are valuable, especially with the
  relevant log tail.
- **The title-bar tab strip aligns itself with the page's centre column** by
  reading live DOM geometry from a `[class*="centerCol"]` element. An upstream
  style change breaks that silently (it degrades to "not aligned" rather than
  crashing). Fixes and a more robust hook are welcome.
- Anything in the "not done" lists in `OPENSOURCE-PLAN.md`. That file is the
  design and decision record — including things that were tried and reverted, and
  why — rather than user documentation, and it is written in Chinese.

## Conventions

**Comments explain why, not what.** The code says what it does. A comment earns
its place by recording the constraint, the measurement or the bug that shaped the
line — the kind of thing the next reader would otherwise have to rediscover.

**Shell.** `set -u` stays on. Always brace a variable that is followed
immediately by a non-ASCII character: in a UTF-8 locale bash folds the following
byte into the variable name, and `set -u` then aborts. This has bitten this
codebase three times, so `tests/t-05-lint.sh` now checks for it. `shellcheck -x`
must be clean at warning level.

**Tests, and reverse verification.** New behaviour needs an assertion. Then break
the implementation on purpose and confirm the assertion goes red before restoring
it — an assertion never seen to fail has not been shown to test anything. The
test harness itself was found this way: it was reading `tee`'s exit status, so
every failure counted as a pass.

**Prefer a stand-in over a real environment.** Installing a dev-preview CLI in CI
ties the build's stability to somebody else's release schedule. Fixtures cover
this side of the boundary; real integration belongs in pre-release manual checks.

## Pull requests

Work on a branch, keep the commit history readable, and describe *why* in the
commit message — a diff shows what changed, only you know what it was for. Say
what you verified and what you could not. CI runs lint, the suite and a build,
all on macOS; it should be green before review.

Documentation only describes behaviour that exists. If a change makes a README
statement untrue, the README is part of the change.

## Scope

This project is a macOS shell around DeepSeek Harness. Agent behaviour, sandbox
policy and the web UI itself belong
[upstream](https://github.com/deepseek-ai/deepseek-harness); multi-folder
workspaces belong to
[dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace).

Security reports go through the process in [SECURITY.md](SECURITY.md), not a
public issue.
