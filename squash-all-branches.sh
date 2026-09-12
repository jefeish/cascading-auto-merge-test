#!/bin/bash
# Squash All Branches Script
#
# Purpose: Squashes EVERY branch in the repository to a single commit,
#          preserving all current files on each branch.
#
# Use Case: When you want to clean up commit history across ALL branches
#           while keeping all current files exactly as they are.
#
# Difference from reset-repository.sh:
#   - reset-repository.sh: Creates specific structure with unique files per branch
#   - squash-all-branches.sh: Just squashes whatever exists on each branch now
#
# ⚠️  WARNING: This rewrites Git history on ALL branches!
#     - Requires force push for every branch
#     - Temporarily disable branch protection on main before running
#     - All commit history will be lost, replaced by single commits
#
# Usage: ./squash-all-branches.sh

set -e  # Exit immediately if any command fails

branches=(
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

echo "🔄 Squash All Branches Script"
echo "=========================================================="
echo ""
echo "This script will squash ALL ${#branches[@]} branches to single commits."
echo ""
echo "What happens to each branch:"
echo "  1. All commits collapsed into ONE commit"
echo "  2. All current files preserved exactly as they are (including branches.png)"
echo "  3. Commit message: 'Initial commit for [branch-name]'"
echo "  4. Force pushed to remote"
echo ""
echo "Before: Multiple commits per branch"
echo "After:  1 commit per branch (files unchanged)"
echo ""
echo "⚠️  WARNING: This rewrites Git history on ALL branches!"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=========================================================="
echo "Processing ${#branches[@]} branches..."
echo "=========================================================="
echo ""

# Process each branch
for branch in "${branches[@]}"; do
    echo "📌 Processing: $branch"
    echo "-----------------------------------"
    
    # Checkout the branch
    echo "  Step 1: Checking out $branch..."
    git checkout "$branch" 2>/dev/null || {
        echo "  ⚠️  Branch $branch does not exist locally, skipping..."
        echo ""
        continue
    }
    
    # Create orphan branch (no history)
    echo "  Step 2: Creating new orphan branch..."
    temp_branch="${branch//\//-}-temp"
    git checkout --orphan "$temp_branch"
    
    # Stage all current files
    echo "  Step 3: Staging all files..."
    git add -A
    
    # Create single commit
    echo "  Step 4: Creating single commit..."
    git commit -m "Initial commit for $branch"
    
    # Delete old branch
    echo "  Step 5: Replacing old branch..."
    git branch -D "$branch"
    
    # Rename temp branch to original name
    git branch -m "$temp_branch" "$branch"
    
    # Force push to remote
    echo "  Step 6: Force pushing to remote..."
    git push -f origin "$branch"
    
    echo "  ✅ $branch squashed successfully!"
    echo ""
done

# Return to main
echo "Returning to main branch..."
git checkout main

echo ""
echo "=========================================================="
echo "🎉 ALL BRANCHES SQUASHED!"
echo "=========================================================="
echo ""
echo "Summary:"
echo "  - Branches processed: ${#branches[@]}"
echo "  - Commits per branch: 1 (was many)"
echo "  - Files: Preserved exactly as they were"
echo ""
echo "All branches now have clean, single-commit history."
echo ""
echo "Verify with: git log --oneline --all --graph"
echo ""
echo "💡 Remember to re-enable branch protection on main if needed!"
