#!/usr/bin/env bash

set -Eeuo pipefail

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
EXPECTED_SOURCES=()
EXPECTED_TARGETS=()
NEXT_RELEASE_BRANCH=""
scenario="${1:-}"
assume_yes=false
work_dir=""
patch_branch=""
report_dir=""
report_active=false
run_started_at=""
run_actor=""
expected_branch_sequence=""
failure_message=""
current_scenario=""
current_scenario_title=""
current_scenario_started_at=""
current_scenario_summary=""
current_pr_file=""
current_origin_pr=""
current_stalled_pr=""

capture_error() {
    local exit_code="$1"
    local line_number="$2"
    local command="$3"

    if [[ -z "$failure_message" ]]; then
        failure_message="Command failed with status ${exit_code} at line ${line_number}: \`${command}\`"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./smoke-test.sh <standard|conflict|existing-pr|all> [options]

Options:
  --yes              Confirm destructive remote reset and PR cleanup
  -h, --help         Show this help

These tests close open PRs, force-reset all configured branches, and create real
commits and pull requests in jefeish/cascading-auto-merge-test. A GitHub issue
for each scenario reports the starting conditions, result, and observed PRs.
EOF
}

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    failure_message="$*"
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

finalize() {
    local exit_code="$1"

    trap - EXIT
    set +e

    if [[ "$report_active" == true && -n "$current_scenario" ]]; then
        if ((exit_code == 0)); then
            finish_scenario PASS "${current_scenario_summary:-Scenario completed successfully.}"
        else
            finish_scenario FAIL "${failure_message:-Smoke test exited with status ${exit_code}.}"
        fi
    fi

    cleanup

    if [[ -n "$report_dir" && -d "$report_dir" ]]; then
        rm -rf "$report_dir"
    fi

    exit "$exit_code"
}

trap 'capture_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap 'finalize $?' EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

