#!/bin/bash

# Master Reset Script for cascading-auto-merge-test repository
#
# Purpose: Resets the entire repository to a clean, pristine state for testing
#
# What this script does:
#   1. Deletes all unwanted branches (local and remote)
#   2. Squashes main branch to a single commit
#   3. Resets all other branches to clean state (2 commits each)
#   4. Ensures each branch has a unique file to prevent merge conflicts
#   5. Verifies workflow files match main on every branch
#
# End State (Clean Starting Point for Testing):
#   - Main branch: 1 commit with ALL files (README, LICENSE, .gitignore, workflows, branches.png, etc.)
#   - Each other branch: 2 commits
#       * Commit 1: Initial commit (inherited from main, includes ALL files)
#       * Commit 2: Branch-specific commit with ONE additional unique file
#
# Unique files per branch (for testing, prevents merge conflicts):
#   - development.txt          (on development branch)
#   - release-0.1.txt          (on release/0.1 branch)
#   - release-1.1-rc.1.txt     (on release/1.1-rc.1 branch)
#   - release-1.1.txt          (on release/1.1 branch)
#   - release-1.2.txt          (on release/1.2 branch)
#   - release-2.0.txt          (on release/2.0 branch)
#   - release-2.0.1-alpha.txt  (on release/2.0.1-alpha branch)
#   - release-2.0.1-beta.txt   (on release/2.0.1-beta branch)
#   - release-2.0.1-beta.1.txt (on release/2.0.1-beta.1 branch)
#   - release-2025-12-31.txt   (on release/2025-12-31 branch)
#   - release-2025-12-31-01.txt (on release/2025-12-31-01 branch)
#   - release-2025-12-31-02.txt (on release/2025-12-31-02 branch)
#   - release-2026-01-20.txt    (on release/2026-01-20 branch)
#   - release-2026-01-20-01.txt (on release/2026-01-20-01 branch)
#   - release-2026-03-12-02.txt (on release/2026-03-12-02 branch)
#
# ⚠️  WARNING: This rewrites Git history and requires force push!
#     Temporarily disable branch protection on main before running.
#
# Usage: ./reset-repository.sh

set -e  # Exit on error

WORKFLOW_DIR=".github/workflows"

get_workflow_tree_hash_for_ref() {
    local ref="$1"
    git rev-parse "$ref:$WORKFLOW_DIR" 2>/dev/null || true
}

verify_workflows_match_main() {
    local branch="$1"
    local main_hash branch_hash

    main_hash=$(get_workflow_tree_hash_for_ref "main")
    branch_hash=$(get_workflow_tree_hash_for_ref "HEAD")

    if [[ -z "$main_hash" && -z "$branch_hash" ]]; then
        echo "  ✅ Workflow check passed for $branch (no $WORKFLOW_DIR in main or branch)"
        return 0
    fi

    if [[ "$main_hash" != "$branch_hash" ]]; then
        echo "  ❌ Workflow mismatch detected on $branch"
        echo "     main hash:   ${main_hash:-<missing>}"
        echo "     branch hash: ${branch_hash:-<missing>}"
        echo "     Changed workflow files versus main:"
        git diff --name-status main...HEAD -- "$WORKFLOW_DIR" || true
        return 1
    fi

    echo "  ✅ Workflow check passed for $branch"
}

# Define all desired branches
desired_branches=(
    "main"
    "development"
    "release/0.1"
    "release/1.1-rc.1"
    "release/1.1"
    "release/1.2"
    "release/2.0"
    "release/2.0.1-alpha"
    "release/2.0.1-beta"
    "release/2.0.1-beta.1"
    "release/2025-12-31" 
    "release/2025-12-31-01" 
    "release/2025-12-31-02"
    "release/2026-01-20"
    "release/2026-01-20-01"
    "release/2026-03-12-02"
)

echo "🚀 Repository Reset Script for cascading-auto-merge-test"
echo "=========================================================="
echo ""
echo "This script will create a CLEAN STARTING POINT FOR TESTING:"
echo ""
echo "What it does:"
echo "  1. Delete all unwanted branches (local and remote)"
echo "  2. Squash main branch to single commit"
echo "  3. Reset all other branches to clean state (2 commits each)"
echo "  4. Add ONE unique file to each branch (e.g., release-0.1.txt)"
echo "  5. Verify workflow files match main on each branch"
echo "  6. Force push everything to remote"
echo ""
echo "End result:"
echo "  - Main: 1 commit with ALL files (including branches.png)"
echo "  - All other branches: 2 commits each"
echo "      * Inherited initial commit from main"
echo "      * One branch-specific file (prevents merge conflicts)"
echo ""
echo "Example: release/0.1 branch will contain:"
echo "  - All files from main (README.md, LICENSE, .gitignore, branches.png, etc.)"
echo "  - PLUS release-0.1.txt (unique to this branch)"
echo ""
echo "⚠️  WARNING: This will rewrite Git history!"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=========================================================="
echo "STEP 1: Cleaning up branches"
echo "=========================================================="

