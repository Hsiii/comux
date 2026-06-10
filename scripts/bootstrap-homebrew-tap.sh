#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="comux"
CASK_TOKEN="comux"

VERSION=""
BUILD_NUMBER=""
SOURCE_REPOSITORY=""
TAP_REPOSITORY=""
OUTPUT_DIR=""
HOMEPAGE=""

usage() {
    cat <<'EOF'
Usage: scripts/bootstrap-homebrew-tap.sh --version <version> --source-repo <owner/name> [options]

Options:
  --build-number <value>  CFBundleVersion value. Defaults to the version string.
  --source-repo <owner/name>
                          GitHub repository that hosts comux releases.
  --tap-repo <owner/name> GitHub repository name for the tap. Defaults to <owner>/homebrew-tap.
  --output <path>         Directory to create or update. Defaults to ../<tap repo name>.
  --homepage <url>        Homepage for the generated cask. Defaults to the source repo URL.

This creates a standalone Homebrew tap scaffold with:
  README.md
  Casks/comux.rb
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --build-number)
            BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --source-repo)
            SOURCE_REPOSITORY="${2:-}"
            shift 2
            ;;
        --tap-repo)
            TAP_REPOSITORY="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --homepage)
            HOMEPAGE="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "--version is required" >&2
    exit 1
fi

if [[ -z "$SOURCE_REPOSITORY" ]]; then
    origin_url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        SOURCE_REPOSITORY="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
fi

if [[ -z "$SOURCE_REPOSITORY" ]]; then
    echo "--source-repo is required" >&2
    exit 1
fi

owner="${SOURCE_REPOSITORY%%/*}"

if [[ -z "$TAP_REPOSITORY" ]]; then
    TAP_REPOSITORY="${owner}/homebrew-tap"
fi

tap_repo_name="${TAP_REPOSITORY#*/}"
tap_short_name="${tap_repo_name#homebrew-}"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$ROOT_DIR/../${tap_repo_name}"
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$VERSION"
fi

if [[ -z "$HOMEPAGE" ]]; then
    HOMEPAGE="https://github.com/${SOURCE_REPOSITORY}"
fi

archive_path=""
cask_path=""
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

"$ROOT_DIR/scripts/package-homebrew.sh" \
    --version "$VERSION" \
    --build-number "$BUILD_NUMBER" \
    --repo "$SOURCE_REPOSITORY" \
    --homepage "$HOMEPAGE" | tee "$output_file"

while IFS= read -r line; do
    case "$line" in
        archive=*)
            archive_path="${line#archive=}"
            ;;
        cask=*)
            cask_path="${line#cask=}"
            ;;
    esac
done < "$output_file"

if [[ -z "$archive_path" || -z "$cask_path" ]]; then
    echo "Failed to generate release archive or cask." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR/Casks"
cp "$cask_path" "$OUTPUT_DIR/Casks/${CASK_TOKEN}.rb"

cat > "$OUTPUT_DIR/README.md" <<EOF
# ${tap_repo_name}

Homebrew tap for [${APP_NAME}](${HOMEPAGE}).

## Install

\`\`\`bash
brew install --cask ${owner}/${tap_short_name}/${CASK_TOKEN}
\`\`\`

## Update

This tap is intended to track GitHub release assets published from:

- Source repo: \`${SOURCE_REPOSITORY}\`
- Release archive: \`$(basename "$archive_path")\`

The cask lives at [Casks/${CASK_TOKEN}.rb](./Casks/${CASK_TOKEN}.rb).
EOF

printf 'tap_dir=%s\n' "$OUTPUT_DIR"
printf 'tap_repo=%s\n' "$TAP_REPOSITORY"
printf 'cask=%s\n' "$OUTPUT_DIR/Casks/${CASK_TOKEN}.rb"
