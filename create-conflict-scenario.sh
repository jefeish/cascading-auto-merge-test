#!/usr/bin/env bash

set -euo pipefail

export GIT_PAGER=cat
export GH_PAGER=cat
export PAGER=cat

readonly EXPECTED_REPO="jefeish/cascading-auto-merge-test"
readonly ENTRY_RELEASE_BRANCH="release/0.1"
readonly TEST_FILE="README.md"
readonly RETRY_DELAY=5
readonly MAX_ATTEMPTS=12

assume_yes=false
work_dir=""
first_target=""

usage() {
    cat <<'EOF'
Usage: ./create-conflict-scenario.sh [options]

Options:
  --yes              Confirm destructive remote reset and PR cleanup
  -h, --help         Show this help

Creates a real cascade merge conflict in jefeish/cascading-auto-merge-test,
prints the originating and stalled pull request URLs, and stops without
resolving the conflict or cleaning up remote artifacts.
EOF
}

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        rm -rf "$work_dir"
        work_dir=""
    fi
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                assume_yes=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                fail "Unknown option: $1"
                ;;
        esac
        shift
    done
}

verify_origin() {
    local origin_url normalized_url
    origin_url=$(git remote get-url origin)
    normalized_url=${origin_url%.git}
    normalized_url=${normalized_url%/}

    case "$normalized_url" in
        "https://github.com/${EXPECTED_REPO}"|"git@github.com:${EXPECTED_REPO}"|"ssh://git@github.com/${EXPECTED_REPO}") ;;
        *) fail "origin does not point to ${EXPECTED_REPO}: ${origin_url}" ;;
    esac
}

derive_first_target() {
    local branches=() branch

    while IFS= read -r branch; do
        [[ -n "$branch" ]] && branches+=("$branch")
    done < <(
        git ls-remote --heads origin |
            awk '{sub("refs/heads/", "", $2); print $2}'
    )

    first_target=$(node - "$ENTRY_RELEASE_BRANCH" "${branches[@]}" <<'NODE'
const [, , entryBranch, ...branches] = process.argv
const firstDigit = entryBranch.search(/\d/)

if (firstDigit === -1) process.exit(0)

const branchPrefix = entryBranch.slice(0, firstDigit)
const ordered = branches
    .filter(branch => branch.startsWith(branchPrefix))
    .map(branch => ({
        original: branch,
        tokenized: branch.split(/[/\-+_.]/)
    }))
    .sort((left, right) => {
        for (
            let index = 0;
            index < Math.max(left.tokenized.length, right.tokenized.length);
            index++
        ) {
            if (left.tokenized[index] === right.tokenized[index]) continue
            if (index >= left.tokenized.length) return -1
            if (index >= right.tokenized.length) return 1

            const leftNumber = Number.parseInt(left.tokenized[index], 10)
            const rightNumber = Number.parseInt(right.tokenized[index], 10)

            if (!Number.isNaN(leftNumber)) {
                return Number.isNaN(rightNumber) ? -1 : leftNumber - rightNumber
            }
            if (!Number.isNaN(rightNumber)) return 1

            return left.tokenized[index] > right.tokenized[index] ? 1 : -1
        }

        return left.original > right.original ? 1 : -1
    })
    .map(branch => branch.original)

const entryIndex = ordered.indexOf(entryBranch)
if (entryIndex >= 0 && entryIndex + 1 < ordered.length) {
    process.stdout.write(ordered[entryIndex + 1])
}
NODE
    )

    [[ -n "$first_target" ]] || fail "No downstream release branch found after ${ENTRY_RELEASE_BRANCH}"
}

preflight() {
    require_command git
    require_command gh
    require_command mktemp
    require_command node

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "Run this script from its Git repository"
    cd "$repo_root"

    [[ -x ./reset-repository.sh ]] || fail "reset-repository.sh must be executable"
    verify_origin
}

confirm_destructive_run() {
    if [[ "$assume_yes" == true ]]; then
        return
    fi

    printf '\nThis will close open PRs and force-reset release branches in %s.\n' "$EXPECTED_REPO"
    read -r -p "Type the repository name to continue: " confirmation
    [[ "$confirmation" == "$EXPECTED_REPO" ]] || fail "Confirmation did not match; no changes made"
}

close_open_prs() {
    local number
    while IFS= read -r number; do
        [[ -n "$number" ]] || continue
        log "Closing open PR #${number}"
        gh pr close "$number" --repo "$EXPECTED_REPO" >/dev/null
    done < <(gh pr list --repo "$EXPECTED_REPO" --state open --limit 100 --json number --jq '.[].number')
}

wait_for_comment() {
    local pr_number="$1"
    local expected="$2"
    local attempt

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        if gh api "repos/${EXPECTED_REPO}/issues/${pr_number}/comments" --paginate --jq '.[].body' | grep -Fq "$expected"; then
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    gh pr view "$pr_number" --repo "$EXPECTED_REPO" --comments || true
    fail "Timed out waiting for comment on PR #${pr_number}: ${expected}"
}

