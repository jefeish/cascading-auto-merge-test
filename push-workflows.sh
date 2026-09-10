#!/bin/bash
set -e

branches=(
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

echo "📂 Pushing workflows from main to all branches..."
echo "=================================================="

# Make sure we're on main
git checkout main

# Configure merge strategy
git config pull.rebase false

echo ""
echo "Pushing workflows to branches..."
echo ""

# Push to each branch
for branch in "${branches[@]}"; do
    echo "Processing branch: $branch"
    
    # Checkout the branch and reset to remote
    git checkout "$branch"
    git reset --hard "origin/$branch"
    
    # Checkout workflow files from main
    git checkout main -- .github/workflows/ 2>/dev/null || mkdir -p .github/workflows
    
    # Check if .github/workflows directory exists in main
    if git ls-tree main -- .github/workflows/ | grep -q .; then
        git checkout main -- .github/workflows/
    fi
    
    # Add and commit if there are changes
    if git diff --quiet HEAD .github/workflows/ 2>/dev/null; then
        echo "  ℹ️  Workflows already up-to-date on $branch"
    else
        git add .github/workflows/
        git commit -m "Add workflows from main"
        git push -f origin "$branch"
        echo "  ✅ Workflows added to $branch"
    fi
    
    echo ""
done

# Return to main
git checkout main

echo "=================================================="
echo "✨ Workflows pushed to all branches!"
