#!/bin/bash

# Check if issue number is provided
ISSUE_NUMBER=$1
if [ -z "$ISSUE_NUMBER" ]; then
  echo "Error: Issue number is required."
  exit 1
fi

REPO_URL=$(git remote get-url origin 2>/dev/null)
REPO=$(echo "$REPO_URL" | sed -E 's#(git@github.com:|https://github.com/)##' | sed -E 's#\.git$##')

if [ -z "$REPO" ]; then
  echo "Error: Could not determine GitHub repository from origin remote."
  exit 1
fi

# Get the issue title using GitHub CLI
TITLE=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title --jq .title 2>/dev/null)

if [ -z "$TITLE" ]; then
  echo "Error: Could not find title for issue #$ISSUE_NUMBER. Make sure you are logged in to 'gh' and have access to the repository."
  exit 1
fi

# Slugify the title: lowercase, replace non-alphanumeric with hyphens, remove duplicate/leading/trailing hyphens
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
BRANCH_NAME="${ISSUE_NUMBER}-${SLUG}"

# Create and checkout the branch
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  git checkout "$BRANCH_NAME"
  echo "Switched to existing branch: $BRANCH_NAME"
else
  git checkout -b "$BRANCH_NAME"
  echo "Created and checked out branch: $BRANCH_NAME"
fi

# Fetch and rebase onto main
echo "Fetching latest main and rebasing..."
git fetch origin main
git rebase origin/main
