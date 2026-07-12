#!/bin/bash

# Get current branch name
BRANCH_NAME=$(git branch --show-current)

if [ -z "$BRANCH_NAME" ]; then
  echo "Error: Could not determine the current branch."
  exit 1
fi

if [ "$BRANCH_NAME" = "main" ]; then
  echo "Error: Refusing to create a PR from main."
  exit 1
fi

# Push the current branch to origin and set upstream
echo "Pushing branch to origin: $BRANCH_NAME"
git push -u origin "$BRANCH_NAME" || exit 1

# Create the pull request using the commit history and branch details
echo "Creating pull request..."
gh pr create -f

# Open the created pull request in the default browser
echo "Opening pull request in browser..."
gh pr view --json url --jq .url | xargs open
