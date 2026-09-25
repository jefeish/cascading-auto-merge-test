---
title: Cascading Merge App Smoke Tests
description: Detailed guide to the live standard, conflict, and existing pull request smoke tests
ms.date: 2026-09-25
ms.topic: how-to
---

## Overview

The smoke-test harness exercises the installed Cascading Merge App against the
live `jefeish/cascading-auto-merge-test` repository. It creates real commits,
branches, pull requests, comments, and merges through the GitHub API. No GitHub
behavior is mocked.

The harness covers three workflows:

- A normal cascade that reaches the configured final branch
- A cascade that stops at a merge conflict and resumes after resolution
- A cascade that encounters an existing pull request and resumes after that
  pull request is merged

Every scenario creates its own final GitHub issue. The issue includes the
starting conditions, expected branch sequence, scenario result, and links to
every originating, cascade, collision, and conflict-repair pull request
observed by the harness. Running `all` creates three independent report issues.

> [!WARNING]
> These tests are destructive. Before every scenario, the harness closes all
> open pull requests and runs `reset-repository.sh --yes`. The reset rewrites
> `main` and all configured test branches with force pushes. Run these tests
> only against the dedicated test repository.

The reset script refuses to begin branch cleanup if this guide is missing from
`main`. It also verifies that the rebuilt `main` commit and every reset test
branch still contain the guide before completing the reset.

## Quick start

Run one scenario:

```bash
./smoke-test.sh standard --yes
./smoke-test.sh conflict --yes
./smoke-test.sh existing-pr --yes
```

Run all scenarios in sequence:

```bash
./smoke-test.sh all --yes
```

Omit `--yes` to require confirmation. The script asks you to type the full
repository name before it makes remote changes:

```text
jefeish/cascading-auto-merge-test
```

Display command help without changing the repository:

```bash
./smoke-test.sh --help
```

## Prerequisites

Before running the harness, confirm the following requirements:

- Bash, Git, GitHub CLI, Node.js, and `mktemp` are installed
- `gh auth status` shows an authenticated account with write access to the test
  repository
- The Cascading Merge App is installed and active on the test repository
- The App can create and merge pull requests and add issue comments
- The authenticated test account can create issues for the final smoke-test
  report
- Repository rules permit the reset script to force-push the test branches
- Repository rules permit the test account to merge pull requests with
  `--admin`
- The local `origin` remote points to
  `jefeish/cascading-auto-merge-test`
- `reset-repository.sh` is executable
- Changes needed by the tests are present in the local working tree before the
  reset starts

> [!CAUTION]
> The reset script rebuilds `main` from the current working tree and force-pushes
> it. Review the working tree before a run. Unrelated local changes can become
> part of the rewritten remote baseline.

## Test configuration

The harness currently uses these fixed test controls:

| Control             | Value                               | Purpose                                                     |
| ------------------- | ----------------------------------- | ----------------------------------------------------------- |
| Repository          | `jefeish/cascading-auto-merge-test` | Prevents accidental use against another repository          |
| Entry branch        | `release/0.1`                       | Receives the originating smoke-test pull request            |
| Final branch        | `development`                       | Must contain the scenario marker after a successful cascade |
| Test file           | `README.md`                         | Carries a unique marker through the cascade                 |
| Maximum merge depth | `5`                                 | Limits normal release-to-release cascade hops               |
| Retry interval      | 5 seconds                           | Delay between checks for asynchronous App activity          |
| Maximum attempts    | 12                                  | Allows about 60 seconds for each individual wait operation  |

The repository configuration in `.github/cascading-merge.yml` must agree with
these controls. In particular, `ref_branch` is `development` and
`maxMergeDepth` is `5`.

The final issue reports these harness controls and embeds the repository's
`.github/cascading-merge.yml` as read from `main` before the destructive test
run begins. Deployment-only App environment variables are not visible to this
repository and cannot be included by the harness.

## How the expected cascade is calculated

The harness does not hardcode the release branch sequence. During preflight, it
reads all remote branches with `git ls-remote` and applies the same ordering
rules as the App.

Branch names are split on `/`, `-`, `+`, `_`, and `.`. Numeric tokens are
compared numerically, numeric tokens sort before text tokens, and a shorter
otherwise-equivalent token sequence sorts first. The harness starts at
`release/0.1`, selects the branches allowed by the depth limit, and uses
`development` as the final target.

With the current reset baseline, the expected path is:

```text
release/0.1
  -> release/1.1
  -> release/1.1-rc.1
  -> release/1.2
  -> release/2.0
  -> release/2.0.1-alpha
  -> development
```

If branches are added, removed, or renamed, the harness derives a new path at
runtime. This keeps expectations aligned with the App instead of relying on a
stale branch list.

## Lifecycle shared by every scenario

