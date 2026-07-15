#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

COMMIT_MSG="${1:-update RuSwitcher}"
BRANCH="$(git branch --show-current)"

if [ -z "$BRANCH" ]; then
    echo "ERROR: could not detect current git branch."
    exit 1
fi

./build_app.sh

if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "$COMMIT_MSG"
    git push origin "$BRANCH"
else
    echo "No git changes to commit."
fi

open "RuSwitcher.app"
