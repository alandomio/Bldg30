#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_version="$(cat VERSION)"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid version: %s\n' "$app_version" >&2; exit 1
fi
if ! rg --fixed-strings --quiet "public static let current = \"$app_version\"" Sources/ModelDeckCore/Models.swift || ! rg --fixed-strings --quiet "MARKETING_VERSION: $app_version" project.yml; then
  printf 'VERSION, DeckVersion and project.yml must agree.\n' >&2; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  printf 'Commit all changes before tagging a release.\n' >&2; exit 1
fi
release_tag="v$app_version"
if git show-ref --verify --quiet "refs/tags/$release_tag"; then
  printf 'Tag already exists: %s. Existing tags are never moved.\n' "$release_tag" >&2; exit 1
fi
git tag -a "$release_tag" -m "ModelDeck $app_version" -m "Release notes: CHANGELOG.md"
printf 'Created annotated tag %s at %s\n' "$release_tag" "$(git rev-parse --short HEAD)"