Every scenario follows the same setup and cleanup lifecycle.

1. The harness deletes artifacts left by its previous scenario.
2. It closes every open pull request in the test repository.
3. It runs `reset-repository.sh --yes` to restore the deterministic branch
   baseline.
4. It creates a temporary directory and clones the test repository into it.
5. It configures a temporary Git identity for smoke-test commits.
6. It performs the scenario-specific operations and assertions.
7. It deletes the temporary patch branch after successful assertions.
8. The exit trap deletes the temporary clone and makes a best effort to delete
   the patch branch after a failure.
9. After each scenario finishes, the harness creates that scenario's report
   issue. The exit trap attempts to publish partial results when a scenario
   fails.

The `all` command runs this complete lifecycle separately for each scenario.
Each scenario therefore starts from a fresh remote baseline.

## Standard cascade test

### Purpose

The standard scenario proves that a normal originating pull request cascades
through the expected release branches, respects the configured depth limit,
and reaches `development`.

### Test flow

1. The harness resets the repository.
2. It creates a branch named with the `smoke/standard-<timestamp>` pattern from
   `release/0.1`.
3. It adds a unique `standard-<timestamp>` line to `README.md`.
4. It creates and merges the originating pull request into `release/0.1`.
5. It waits for the App to report a successful automatic merge.
6. It waits for the App to report that the maximum merge depth was reached and
   that the final merge to `development` was performed.
7. For every dynamically derived source and target pair, it finds the cascade
   pull request associated with the originating pull request.
8. It verifies that every cascade pull request reaches the `MERGED` state.
9. If another release branch exists beyond the depth limit, it verifies that no
   pull request was created for that extra release hop.
10. It reads `README.md` from `development` and verifies that the unique marker
    is present as a complete line.

### Pass criteria

The scenario passes only when all expected cascade pull requests are merged,
no release hop exceeds `maxMergeDepth`, and the unique marker reaches
`development`.

A successful run ends with output similar to:

```text
PASS standard: originating PR #123, cascade PRs #124 #125 #126 #127 #128 #129
```

## Merge conflict and resume test

### Purpose

The conflict scenario proves that the App stops when a generated cascade pull
request has a real merge conflict, creates a protected-branch repair pull
request, preserves enough metadata to continue, and resumes at the correct next
branch after the repair is merged.

### Test flow

1. The harness resets the repository.
2. It adds a unique target-side line to `README.md` on the first downstream
   release branch.
3. It creates an originating patch branch from `release/0.1` and adds a
   different source-side line to the same file.
4. It creates and merges the originating pull request into `release/0.1`.
5. It waits for the first cascade pull request and verifies that it remains
   open.
6. It waits for the App to report that the cascade pull request could not be
   merged because of conflicts.
7. It verifies that the stalled pull request body contains the hidden
   `<!-- cascading-merge-app:` continuation metadata marker.
8. It waits for the App-created draft repair pull request linked to the stalled
   cascade pull request.
9. It checks out the repair branch, merges the protected source branch into it,
   and confirms that Git reports a real merge conflict.
10. It resolves `README.md` in favor of the source branch, adds a unique
    `resolved-<timestamp>` marker, commits the resolution, and pushes it to the
    repair branch.
11. It marks the repair pull request ready and merges it.
12. It verifies that the App automatically merges the original stalled cascade
    pull request.
13. It waits for the originating pull request to receive a comment stating that
    the interrupted cascade is resuming from the stalled pull request.
14. It waits for the App to report a successful automatic merge.
15. Starting with the second expected branch pair, it verifies that every
    remaining cascade pull request is created and merged.
16. It verifies that the resolved marker reaches `development`.

### Pass criteria

The scenario passes only when the first cascade pull request genuinely
conflicts, contains continuation metadata, receives an app-created repair pull
request, resumes after that repair, merges all remaining hops, and carries the
resolved marker to `development`.

A successful run ends with output similar to:

```text
PASS conflict: originating PR #130, repaired by #132, resumed from #131 through development
```

## Per-scenario smoke-test report issue

The harness creates one issue for each `standard`, `conflict`, or `existing-pr`
scenario. Running `all` creates three issues instead of one combined issue. The
issue title includes the scenario, result, and UTC scenario start timestamp.

The issue begins with:

- Repository and requested scenario
- UTC start time and authenticated GitHub actor
- Entry branch, `ref_branch`, and `maxMergeDepth`
- Retry interval, maximum attempts, and test file
- The expected branch sequence
- A hop table distinguishing depth-counted hops from the forced final
  `ref_branch` merge
- The repository cascade configuration read from `main`, inside a collapsed
  details section

Each scenario section contains:

- PASS or FAIL status
- Scenario start time
- Result or failure message
- Linked originating and cascade pull requests
- Linked conflict-repair pull requests
- Linked pre-existing collision pull requests
- Source and target branches, final state, and title for each pull request

