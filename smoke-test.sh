#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_REPO="jefeish/cascading-auto-merge-test"
readonly SOURCE_BRANCH="release/2026-01-20-01"
readonly TARGET_BRANCH="release/2026-03-12-02"
readonly FINAL_BRANCH="development"
readonly FIXTURE_PATH="smoke/merge-target.txt"
readonly DEFAULT_TIMEOUT=300

scenario="${1:-}"
assume_yes=false
preflight_only=false
timeout="$DEFAULT_TIMEOUT"
work_dir=""
patch_branch=""

usage() {
    cat <<'EOF'
Usage: ./smoke-test.sh <standard|conflict|existing-pr|all> [options]

Options:
  --yes              Confirm destructive remote reset and PR cleanup
  --preflight-only   Validate prerequisites without changing local or GitHub state
  --timeout SECONDS  Maximum wait for each asynchronous App outcome (default: 300)
  -h, --help         Show this help

These tests close open PRs, force-reset all configured branches, and create real
commits and pull requests in jefeish/cascading-auto-merge-test.
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
    if [[ -n "$patch_branch" && -n "$work_dir" && -d "$work_dir/repo" ]]; then
        git -C "$work_dir/repo" push --quiet origin --delete "$patch_branch" >/dev/null 2>&1 || true
        patch_branch=""
    fi

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
    if [[ "$scenario" == "-h" || "$scenario" == "--help" ]]; then
        usage
        exit 0
    fi

    case "$scenario" in
        standard|conflict|existing-pr|all) ;;
        *)
            usage >&2
            exit 2
            ;;
    esac

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                assume_yes=true
                ;;
            --preflight-only)
                preflight_only=true
                ;;
            --timeout)
                shift
                [[ $# -gt 0 ]] || fail "--timeout requires a value"
                timeout="$1"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
        shift
    done

    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "Timeout must be a positive integer"
}

preflight() {
    require_command git
    require_command gh
    require_command mktemp

    local repo_root repo_name remote_url
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "Run this script from its Git repository"
    cd "$repo_root"

    [[ -z "$(git status --porcelain)" ]] || fail "Working tree must be clean before running live smoke tests"
    [[ "$(git branch --show-current)" == "main" ]] || fail "Check out main before running live smoke tests"

    remote_url=$(git remote get-url origin)
    [[ "$remote_url" == *"github.com/${EXPECTED_REPO}"* || "$remote_url" == *"github.com:${EXPECTED_REPO}"* ]] ||
        fail "origin must point to ${EXPECTED_REPO}; found ${remote_url}"

    gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
    repo_name=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
    [[ "$repo_name" == "$EXPECTED_REPO" ]] || fail "GitHub CLI resolved ${repo_name}, expected ${EXPECTED_REPO}"

    for branch in "$SOURCE_BRANCH" "$TARGET_BRANCH" "$FINAL_BRANCH"; do
        git ls-remote --exit-code --heads origin "$branch" >/dev/null || fail "Missing remote branch: $branch"
    done

    [[ -f "$FIXTURE_PATH" ]] || fail "Missing fixture: $FIXTURE_PATH"
    [[ -x ./reset-repository.sh ]] || fail "reset-repository.sh must be executable"

    log "Preflight passed for ${EXPECTED_REPO}"
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

prepare_scenario() {
    cleanup
    close_open_prs
    log "Resetting repository branches to the deterministic baseline"
    ./reset-repository.sh --yes >/dev/null

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cascade-smoke.XXXXXX")
    git clone --quiet "$(git remote get-url origin)" "$work_dir/repo"
    git -C "$work_dir/repo" config user.name "Cascade Smoke Test"
    git -C "$work_dir/repo" config user.email "cascade-smoke@example.invalid"
}

wait_for_comment() {
    local pr_number="$1"
    local expected="$2"
    local deadline=$((SECONDS + timeout))

    while ((SECONDS < deadline)); do
        if gh api "repos/${EXPECTED_REPO}/issues/${pr_number}/comments" --paginate --jq '.[].body' | grep -Fq "$expected"; then
            return 0
        fi
        sleep 5
    done

    gh pr view "$pr_number" --repo "$EXPECTED_REPO" --comments || true
    fail "Timed out waiting for comment on PR #${pr_number}: ${expected}"
}

find_cascade_pr() {
    local source="$1"
    local target="$2"
    local origin_pr="$3"

    gh pr list \
        --repo "$EXPECTED_REPO" \
        --state all \
        --head "$source" \
        --base "$target" \
        --limit 100 \
        --json number,body \
        --jq ".[] | select(.body != null and (.body | contains(\"Originating PR #${origin_pr}\"))) | .number" |
        head -n 1
}

wait_for_cascade_pr() {
    local source="$1"
    local target="$2"
    local origin_pr="$3"
    local deadline=$((SECONDS + timeout))
    local number

    while ((SECONDS < deadline)); do
        number=$(find_cascade_pr "$source" "$target" "$origin_pr")
        if [[ -n "$number" ]]; then
            printf '%s\n' "$number"
            return 0
        fi
        sleep 5
    done

    fail "Timed out waiting for cascade PR ${source} -> ${target} from PR #${origin_pr}"
}

wait_for_pr_state() {
    local pr_number="$1"
    local expected_state="$2"
    local deadline=$((SECONDS + timeout))
    local state

    while ((SECONDS < deadline)); do
        state=$(gh pr view "$pr_number" --repo "$EXPECTED_REPO" --json state --jq .state)
        if [[ "$state" == "$expected_state" ]]; then
            return 0
        fi
        sleep 5
    done

    fail "Timed out waiting for PR #${pr_number} to reach state ${expected_state}; last state was ${state}"
}

merge_pr() {
    local pr_number="$1"
    local deadline=$((SECONDS + timeout))

    while ((SECONDS < deadline)); do
        if gh pr merge "$pr_number" --repo "$EXPECTED_REPO" --merge >/dev/null 2>&1; then
            wait_for_pr_state "$pr_number" MERGED
            return 0
        fi
        sleep 5
    done

    gh pr checks "$pr_number" --repo "$EXPECTED_REPO" || true
    fail "Timed out trying to merge PR #${pr_number}"
}

create_patch_pr() {
    local value="$1"
    local label="$2"
    local pr_url

    patch_branch="smoke/${label}-$(date -u '+%Y%m%d%H%M%S')"
    git -C "$work_dir/repo" checkout --quiet -B "$patch_branch" "origin/$SOURCE_BRANCH"
    printf '%s\n' "$value" >"$work_dir/repo/$FIXTURE_PATH"
    git -C "$work_dir/repo" add "$FIXTURE_PATH"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9001: Prepare ${label} smoke test"
    git -C "$work_dir/repo" push --quiet --set-upstream origin "$patch_branch"

    pr_url=$(gh pr create \
        --repo "$EXPECTED_REPO" \
        --head "$patch_branch" \
        --base "$SOURCE_BRANCH" \
        --title "JIRA-9001: ${label} cascade smoke test" \
        --body "Live ${label} smoke test for the Cascading Merge App.")
    gh pr view "$pr_url" --repo "$EXPECTED_REPO" --json number --jq .number
}

delete_patch_branch() {
    if [[ -n "$patch_branch" ]]; then
        git -C "$work_dir/repo" push --quiet origin --delete "$patch_branch" >/dev/null 2>&1 || true
        patch_branch=""
    fi
}

branch_fixture_value() {
    local branch="$1"
    gh api \
        -H "Accept: application/vnd.github.raw+json" \
        "repos/${EXPECTED_REPO}/contents/${FIXTURE_PATH}?ref=${branch}"
}

assert_branch_value() {
    local branch="$1"
    local expected="$2"
    local actual
    actual=$(branch_fixture_value "$branch")
    [[ "$actual" == "$expected" ]] || fail "Expected ${FIXTURE_PATH} on ${branch} to be '${expected}', found '${actual}'"
}

assert_no_downstream_pr() {
    local origin_pr="$1"
    local number
    number=$(find_cascade_pr "$TARGET_BRANCH" "$FINAL_BRANCH" "$origin_pr")
    [[ -z "$number" ]] || fail "Unexpected downstream cascade PR #${number} after existing-PR collision"
}

run_standard() {
    local value origin_pr first_pr final_pr
    value="standard-$(date -u '+%Y%m%d%H%M%S')"

    log "Scenario: standard cascade"
    prepare_scenario
    origin_pr=$(create_patch_pr "$value" standard)
    merge_pr "$origin_pr"

    wait_for_comment "$origin_pr" "Auto-merge was successful."
    first_pr=$(wait_for_cascade_pr "$SOURCE_BRANCH" "$TARGET_BRANCH" "$origin_pr")
    final_pr=$(wait_for_cascade_pr "$TARGET_BRANCH" "$FINAL_BRANCH" "$origin_pr")
    wait_for_pr_state "$first_pr" MERGED
    wait_for_pr_state "$final_pr" MERGED
    assert_branch_value "$FINAL_BRANCH" "$value"
    delete_patch_branch

    log "PASS standard: originating PR #${origin_pr}, cascade PRs #${first_pr} and #${final_pr}"
}

run_conflict() {
    local target_value source_value resolved_value origin_pr stalled_pr final_pr
    target_value="target-$(date -u '+%Y%m%d%H%M%S')"
    source_value="source-$(date -u '+%Y%m%d%H%M%S')"
    resolved_value="resolved-${source_value}"

    log "Scenario: merge conflict and resume"
    prepare_scenario

    git -C "$work_dir/repo" checkout --quiet -B smoke-target "origin/$TARGET_BRANCH"
    printf '%s\n' "$target_value" >"$work_dir/repo/$FIXTURE_PATH"
    git -C "$work_dir/repo" add "$FIXTURE_PATH"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9002: Create downstream conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$TARGET_BRANCH"

    origin_pr=$(create_patch_pr "$source_value" conflict)
    merge_pr "$origin_pr"
    stalled_pr=$(wait_for_cascade_pr "$SOURCE_BRANCH" "$TARGET_BRANCH" "$origin_pr")
    wait_for_pr_state "$stalled_pr" OPEN
    wait_for_comment "$origin_pr" "Could not auto merge PR #${stalled_pr} due to merge conflicts."

    gh pr view "$stalled_pr" --repo "$EXPECTED_REPO" --json body --jq .body | grep -Fq '<!-- cascading-merge-app:' ||
        fail "Stalled PR #${stalled_pr} does not contain resume metadata"

    git -C "$work_dir/repo" fetch --quiet origin
    git -C "$work_dir/repo" checkout --quiet -B smoke-resolve "origin/$SOURCE_BRANCH"
    if git -C "$work_dir/repo" merge --no-edit "origin/$TARGET_BRANCH" >/dev/null 2>&1; then
        fail "Expected a real merge conflict while resolving PR #${stalled_pr}"
    fi
    printf '%s\n' "$resolved_value" >"$work_dir/repo/$FIXTURE_PATH"
    git -C "$work_dir/repo" add "$FIXTURE_PATH"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9002: Resolve cascade conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$SOURCE_BRANCH"

    merge_pr "$stalled_pr"
    wait_for_comment "$origin_pr" "Resuming interrupted cascade from PR #${stalled_pr}"
    wait_for_comment "$origin_pr" "Auto-merge was successful."
    final_pr=$(wait_for_cascade_pr "$TARGET_BRANCH" "$FINAL_BRANCH" "$origin_pr")
    wait_for_pr_state "$final_pr" MERGED
    assert_branch_value "$FINAL_BRANCH" "$resolved_value"
    delete_patch_branch

    log "PASS conflict: originating PR #${origin_pr}, resumed from #${stalled_pr}, final PR #${final_pr}"
}

run_existing_pr() {
    local value collision_url collision_pr origin_pr collision_state
    value="existing-pr-$(date -u '+%Y%m%d%H%M%S')"

    log "Scenario: existing cascade PR collision"
    prepare_scenario

    collision_url=$(gh pr create \
        --repo "$EXPECTED_REPO" \
        --head "$SOURCE_BRANCH" \
        --base "$TARGET_BRANCH" \
        --title "JIRA-9003: Existing release promotion PR" \
        --body "Pre-existing real PR used by the cascading smoke test.")
    collision_pr=$(gh pr view "$collision_url" --repo "$EXPECTED_REPO" --json number --jq .number)

    origin_pr=$(create_patch_pr "$value" existing-pr)
    merge_pr "$origin_pr"
    wait_for_comment "$origin_pr" "there is already a pull request open."
    wait_for_comment "$origin_pr" "Auto-merge action did not complete successfully."

    collision_state=$(gh pr view "$collision_pr" --repo "$EXPECTED_REPO" --json state --jq .state)
    [[ "$collision_state" == "OPEN" ]] || fail "Expected collision PR #${collision_pr} to remain open"
    assert_no_downstream_pr "$origin_pr"
    delete_patch_branch

    log "PASS existing-pr: originating PR #${origin_pr}, pre-existing PR #${collision_pr} remained open"
}

main() {
    parse_args "$@"
    preflight

    if [[ "$preflight_only" == true ]]; then
        return
    fi

    confirm_destructive_run

    case "$scenario" in
        standard) run_standard ;;
        conflict) run_conflict ;;
        existing-pr) run_existing_pr ;;
        all)
            run_standard
            run_conflict
            run_existing_pr
            ;;
    esac
}

main "$@"