# Switch to main to avoid being on a branch we're deleting
git checkout main

# Get all local branches except main
all_local_branches=$(git branch | grep -v "^\*" | grep -v "main" | sed 's/^[* ]*//')

# Delete local branches not in desired list
for branch in $all_local_branches; do
    if [[ ! " ${desired_branches[@]} " =~ " ${branch} " ]]; then
        echo "Deleting local branch: $branch"
        git branch -D "$branch" 2>/dev/null || echo "  ⚠️  Could not delete $branch"
    fi
done

# Get all remote branches except main
all_remote_branches=$(git branch -r | grep "origin/" | grep -v "origin/HEAD" | grep -v "origin/main" | sed 's/.*origin\///')

# Delete remote branches not in desired list
for branch in $all_remote_branches; do
    if [[ ! " ${desired_branches[@]} " =~ " ${branch} " ]]; then
        echo "Deleting remote branch: $branch"
        git push origin --delete "$branch" 2>/dev/null || echo "  ⚠️  Could not delete origin/$branch"
    fi
done

echo ""
echo "✅ Branch cleanup complete!"

echo ""
echo "=========================================================="
echo "STEP 2: Squashing main branch"
echo "=========================================================="

# Create a new orphan branch (no history)
git checkout --orphan main-new

# Add all current files
git add -A

# Commit everything as one initial commit
git commit -m "Initial commit"

# Delete the old main branch
git branch -D main

# Rename the new branch to main
git branch -m main

# Force push to remote
echo "Force pushing squashed main to remote..."
git push -f origin main

echo ""
echo "✅ Main branch squashed to single commit!"

echo ""
echo "=========================================================="
echo "STEP 3: Resetting all other branches"
echo "=========================================================="

# Get the initial commit
INITIAL_COMMIT=$(git rev-list --max-parents=0 HEAD)
echo "Initial commit: $INITIAL_COMMIT"
echo ""

# Reset each branch to have only one clean commit
for branch in "${desired_branches[@]}"; do
    if [ "$branch" == "main" ]; then
        continue
    fi
    
    echo "Processing branch: $branch"
    
    # Check if branch exists locally
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch"
    else
        # Create from initial commit
        git checkout -b "$branch" "$INITIAL_COMMIT"
    fi
    
    # Hard reset to initial commit
    git reset --hard "$INITIAL_COMMIT"
    
    # Clean any untracked files
    git clean -fd
    
    # Create unique file for this branch
    filename="${branch//\//-}.txt"
    echo "This file belongs to branch: $branch" > "$filename"
    echo "Created at: $(date)" >> "$filename"
    echo "Purpose: Testing cascading auto-merge functionality" >> "$filename"
    
    # Add and commit
    git add "$filename"
    git commit -m "Initialize $branch with unique file"

    # Validate workflows still match main exactly.
    verify_workflows_match_main "$branch"
    
    # Force push to remote
    git push -f origin "$branch"
    
    echo "  ✅ Reset complete for $branch"
    echo ""
done

echo "Running final workflow parity verification across all non-main branches..."
for branch in "${desired_branches[@]}"; do
    if [ "$branch" == "main" ]; then
        continue
    fi

    git checkout "$branch"
    verify_workflows_match_main "$branch"
done

# Return to main
git checkout main

echo ""
echo "=========================================================="
echo "🎉 COMPLETE! Repository fully reset."
echo "=========================================================="
echo ""
echo "✅ CLEAN STARTING POINT FOR TESTING"
echo ""
echo "Main branch (1 commit):"
echo "  - ALL current files: README, LICENSE, .gitignore, workflows, branches.png, etc."
echo ""
echo "All other branches (2 commits each):"
echo "  - Commit 1: Initial commit (inherited from main)"
echo "  - Commit 2: Single unique file named after the branch"
echo ""
echo "Example:"
echo "  - development branch has → development.txt"
echo "  - release/0.1 branch has → release-0.1.txt"
echo "  - release/1.1 branch has → release-1.1.txt"
echo "  ...and so on for all ${#desired_branches[@]} branches"
echo ""
echo "Why unique files?"
echo "  Each branch has ONE unique file to prevent merge conflicts"
echo "  during cascading merge testing."
echo ""
echo "Available branches:"
for branch in "${desired_branches[@]}"; do
    if [ "$branch" == "main" ]; then
        echo "  ✓ $branch (base branch)"
    else
        filename="${branch//\//-}.txt"
        echo "  ✓ $branch → contains $filename"
    fi
done
echo ""
echo "🧪 Repository is ready for cascading merge testing!"
echo ""
echo "⚠️  Remember to re-enable branch protection on main if needed!"