Before publishing, the harness also searches pull request bodies for the
originating pull request and stalled pull request metadata. This captures
additional cascade or repair pull requests created asynchronously, including a
second repair attempt after an unsuccessful fix.

Successful reports are published as soon as their scenario finishes. The exit
trap publishes the active scenario's partial report after a failure. Unexpected
shell failures include the exit status, source line, and failing command instead
of only reporting a numeric status. Failure to create the report does not
replace the original smoke-test exit status.

## Existing pull request collision and resume test

### Purpose

The existing pull request scenario proves that the App handles GitHub's
"pull request already exists" response without opening a duplicate. It must
attach continuation metadata to the human-created pull request, pause the
cascade, and resume after that pull request is merged.

### Test flow

1. The harness resets the repository.
2. Before triggering a cascade, it opens a pull request for the first expected
   release-to-release branch pair.
3. It creates and merges the originating patch pull request into
   `release/0.1`.
4. It waits for the App to report that a pull request is already open.
5. It waits for the App to report that the automatic merge action did not
   complete successfully.
6. It verifies that the pre-existing pull request remains open.
7. It verifies that no downstream cascade pull requests were created while the
   collision was unresolved.
8. It verifies that the App appended the hidden
   `<!-- cascading-merge-app:` continuation metadata marker to the pre-existing
   pull request body.
9. It merges the pre-existing pull request.
10. It waits for the originating pull request to receive a comment stating that
    the interrupted cascade is resuming from the pre-existing pull request.
11. It waits for the App to report a successful automatic merge.
12. Starting with the second expected branch pair, it verifies that every
    remaining cascade pull request is created and merged.
13. It verifies that the original `existing-pr-<timestamp>` marker reaches
    `development`.

### Pass criteria

The scenario passes only when no duplicate pull request is created, the
existing pull request receives continuation metadata, no downstream work starts
before that pull request is merged, and the resumed cascade reaches
`development`.

A successful run ends with output similar to:

```text
PASS existing-pr: originating PR #140, resumed from pre-existing PR #139 through development
```

## How pull requests are correlated

The test repository can contain historical pull requests for the same branch
pairs. To avoid treating an older pull request as evidence for the current run,
the harness searches the pull request body for the current originating pull
request number.

A cascade pull request counts only when all three values match:

- Source branch
- Target branch
- `Originating PR #<number>` in the pull request body

This correlation applies to open, closed, and merged pull requests.

## Understanding failures

The harness exits immediately when an assertion fails. The final error usually
identifies the stage that did not complete.

| Error pattern                         | Likely meaning                                                                                 |
| ------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `Timed out waiting for comment`       | The App did not handle the webhook, emitted different report text, or exceeded the wait window |
| `Timed out waiting for cascade PR`    | The App did not create or resume the expected branch pair                                      |
| `Timed out waiting for PR ... MERGED` | The pull request remained open, failed checks, conflicted, or could not be merged              |
| `does not contain resume metadata`    | The App stopped but did not persist continuation state in the pull request body                |
| `Unexpected downstream cascade PR`    | The App continued past an unresolved existing pull request collision                           |
| `Expected README.md ... to contain`   | Pull request activity completed, but the tested content did not reach the final branch         |
| `Cascade exceeded maxMergeDepth`      | The App created an extra release-to-release pull request beyond the configured limit           |

When a comment wait fails, the harness prints the originating pull request and
its comments. When merging repeatedly fails, it prints the pull request checks.
These diagnostics provide the first place to inspect before reviewing App logs.

Because each wait allows about 60 seconds, a slow webhook or queued GitHub
operation can fail the test even when it completes later. The current script
does not provide a command-line timeout override.

## Cleanup after an interrupted run

The exit trap removes the temporary clone and attempts to delete the current
patch branch. Other remote artifacts can remain when a run is interrupted,
including open cascade pull requests or scenario commits on release branches.

The next scenario closes open pull requests and resets all configured branches.
To restore the baseline manually, run:

```bash
./reset-repository.sh --yes
```

Review open pull requests before and after cleanup:

```bash
gh pr list --repo jefeish/cascading-auto-merge-test --state open
```

> [!WARNING]
> Manual reset is destructive for the same reasons as the smoke harness. It
> force-rewrites the configured branches.

## Scope and limitations

The smoke tests validate the App's observable GitHub behavior in one dedicated
repository. They do not replace unit or integration tests for internal code
paths.

The harness does not currently test:

- Required status checks that remain pending for an extended period
- GitHub native auto-merge activation
- Ruleset combinations other than those configured on the test repository
- Webhook delivery recovery after a lost event
- Multiple simultaneous cascades
- Manual edits that remove or corrupt continuation metadata