initialize_report() {
    local index

    report_dir=$(mktemp -d "${TMPDIR:-/tmp}/cascade-smoke-report.XXXXXX")
    run_started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    run_actor=$(gh api user --jq .login 2>/dev/null || printf 'unknown')
    expected_branch_sequence="${EXPECTED_SOURCES[0]}"

    for ((index = 0; index < ${#EXPECTED_TARGETS[@]}; index++)); do
        expected_branch_sequence+=" -> ${EXPECTED_TARGETS[index]}"
    done

    if ! gh api "repos/${EXPECTED_REPO}/contents/.github/cascading-merge.yml?ref=main" --jq .content |
        base64 --decode >"$report_dir/repository-config.yml"; then
        printf '%s\n' 'Unable to read repository configuration.' >"$report_dir/repository-config.yml"
    fi

    report_active=true
}

begin_scenario() {
    current_scenario="$1"
    current_scenario_title="$2"
    current_scenario_started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    current_scenario_summary=""
    current_pr_file="$report_dir/${current_scenario}-prs.tsv"
    current_origin_pr=""
    current_stalled_pr=""
    : >"$current_pr_file"
}

record_pr() {
    local role="$1"
    local pr_number="$2"

    [[ -n "$current_pr_file" && -n "$pr_number" ]] || return

    if awk -F '\t' -v number="$pr_number" '$2 == number { found = 1 } END { exit !found }' "$current_pr_file"; then
        return
    fi

    printf '%s\t%s\n' "$role" "$pr_number" >>"$current_pr_file"
}

record_repair_prs() {
    local stalled_pr="$1"
    local repair_pr

    while IFS= read -r repair_pr; do
        [[ -n "$repair_pr" ]] || continue
        record_pr "Conflict repair" "$repair_pr"
    done < <(
        gh pr list \
            --repo "$EXPECTED_REPO" \
            --state all \
            --limit 100 \
            --json number,body \
            --jq ".[] | select(.body != null and (.body | contains(\"\\\"kind\\\":\\\"repair\\\"\") and contains(\"\\\"stalledPr\\\":${stalled_pr}\"))) | .number"
    )
}

discover_related_prs() {
    local related_pr

    if [[ -n "$current_origin_pr" ]]; then
        while IFS= read -r related_pr; do
            [[ -n "$related_pr" ]] || continue
            record_pr "Related cascade" "$related_pr"
        done < <(
            gh pr list \
                --repo "$EXPECTED_REPO" \
                --state all \
                --limit 100 \
                --json number,body \
                --jq ".[] | select(.body != null and (.body | contains(\"Originating PR #${current_origin_pr}\"))) | .number"
        )
    fi

    if [[ -n "$current_stalled_pr" ]]; then
        record_repair_prs "$current_stalled_pr"
    fi
}

append_pr_table() {
    local destination="$1"
    local role pr_number details number url state head base title

    {
        printf '| Role | Pull request | Branches | Final state | Title |\n'
        printf '| ---- | ------------ | -------- | ----------- | ----- |\n'
    } >>"$destination"

    if [[ ! -s "$current_pr_file" ]]; then
        printf '| None recorded | - | - | - | - |\n' >>"$destination"
        return
    fi

    while IFS=$'\t' read -r role pr_number; do
        details=$(gh pr view "$pr_number" \
            --repo "$EXPECTED_REPO" \
            --json number,url,state,headRefName,baseRefName,title \
            --jq '[.number, .url, .state, .headRefName, .baseRefName, .title] | @tsv' 2>/dev/null || true)

        if [[ -n "$details" ]]; then
            IFS=$'\t' read -r number url state head base title <<<"$details"
            title=${title//|/\\|}
            printf '| %s | [#%s](%s) | `%s` to `%s` | %s | %s |\n' \
                "$role" "$number" "$url" "$head" "$base" "$state" "$title" >>"$destination"
        else
            printf '| %s | [#%s](https://github.com/%s/pull/%s) | unavailable | unavailable | unavailable |\n' \
                "$role" "$pr_number" "$EXPECTED_REPO" "$pr_number" >>"$destination"
        fi
    done <"$current_pr_file"
}

finish_scenario() {
    local status="$1"
    local summary="$2"
    local section_file="$report_dir/${current_scenario}-result.md"
    local status_icon

    if [[ "$status" == "PASS" ]]; then
        status_icon=":white_check_mark:"
    else
        status_icon=":x:"
    fi

    discover_related_prs

    {
        printf '### %s\n\n' "$current_scenario_title"
        printf '* Status: %s **%s**\n' "$status_icon" "$status"
        printf '* Started: `%s`\n' "$current_scenario_started_at"
        printf '* Result: %s\n\n' "$summary"
        printf '#### Pull requests\n\n'
    } >"$section_file"

    append_pr_table "$section_file"
    publish_smoke_report "$status" "$section_file"

    current_scenario=""
    current_scenario_title=""
    current_scenario_started_at=""
    current_scenario_summary=""
    current_pr_file=""
    current_origin_pr=""
    current_stalled_pr=""
}

append_starting_conditions() {
    local destination="$1"
    local index hop_type

    {
        printf '## Starting conditions\n\n'
        printf '| Setting | Value |\n'
        printf '| ------- | ----- |\n'
        printf '| Repository | `%s` |\n' "$EXPECTED_REPO"
        printf '| Requested scenario | `%s` |\n' "$scenario"
        printf '| Started | `%s` |\n' "$run_started_at"
        printf '| Actor | `%s` |\n' "$run_actor"
        printf '| Entry branch | `%s` |\n' "$ENTRY_RELEASE_BRANCH"
        printf '| Final ref branch | `%s` |\n' "$REF_BRANCH"
        printf '| maxMergeDepth | `%s` |\n' "$MAX_MERGE_DEPTH"
        printf '| Retry interval | `%s seconds` |\n' "$RETRY_DELAY"
        printf '| Maximum attempts | `%s` |\n' "$MAX_ATTEMPTS"
        printf '| Test file | `%s` |\n\n' "$TEST_FILE"
        printf '### Expected branch sequence\n\n'
        printf '```text\n%s\n```\n\n' "$expected_branch_sequence"
        printf '### Expected hops\n\n'
        printf '| # | Source | Target | Depth accounting |\n'
        printf '| - | ------ | ------ | ---------------- |\n'
    } >>"$destination"

    for ((index = 0; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        if ((index < MAX_MERGE_DEPTH)); then
            hop_type="Consumes depth"
        else
            hop_type="Forced final ref merge"
        fi
        printf '| %s | `%s` | `%s` | %s |\n' \
            "$((index + 1))" "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$hop_type" >>"$destination"
    done

    {
        printf '\n<details>\n'
        printf '<summary>Repository cascade configuration</summary>\n\n'
        printf '```yaml\n'
        cat "$report_dir/repository-config.yml"
        printf '```\n\n'
        printf '</details>\n\n'
    } >>"$destination"
}

publish_smoke_report() {
    local scenario_status="$1"
    local section_file="$2"
    local overall_icon issue_title issue_url
    local body_file="$report_dir/smoke-report.md"

    if [[ "$scenario_status" == "PASS" ]]; then
        overall_icon=":white_check_mark:"
    else
        overall_icon=":x:"
    fi

    {
        printf '# Cascading Merge Smoke Test Results\n\n'
        printf '> %s **Scenario result: %s**\n\n' "$overall_icon" "$scenario_status"
    } >"$body_file"

    append_starting_conditions "$body_file"
    printf '## Scenario results\n\n' >>"$body_file"
    cat "$section_file" >>"$body_file"
    printf '\n\n' >>"$body_file"

    {
        printf '## Report notes\n\n'
        printf '* This issue is generated by `smoke-test.sh`.\n'
        printf '* Pull request states are queried when the final report is created.\n'
        printf '* App-generated cascade report issues are separate and remain invocation-scoped.\n'
    } >>"$body_file"

    issue_title="Cascading merge smoke test ${scenario_status}: ${current_scenario} (${current_scenario_started_at})"
    if issue_url=$(gh issue create \
        --repo "$EXPECTED_REPO" \
        --title "$issue_title" \
        --body-file "$body_file" 2>/dev/null); then
        log "Smoke test report: ${issue_url}"
    else
        printf '\nWARNING: Failed to create the smoke test report issue.\n' >&2
        printf 'Report body retained until process exit: %s\n' "$body_file" >&2
    fi
}

build_expected_branch_pairs() {
        local branches=() ordered_branches branch entry_index=-1 index

        while IFS= read -r branch; do
                [[ -n "$branch" ]] && branches+=("$branch")
        done < <(
                git ls-remote --heads origin |
                        awk '{sub("refs/heads/", "", $2); print $2}'
        )

        ordered_branches=$(node - "$ENTRY_RELEASE_BRANCH" "${branches[@]}" <<'NODE'
const [, , targetBranch, ...branches] = process.argv
const firstDigit = targetBranch.search(/\d/)

if (firstDigit === -1) process.exit(0)

const branchPrefix = targetBranch.slice(0, firstDigit)
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

process.stdout.write(ordered.join('\n'))
NODE
        )

        EXPECTED_SOURCES=()
        EXPECTED_TARGETS=()
        NEXT_RELEASE_BRANCH=""

        index=0
        while IFS= read -r branch; do
                [[ -n "$branch" ]] || continue

                if [[ "$branch" == "$ENTRY_RELEASE_BRANCH" ]]; then
                        entry_index=$index
                fi

                if ((entry_index >= 0)); then
                        if ((${#EXPECTED_SOURCES[@]} <= MAX_MERGE_DEPTH)); then
                                EXPECTED_SOURCES+=("$branch")
                        elif [[ -z "$NEXT_RELEASE_BRANCH" ]]; then
                                NEXT_RELEASE_BRANCH="$branch"
                        fi
                fi

                ((index += 1))
        done <<<"$ordered_branches"

        ((entry_index >= 0)) || fail "Entry release branch not found: ${ENTRY_RELEASE_BRANCH}"
        ((${#EXPECTED_SOURCES[@]} > 1)) || fail "No downstream release branch found after ${ENTRY_RELEASE_BRANCH}"
        EXPECTED_TARGETS=("${EXPECTED_SOURCES[@]:1}" "$REF_BRANCH")
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
    require_command node
    require_command base64

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "Run this script from its Git repository"
    cd "$repo_root"

    [[ -x ./reset-repository.sh ]] || fail "reset-repository.sh must be executable"
    build_expected_branch_pairs
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

wait_for_repair_pr() {
    local stalled_pr="$1"
    local attempt number

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        number=$(gh pr list \
            --repo "$EXPECTED_REPO" \
            --state all \
            --limit 100 \
            --json number,body \
            --jq ".[] | select(.body != null and (.body | contains(\"\\\"kind\\\":\\\"repair\\\"\") and contains(\"\\\"stalledPr\\\":${stalled_pr}\"))) | .number" |
            head -n 1)

        if [[ -n "$number" ]]; then
            printf '%s\n' "$number"
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    fail "Timed out waiting for a repair PR linked to stalled cascade PR #${stalled_pr}"
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
    local value origin_pr index cascade_pr cascade_pr_numbers="" last_source_index
    value="standard-$(date -u '+%Y%m%d%H%M%S')"

    begin_scenario standard "Standard cascade"
    log "Scenario: standard cascade"
    prepare_scenario
    origin_pr=$(create_patch_pr "$value" standard)
    current_origin_pr="$origin_pr"
    record_pr "Originating" "$origin_pr"
    merge_pr "$origin_pr"

    wait_for_comment "$origin_pr" "Auto-merge was successful."
    wait_for_comment "$origin_pr" "Reached configured max merge depth (${MAX_MERGE_DEPTH}). Performed a final merge to __${REF_BRANCH}__ and stopped."
    for ((index = 0; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        cascade_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$origin_pr")
        record_pr "Cascade hop $((index + 1))" "$cascade_pr"
        wait_for_pr_state "$cascade_pr" MERGED
        cascade_pr_numbers+=" #${cascade_pr}"
    done
    if [[ -n "$NEXT_RELEASE_BRANCH" ]]; then
        last_source_index=$((${#EXPECTED_SOURCES[@]} - 1))
        cascade_pr=$(find_cascade_pr "${EXPECTED_SOURCES[last_source_index]}" "$NEXT_RELEASE_BRANCH" "$origin_pr")
        [[ -z "$cascade_pr" ]] || fail "Cascade exceeded maxMergeDepth=${MAX_MERGE_DEPTH} with PR #${cascade_pr}"
    fi
    assert_branch_contains_marker "$REF_BRANCH" "$value"
    delete_patch_branch

    log "PASS standard: originating PR #${origin_pr}, cascade PRs${cascade_pr_numbers}"
    finish_scenario PASS "Originating PR #${origin_pr} cascaded through ${REF_BRANCH} within maxMergeDepth=${MAX_MERGE_DEPTH}."
}

run_conflict() {
    local target_value source_value resolved_value origin_pr stalled_pr repair_pr repair_branch index cascade_pr
    local first_target="${EXPECTED_TARGETS[0]}"
    target_value="target-$(date -u '+%Y%m%d%H%M%S')"
    source_value="source-$(date -u '+%Y%m%d%H%M%S')"
    resolved_value="resolved-${source_value}"

    begin_scenario conflict "Merge conflict and protected-branch repair"
    log "Scenario: merge conflict and protected-branch repair"
    prepare_scenario

    git -C "$work_dir/repo" checkout --quiet -B smoke-target "origin/$first_target"
    printf '\n%s\n' "$target_value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9002: Create downstream conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$first_target"

    origin_pr=$(create_patch_pr "$source_value" conflict)
    current_origin_pr="$origin_pr"
    record_pr "Originating" "$origin_pr"
    merge_pr "$origin_pr"
    stalled_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[0]}" "$first_target" "$origin_pr")
    current_stalled_pr="$stalled_pr"
    record_pr "Stalled cascade" "$stalled_pr"
    wait_for_pr_state "$stalled_pr" OPEN
    wait_for_comment "$origin_pr" "Could not auto merge PR #${stalled_pr} due to merge conflicts."

    gh pr view "$stalled_pr" --repo "$EXPECTED_REPO" --json body --jq .body | grep -Fq '<!-- cascading-merge-app:' ||
        fail "Stalled PR #${stalled_pr} does not contain resume metadata"

    repair_pr=$(wait_for_repair_pr "$stalled_pr")
    record_pr "Conflict repair" "$repair_pr"
    repair_branch=$(gh pr view "$repair_pr" --repo "$EXPECTED_REPO" --json headRefName --jq .headRefName)

    git -C "$work_dir/repo" fetch --quiet origin
    git -C "$work_dir/repo" checkout --quiet -B smoke-resolve "origin/$repair_branch"
    if git -C "$work_dir/repo" merge --no-edit "origin/$ENTRY_RELEASE_BRANCH" >/dev/null 2>&1; then
        fail "Expected a real merge conflict while updating repair PR #${repair_pr}"
    fi
    git -C "$work_dir/repo" checkout --theirs -- "$TEST_FILE"
    printf '\n%s\n' "$resolved_value" >>"$work_dir/repo/$TEST_FILE"
    git -C "$work_dir/repo" add "$TEST_FILE"
    git -C "$work_dir/repo" commit --quiet -m "JIRA-9002: Resolve cascade conflict"
    git -C "$work_dir/repo" push --quiet origin "HEAD:$repair_branch"

    gh pr ready "$repair_pr" --repo "$EXPECTED_REPO" >/dev/null
    merge_pr "$repair_pr"
    wait_for_pr_state "$stalled_pr" MERGED
    record_repair_prs "$stalled_pr"
    wait_for_comment "$origin_pr" "Resuming interrupted cascade from PR #${stalled_pr}"
    wait_for_comment "$origin_pr" "Auto-merge was successful."
    for ((index = 1; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        cascade_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$origin_pr")
        record_pr "Cascade hop $((index + 1))" "$cascade_pr"
        wait_for_pr_state "$cascade_pr" MERGED
    done
    assert_branch_contains_marker "$REF_BRANCH" "$resolved_value"
    delete_patch_branch

    log "PASS conflict: originating PR #${origin_pr}, repaired by #${repair_pr}, resumed from #${stalled_pr} through ${REF_BRANCH}"
    finish_scenario PASS "Originating PR #${origin_pr} resumed from stalled PR #${stalled_pr} after repair PR #${repair_pr} and reached ${REF_BRANCH}."
}

run_existing_pr() {
    local value collision_url collision_pr origin_pr collision_state index cascade_pr
    value="existing-pr-$(date -u '+%Y%m%d%H%M%S')"

    begin_scenario existing-pr "Existing pull request collision"
    log "Scenario: existing cascade PR collision"
    prepare_scenario

    collision_url=$(gh pr create \
        --repo "$EXPECTED_REPO" \
        --head "${EXPECTED_SOURCES[0]}" \
        --base "${EXPECTED_TARGETS[0]}" \
        --title "JIRA-9003: Existing release promotion PR" \
        --body "Pre-existing real PR used by the cascading smoke test.")
    collision_pr=$(gh pr view "$collision_url" --repo "$EXPECTED_REPO" --json number --jq .number)
    record_pr "Pre-existing collision" "$collision_pr"

    origin_pr=$(create_patch_pr "$value" existing-pr)
    current_origin_pr="$origin_pr"
    record_pr "Originating" "$origin_pr"
    current_stalled_pr="$collision_pr"
    merge_pr "$origin_pr"
    wait_for_comment "$origin_pr" "there is already a pull request open."
    wait_for_comment "$origin_pr" "Auto-merge action did not complete successfully."

    collision_state=$(gh pr view "$collision_pr" --repo "$EXPECTED_REPO" --json state --jq .state)
    [[ "$collision_state" == "OPEN" ]] || fail "Expected collision PR #${collision_pr} to remain open"
    assert_no_downstream_pr "$origin_pr"

    gh pr view "$collision_pr" --repo "$EXPECTED_REPO" --json body --jq .body | grep -Fq '<!-- cascading-merge-app:' ||
        fail "Collision PR #${collision_pr} does not contain resume metadata"

    merge_pr "$collision_pr"
    wait_for_comment "$origin_pr" "Resuming interrupted cascade from PR #${collision_pr}"
    wait_for_comment "$origin_pr" "Auto-merge was successful."
    for ((index = 1; index < ${#EXPECTED_SOURCES[@]}; index++)); do
        cascade_pr=$(wait_for_cascade_pr "${EXPECTED_SOURCES[index]}" "${EXPECTED_TARGETS[index]}" "$origin_pr")
        record_pr "Cascade hop $((index + 1))" "$cascade_pr"
        wait_for_pr_state "$cascade_pr" MERGED
    done
    assert_branch_contains_marker "$REF_BRANCH" "$value"
    delete_patch_branch

    log "PASS existing-pr: originating PR #${origin_pr}, resumed from pre-existing PR #${collision_pr} through ${REF_BRANCH}"
    finish_scenario PASS "Originating PR #${origin_pr} resumed through pre-existing PR #${collision_pr} and reached ${REF_BRANCH}."
}

main() {
    parse_args "$@"
    preflight

    confirm_destructive_run
    initialize_report

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