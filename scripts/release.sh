#!/usr/bin/env bash
#
# release.sh — push committed work, bump the version, and cut a release.
#
# Usage (from Git Bash on Windows, or any bash):
#   ./scripts/release.sh            # bump patch  (1.9.3 -> 1.9.4)
#   ./scripts/release.sh patch      # same
#   ./scripts/release.sh minor      # 1.9.3 -> 1.10.0
#   ./scripts/release.sh major      # 1.9.3 -> 2.0.0
#   ./scripts/release.sh patch -y   # skip the confirmation prompt
#
# What it does:
#   1. Pushes the current branch (everything already committed goes up).
#   2. Bumps `version:` in pubspec.yaml (semver + build number) and commits it
#      as "chore(release): X.Y.Z".
#   3. Pushes that commit, then creates + pushes tag vX.Y.Z, which triggers
#      .github/workflows/release.yml (the `on: push: tags: v*` release build).
#
set -euo pipefail

BUMP="patch"
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    major|minor|patch) BUMP="$arg" ;;
    -y|--yes)          ASSUME_YES=1 ;;
    *) echo "Unknown arg: $arg (use major|minor|patch [-y])" >&2; exit 1 ;;
  esac
done

# Run from repo root regardless of where it's invoked.
cd "$(dirname "$0")/.."

# Guard: no uncommitted changes to *tracked* files (untracked scratch files are
# fine). The point of the script is to release what's committed, cleanly.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes to tracked files. Commit or stash first." >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# Read current version "X.Y.Z+B" from pubspec.yaml.
line="$(grep -m1 '^version:' pubspec.yaml)"
ver="${line#version:}"; ver="${ver// /}"
semver="${ver%%+*}"
build="${ver##*+}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$semver"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac
build=$((build + 1))

NEW="${MAJOR}.${MINOR}.${PATCH}"
NEW_FULL="${NEW}+${build}"
TAG="v${NEW}"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists — nothing to do." >&2
  exit 1
fi

echo "About to release:"
echo "  branch : $BRANCH"
echo "  version: $ver  ->  $NEW_FULL"
echo "  tag    : $TAG   (pushing this triggers the release build)"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# 1. Push whatever is already committed on this branch.
git push origin "$BRANCH"

# 2. Bump pubspec version + commit (portable in-place sed).
sed -i.bak "s/^version: .*/version: ${NEW_FULL}/" pubspec.yaml && rm -f pubspec.yaml.bak
git add pubspec.yaml
git commit -m "chore(release): ${NEW}"

# 3. Push the bump, then the tag (the tag is what fires CI).
git push origin "$BRANCH"
git tag "$TAG"
git push origin "$TAG"

echo
echo "Released ${NEW} (build ${build}) from ${BRANCH}."
echo "CI: https://github.com/RavinduRepo/OminiNote/actions"
