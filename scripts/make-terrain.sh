#!/usr/bin/env bash
# One-time generator for terrain/: clones dynnamitt/apicult-desigual-rs at a
# commit, runs its hex-chunks CLI and writes terrain/manifest.json,
# terrain/chunk_<q>_<r>.bin and terrain/SOURCE. Run it again only to change the
# world, then commit the result. CI never runs this.
#
#   scripts/make-terrain.sh [apicult-commit] [hex-chunks args…]
#   scripts/make-terrain.sh e59947bac9356b6cdf706fdb4c9c933083677b0d --radius 30 --chunk-radius 6
#
# Needs git and cargo. The chunk format is documented in apicult's
# src/chunk.rs; the reader is src/core/Chunk.zig.
set -euo pipefail

repo_url=https://github.com/dynnamitt/apicult-desigual-rs
default_commit=e59947bac9356b6cdf706fdb4c9c933083677b0d # adds hex-chunks (apicult PR #18)
default_args=(--radius 30 --chunk-radius 6)

# A first argument that starts with '-' is a hex-chunks flag, not a commit.
commit=$default_commit
if [ $# -gt 0 ] && [ -n "$1" ] && [ "${1#-}" = "$1" ]; then
	commit=$1
	shift
fi
args=("$@")
if [ ${#args[@]} -eq 0 ]; then args=("${default_args[@]}"); fi

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/terrain
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git init -q "$work/src"
git -C "$work/src" fetch -q --depth 1 "$repo_url" "$commit"
git -C "$work/src" checkout -q FETCH_HEAD
full_commit=$(git -C "$work/src" rev-parse HEAD)

(cd "$work/src" && cargo build -q --release --bin hex-chunks)

# Generate into the temp dir first, so a failed run leaves terrain/ as it was.
"$work/src/target/release/hex-chunks" --out "$work/out" "${args[@]}"
rm -rf "$out"
mv "$work/out" "$out"

# apicult doesn't commit Cargo.lock, so record what this run resolved: noise
# or hexx updates could change the output for the same commit and arguments.
{
	echo "repo: $repo_url"
	echo "commit: $full_commit"
	echo "args: ${args[*]}"
	echo "rustc: $(rustc --version)"
	echo "crates:"
	sed -n '/^name = "\(glam\|hexx\|noise\)"$/{N;s/name = "\(.*\)"\nversion = "\(.*\)"/  \1 \2/p}' "$work/src/Cargo.lock"
} >"$out/SOURCE"

echo "terrain/ written from $full_commit ($(du -sh "$out" | cut -f1))"
