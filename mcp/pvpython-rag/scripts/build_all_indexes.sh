#!/usr/bin/env bash
#
# build_all_indexes.sh
#
# Builds a FAISS index + metadata sidecar for every eligible git tag of
# the vendored ParaView checkout (data/paraview-code), extracting
# functions from Wrapping/Python/paraview at that tag.
#
# For each tag:
#   - Skips tags that don't contain Wrapping/Python/paraview (older
#     ParaView releases predate this module layout) — warns and
#     continues.
#   - Skips release-candidate (-RCn), -dev, and -final suffixed tags,
#     as well as the unrelated SALOME_77_EDF_2015_v1 tag.
#   - Skips tags whose output already exists in data/vector-db/ (set
#     FORCE=1 to rebuild anyway).
#   - Checks out the tag into an isolated git worktree (leaving the
#     shared clone's working directory untouched), runs
#     pvpython_rag.main against it, then removes the worktree.
#   - On failure, logs the tag and continues with the remaining tags
#     instead of aborting the whole run.
#
# A summary of built / skipped / failed tags is printed at the end.
# Exit status is non-zero if any tag failed to build.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PARAVIEW_REPO="$PROJECT_DIR/data/paraview-code"
OUTPUT_DIR="$PROJECT_DIR/data/vector-db"
TARGET_PATH="Wrapping/Python/paraview"

# Tags that should never be built, regardless of the RC/dev/final filter.
EXCLUDED_TAGS_PATTERN='^SALOME_77_EDF_2015_v1|LANL$'

# Suffix patterns to exclude (release candidates, dev snapshots, "final"
# tags that duplicate a same-named release tag).
EXCLUDED_SUFFIX_PATTERN='-RC[0-9]+$|-dev$|-final$'

if [[ ! -d "$PARAVIEW_REPO/.git" ]]; then
    echo "Error: $PARAVIEW_REPO is not a git repository." \
        "Run 'make clone-paraview' first." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

built=()
skipped_missing_path=()
skipped_filtered=()
skipped_existing=()
failed=()

while IFS= read -r tag; do
    echo tag
    [[ -z "$tag" ]] && continue

    if [[ "$tag" =~ $EXCLUDED_TAGS_PATTERN ]]; then
        skipped_filtered+=("$tag")
        continue
    fi

    if [[ "$tag" =~ $EXCLUDED_SUFFIX_PATTERN ]]; then
        skipped_filtered+=("$tag")
        continue
    fi

    if ! git -C "$PARAVIEW_REPO" cat-file -e "$tag:$TARGET_PATH" 2>/dev/null; then
        echo "Warning: skipping $tag ($TARGET_PATH not found at this tag)" >&2
        skipped_missing_path+=("$tag")
        continue
    fi

    index_file="$OUTPUT_DIR/index_${tag}.faiss"
    metadata_file="$OUTPUT_DIR/metadata_${tag}.json"

    if [[ -f "$index_file" && -f "$metadata_file" && "${FORCE:-0}" != "1" ]]; then
        echo "Skipping $tag (already built; set FORCE=1 to rebuild)"
        skipped_existing+=("$tag")
        continue
    fi

    worktree_dir="$(mktemp -d)"
    echo "Building index for $tag ..."

    if ! git -C "$PARAVIEW_REPO" worktree add --detach --force \
        "$worktree_dir" "$tag" >/dev/null 2>&1; then
        echo "Error: failed to create worktree for $tag" >&2
        failed+=("$tag")
        rm -rf "$worktree_dir"
        continue
    fi

    if python -m pvpython_rag.main \
        --input-dir "$worktree_dir/$TARGET_PATH" \
        --output-dir "$OUTPUT_DIR" \
        --tag "$tag"; then
        built+=("$tag")
    else
        echo "Error: failed to build index for $tag" >&2
        failed+=("$tag")
    fi

    git -C "$PARAVIEW_REPO" worktree remove --force "$worktree_dir" \
        >/dev/null 2>&1
    rm -rf "$worktree_dir"
done < <(git -C "$PARAVIEW_REPO" tag --format='%(refname:short)' --column=never | sort -V)

echo
echo "===== Summary ====="
echo "Built:                  ${#built[@]}"
echo "Skipped (already built): ${#skipped_existing[@]}"
echo "Skipped (filtered):      ${#skipped_filtered[@]}"
echo "Skipped (missing path):  ${#skipped_missing_path[@]}"
echo "Failed:                  ${#failed[@]}"

if [[ ${#failed[@]} -gt 0 ]]; then
    echo
    echo "Failed tags:"
    printf '  - %s\n' "${failed[@]}"
    exit 1
fi
