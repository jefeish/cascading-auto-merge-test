#!/usr/bin/env bash

set -euo pipefail

export GIT_PAGER=cat
export GH_PAGER=cat
export PAGER=cat

readonly EXPECTED_REPO="jefeish/cascading-auto-merge-test"
readonly ENTRY_RELEASE_BRANCH="release/0.1"
readonly TEST_FILE="README.md"
readonly REF_BRANCH="development"
readonly MAX_MERGE_DEPTH=5
readonly RETRY_DELAY=5
readonly MAX_ATTEMPTS=12
readonly -a EXPECTED_SOURCES=(
    "release/0.1"
    "release/1.1-rc.1"
    "release/1.1"
    "release/1.2"
    "release/2.0"
    "release/2.0.1-alpha"
)
readonly -a EXPECTED_TARGETS=(
    "release/1.1-rc.1"
    "release/1.1"
    "release/1.2"
    "release/2.0"
    "release/2.0.1-alpha"
    "$REF_BRANCH"
)

scenario="${1:-}"
assume_yes=false
work_dir=""
patch_branch=""

usage() {
    cat <<'EOF'
Usage: ./smoke-test.sh <standard|conflict|existing-pr|all> [options]

Options:
  --yes              Confirm destructive remote reset and PR cleanup
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

}

preflight() {
    require_command git
    require_command gh
    require_command mktemp

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "Run this script from its Git repository"
    cd "$repo_root"

    [[ -x ./reset-repository.sh ]] || fail "reset-repository.sh must be executable"
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
    local attempt number

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        number=$(find_cascade_pr "$source" "$target" "$origin_pr")
        if [[ -n "$number" ]]; then
            printf '%s\n' "$number"
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    fail "Timed out waiting for cascade PR ${source} -> ${target} from PR #${origin_pr}"
}

wait_for_pr_state() {
    local pr_number="$1"
    local expected_state="$2"
    local attempt state

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

create_patch_pr() {
    local value="$1"
    local label="$2"
    local pr_url

    patch_branch="smoke/${label}-$(date -u '+%Y%m%d%H%M%S')"
    git -C "$work_dir/repo" checkout --quiet -B "$patch_branch" "origin/$ENTRY_RELEASE_BRANCH"
    printf '\n%s\n' "$value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9001: Prepare ${label} smoke test"
    git -C "$work_dir/repo" push --quiet --set-upstream origin "$patch_branch"

    pr_url=$(gh pr create \
        --repo "$EXPECTED_REPO" \
        --head "$patch_branch" \
        --base "$ENTRY_RELEASE_BRANCH" \
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

branch_contains_marker() {
    local branch="$1"
    local marker="$2"

    gh api "repos/${EXPECTED_REPO}/contents/${TEST_FILE}?ref=${branch}" --jq .content |
        base64 --decode |
        grep -Fqx "$marker"
}

assert_branch_contains_marker() {
    local branch="$1"
    local marker="$2"

    branch_contains_marker "$branch" "$marker" ||
        fail "Expected ${TEST_FILE} on ${branch} to contain '${marker}'"
}

assert_no_downstream_pr() {
    local origin_pr="$1"
    local index number

    for ((index = 1; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        number=$(find_cascade_pr "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$origin_pr")
        [[ -z "$number" ]] || fail "Unexpected downstream cascade PR #${number} after existing-PR collision"
    done
}

run_standard() {
    local value origin_pr index cascade_pr cascade_pr_numbers=""
    value="standard-$(date -u '+%Y%m%d%H%M%S')"

    log "Scenario: standard cascade"
    prepare_scenario
    origin_pr=$(create_patch_pr "$value" standard)
    merge_pr "$origin_pr"

    wait_for_comment "$origin_pr" "Auto-merge was successful."
    wait_for_comment "$origin_pr" "Reached configured max merge depth (${MAX_MERGE_DEPTH}). Performed a final merge to __${REF_BRANCH}__ and stopped."
    for ((index = 0; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        cascade_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$origin_pr")
        wait_for_pr_state "$cascade_pr" MERGED
        cascade_pr_numbers+=" #${cascade_pr}"
    done
    cascade_pr=$(find_cascade_pr "release/2.0.1-alpha" "release/2.0.1-beta" "$origin_pr")
    [[ -z "$cascade_pr" ]] || fail "Cascade exceeded maxMergeDepth=${MAX_MERGE_DEPTH} with PR #${cascade_pr}"
    assert_branch_contains_marker "$REF_BRANCH" "$value"
    delete_patch_branch

    log "PASS standard: originating PR #${origin_pr}, cascade PRs${cascade_pr_numbers}"
}

run_conflict() {
    local target_value source_value resolved_value origin_pr stalled_pr index cascade_pr
    local first_target="${EXPECTED_TARGETS[0]}"
    target_value="target-$(date -u '+%Y%m%d%H%M%S')"
    source_value="source-$(date -u '+%Y%m%d%H%M%S')"
    resolved_value="resolved-${source_value}"

    log "Scenario: merge conflict and resume"
    prepare_scenario

    git -C "$work_dir/repo" checkout --quiet -B smoke-target "origin/$first_target"
    printf '\n%s\n' "$target_value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9002: Create downstream conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$first_target"

    origin_pr=$(create_patch_pr "$source_value" conflict)
    merge_pr "$origin_pr"
    stalled_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[0]}" "$first_target" "$origin_pr")
    wait_for_pr_state "$stalled_pr" OPEN
    wait_for_comment "$origin_pr" "Could not auto merge PR #${stalled_pr} due to merge conflicts."

    gh pr view "$stalled_pr" --repo "$EXPECTED_REPO" --json body --jq .body | grep -Fq '<!-- cascading-merge-app:' ||
        fail "Stalled PR #${stalled_pr} does not contain resume metadata"

    git -C "$work_dir/repo" fetch --quiet origin
    git -C "$work_dir/repo" checkout --quiet -B smoke-resolve "origin/$ENTRY_RELEASE_BRANCH"
    if git -C "$work_dir/repo" merge --no-edit "origin/$first_target" >/dev/null 2>&1; then
        fail "Expected a real merge conflict while resolving PR #${stalled_pr}"
    fi
    git -C "$work_dir/repo" checkout --ours -- "$TEST_FILE"
    printf '\n%s\n' "$resolved_value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9002: Resolve cascade conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$ENTRY_RELEASE_BRANCH"

    merge_pr "$stalled_pr"
    wait_for_comment "$origin_pr" "Resuming interrupted cascade from PR #${stalled_pr}"
    wait_for_comment "$origin_pr" "Auto-merge was successful."
    for ((index = 1; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        cascade_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$origin_pr")
        wait_for_pr_state "$cascade_pr" MERGED
    done
    assert_branch_contains_marker "$REF_BRANCH" "$resolved_value"
    delete_patch_branch

    log "PASS conflict: originating PR #${origin_pr}, resumed from #${stalled_pr} through ${REF_BRANCH}"
}

run_existing_pr() {
    local value collision_url collision_pr origin_pr collision_state
    value="existing-pr-$(date -u '+%Y%m%d%H%M%S')"

    log "Scenario: existing cascade PR collision"
    prepare_scenario

    collision_url=$(gh pr create \
        --repo "$EXPECTED_REPO" \
        --head "${EXPECTED_SOURCES[0]}" \
        --base "${EXPECTED_TARGETS[0]}" \
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