find_cascade_pr() {
    local origin_pr="$1"

    gh pr list \
        --repo "$EXPECTED_REPO" \
        --state all \
        --head "$ENTRY_RELEASE_BRANCH" \
        --base "$first_target" \
        --limit 100 \
        --json number,body \
        --jq ".[] | select(.body != null and (.body | contains(\"Originating PR #${origin_pr}\"))) | .number" |
        head -n 1
}

wait_for_cascade_pr() {
    local origin_pr="$1"
    local attempt number

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        number=$(find_cascade_pr "$origin_pr")
        if [[ -n "$number" ]]; then
            printf '%s\n' "$number"
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    fail "Timed out waiting for cascade PR ${ENTRY_RELEASE_BRANCH} -> ${first_target} from PR #${origin_pr}"
}

wait_for_pr_state() {
    local pr_number="$1"
    local expected_state="$2"
    local attempt state=""

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        state=$(gh pr view "$pr_number" --repo "$EXPECTED_REPO" --json state --jq .state)
        if [[ "$state" == "$expected_state" ]]; then
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    fail "Timed out waiting for PR #${pr_number} to reach state ${expected_state}; last state was ${state}"
}

merge_pr() {
    local pr_number="$1"
    local attempt

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        if gh pr merge "$pr_number" --repo "$EXPECTED_REPO" --merge --admin >/dev/null 2>&1; then
            wait_for_pr_state "$pr_number" MERGED
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    gh pr checks "$pr_number" --repo "$EXPECTED_REPO" || true
    fail "Timed out trying to merge PR #${pr_number}"
}

create_scenario() {
    local timestamp target_value source_value patch_branch pr_url origin_pr stalled_pr stalled_body
    timestamp=$(date -u '+%Y%m%d%H%M%S')
    target_value="conflict-target-${timestamp}"
    source_value="conflict-source-${timestamp}"
    patch_branch="smoke/conflict-observation-${timestamp}"

    close_open_prs
    log "Resetting repository branches to the deterministic baseline"
    ./reset-repository.sh --yes >/dev/null
    derive_first_target

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cascade-conflict.XXXXXX")
    git clone --quiet "$(git remote get-url origin)" "$work_dir/repo"
    git -C "$work_dir/repo" config user.name "Cascade Conflict Scenario"
    git -C "$work_dir/repo" config user.email "cascade-conflict@example.invalid"

    log "Creating target-side change on ${first_target}"
    git -C "$work_dir/repo" checkout --quiet -B conflict-target "origin/$first_target"
    printf '\n%s\n' "$target_value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9004: Create observed cascade conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$first_target"

    log "Creating originating pull request into ${ENTRY_RELEASE_BRANCH}"
    git -C "$work_dir/repo" checkout --quiet -B "$patch_branch" "origin/$ENTRY_RELEASE_BRANCH"
    printf '\n%s\n' "$source_value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9004: Trigger observed cascade conflict"
    git -C "$work_dir/repo" push --quiet --set-upstream origin "$patch_branch"

    pr_url=$(gh pr create \
        --repo "$EXPECTED_REPO" \
        --head "$patch_branch" \
        --base "$ENTRY_RELEASE_BRANCH" \
        --title "JIRA-9004: Observe cascade conflict handling" \
        --body "Creates a live cascade conflict for manual developer investigation.")
    origin_pr=$(gh pr view "$pr_url" --repo "$EXPECTED_REPO" --json number --jq .number)
    merge_pr "$origin_pr"

    stalled_pr=$(wait_for_cascade_pr "$origin_pr")
    wait_for_pr_state "$stalled_pr" OPEN
    wait_for_comment "$origin_pr" "Could not auto merge PR #${stalled_pr} due to merge conflicts."

    stalled_body=$(gh pr view "$stalled_pr" --repo "$EXPECTED_REPO" --json body --jq .body)
    grep -Fq '<!-- cascading-merge-app:' <<<"$stalled_body" ||
        fail "Stalled PR #${stalled_pr} does not contain resume metadata"

    printf '\nCascade conflict is ready for manual investigation.\n\n'
    printf 'Originating PR:    https://github.com/%s/pull/%s\n' "$EXPECTED_REPO" "$origin_pr"
    printf 'Stalled cascade PR: https://github.com/%s/pull/%s\n' "$EXPECTED_REPO" "$stalled_pr"
    printf 'Cascade:            %s -> %s\n' "$ENTRY_RELEASE_BRANCH" "$first_target"
    printf 'Conflicted file:     %s\n\n' "$TEST_FILE"
    printf 'The stalled PR remains open. No conflict resolution or remote cleanup was performed.\n'
}

main() {
    parse_args "$@"
    preflight
    confirm_destructive_run
    create_scenario
}

main "$@"