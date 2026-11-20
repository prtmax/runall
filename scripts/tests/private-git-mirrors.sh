#!/usr/bin/env bash
# Exercise prepare and compile with real repositories and file transport only.
set -euo pipefail
RUNALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$RUNALL_ROOT/scripts/lib/common.sh"
source "$RUNALL_ROOT/scripts/lib/build_release.sh"
spec="$1"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
workspace="$scratch/source workspace"
upstream="$scratch/upstream"
export GIT_CONFIG_GLOBAL="$scratch/prepare.gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.test
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

git init -q -b main "$upstream"
git -C "$upstream" commit -q --allow-empty -m base
locked="$(git -C "$upstream" rev-parse HEAD)"
git -C "$upstream" tag pinned
git -C "$upstream" commit -q --allow-empty -m latest
git -C "$upstream" checkout -qb secondary
git -C "$upstream" commit -q --allow-empty -m secondary
secondary="$(git -C "$upstream" rev-parse HEAD)"
base=https://github.com/prtmax
repos=(image_mirror overrides_only lock_only)
for repo in "${repos[@]}"; do
  git config --global --add "url.file://$upstream.insteadOf" "$base/$repo.git"
done

git init -q -b main "$workspace"
git -C "$workspace" remote add origin "$base/orion.git"
member="$workspace/packages/core/utils"
mkdir -p "$member" "$workspace/tools/rigel_build/bin"
touch "$workspace/tools/rigel_build/bin/assemble.dart"
printf 'name: root\nworkspace: [packages/core/utils]\n' > "$workspace/pubspec.yaml"
printf 'name: utils\ndependencies:\n  image_mirror:\n    git: %s/image_mirror.git\n' "$base" > "$member/pubspec.yaml"
printf 'dependency_overrides:\n  fix:\n    git: %s/overrides_only\n' "$base" > "$member/pubspec_overrides.yaml"
cat > "$workspace/pubspec.lock" <<LOCK
packages:
  image_mirror:
    description:
      resolved-ref: "$locked"
      url: "$base/image_mirror"
    source: git
  lock_only:
    description:
      url: "$base/lock_only.git"
    source: git
LOCK
for dir in "$workspace/.git" "$member/build" "$workspace/.dart_tool"; do
  mkdir -p "$dir"
  printf 'git: %s/ignored.git\n' "$base" > "$dir/pubspec.yaml"
done
git -C "$workspace" add .
git -C "$workspace" commit -qm source
COSMOS_BUILD_REPOSITORY_TOKEN=test-only-token "$RUNALL_ROOT/scripts/checkout-source" \
  --spec "$spec" --workspace "$workspace" --resolved-sha "$(git -C "$workspace" rev-parse HEAD)"

# Compile gets an extracted workspace at a different path and a fresh Git config.
mkdir "$scratch/compile"
tar -C "$workspace" -cf - . | tar -C "$scratch/compile" -xf -
rm -rf "$upstream" "$workspace"
workspace="$scratch/compile"
export GIT_CONFIG_GLOBAL="$scratch/compile.gitconfig"
unset GIT_ALLOW_PROTOCOL
git config --global protocol.allow never
export RUNALL_FLUTTER="$scratch/flutter" RUNALL_DART=/bin/true
printf '#!/bin/sh\necho Flutter %s\n' "$(jq -r .buildInput.source.flutterVersion "$spec")" > "$RUNALL_FLUTTER"
chmod +x "$RUNALL_FLUTTER"
prepare_frozen_workspace "$spec" "$workspace"
prepare_frozen_workspace "$spec" "$workspace"
for repo in "${repos[@]}"; do
  mirror="$workspace/.git/runall-mirrors/$repo.git"
  [[ "$(git -C "$mirror" rev-parse --is-bare-repository)" == true ]]
  [[ "$(git -C "$mirror" config --local remote.origin.url)" == "$base/$repo.git" ]]
  if grep -Eiq 'authorization|extraheader|test-only-token' "$mirror/config"; then exit 1; fi
  [[ "$(git config --global --get-all "url.file://$mirror.insteadOf")" == "$(printf '%s\n' "$base/$repo.git" "$base/$repo")" ]]
  for suffix in .git ''; do
    dest="$scratch/$repo$suffix"
    git clone -q --mirror "$base/$repo$suffix" "$dest"
    [[ "$(git -C "$dest" rev-parse refs/heads/secondary)" == "$secondary" ]]
    [[ "$(git -C "$dest" rev-parse refs/tags/pinned)" == "$locked" ]]
    git -C "$dest" cat-file -e "$locked^{commit}"
  done
done
