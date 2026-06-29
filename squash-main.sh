#!/bin/bash
# Squash Main Branch Script
# 
# Purpose: Collapses all commits on the main branch into a single "Initial commit"
#          while preserving all current files and their content.
#
# Use Case: Clean up commit history on main branch for testing purposes
#
# ⚠️  WARNING: This rewrites Git history and requires force push
#     Make sure branch protection is temporarily disabled before running!
#
# Usage: ./squash-main.sh

set -e  # Exit immediately if any command fails

echo "🔄 Squashing all commits on main branch..."
echo "==========================================="
echo ""
echo "This script will:"
echo "  1. Create a new branch with no history (orphan branch)"
echo "  2. Commit all current files as a single 'Initial commit'"
echo "  3. Replace the old main branch with the new one"
echo "  4. Force push to remote"
echo ""
echo "⚠️  This will rewrite Git history!"
echo ""

# Make sure we're on the main branch before starting
echo "Step 1: Switching to main branch..."
git checkout main

# Capture the current working directory state (all files will be preserved)
echo "Step 2: Saving current state of main branch..."
echo "           (All files and content will be preserved)"

# Create a new orphan branch (a branch with no parent commits, no history)
# This gives us a clean slate to build a single commit from
echo "Step 3: Creating new orphan branch (no history)..."
git checkout --orphan main-new

# Stage all files from the current working directory
echo "Step 4: Staging all files for commit..."
git add -A

# Create the single commit that will become the entire history
echo "Step 5: Creating single 'Initial commit'..."
git commit -m "Initial commit"

# Remove the old main branch (we're currently on main-new)
echo "Step 6: Deleting old main branch..."
git branch -D main

# Rename our new branch to 'main'
echo "Step 7: Renaming new branch to 'main'..."
git branch -m main

# Push to remote with force flag (overwrites remote history)
echo ""
echo "Step 8: Force pushing to remote..."
echo "           ⚠️  This overwrites the remote branch history!"
git push -f origin main

echo ""
echo "==========================================="
echo "✅ Main branch squashed to single commit!"
echo ""
echo "Before: Multiple commits with full history"
echo "After:  1 commit - 'Initial commit'"
echo ""
echo "💡 Remember to re-enable branch protection if it was disabled."
