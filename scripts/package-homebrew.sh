#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_NAME="comux"
APP_FILENAME="${APP_NAME}.app"
CASK_TOKEN="comux"

VERSION=""
BUILD_NUMBER=""
REPOSITORY=""
HOMEPAGE=""

usage() {
    cat <<'EOF'
Usage: scripts/package-homebrew.sh --version <version> [options]

Options:
  --build-number <value>  CFBundleVersion value. Defaults to the version string.
  --repo <owner/name>     GitHub repository that hosts release archives.
  --homepage <url>        Homepage for the generated cask. Defaults to the repo URL.

Environment fallbacks:
  GITHUB_REPOSITORY, GITHUB_SERVER_URL, COMUX_VERSION, COMUX_BUILD_NUMBER
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
        --repo)
            REPOSITORY="${2:-}"
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
    VERSION="${COMUX_VERSION:-}"
fi

if [[ -z "$VERSION" ]]; then
    echo "--version is required" >&2
    exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="${COMUX_BUILD_NUMBER:-$VERSION}"
fi

if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY="${GITHUB_REPOSITORY:-}"
fi

if [[ -z "$REPOSITORY" ]]; then
    origin_url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        REPOSITORY="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
fi

if [[ -z "$REPOSITORY" ]]; then
    echo "Unable to determine GitHub repository. Pass --repo owner/name." >&2
    exit 1
fi

server_url="${GITHUB_SERVER_URL:-https://github.com}"

if [[ -z "$HOMEPAGE" ]]; then
    HOMEPAGE="${server_url}/${REPOSITORY}"
fi

archive_name="${APP_NAME}-${VERSION}.zip"
archive_path="${DIST_DIR}/${archive_name}"
cask_path="${DIST_DIR}/${CASK_TOKEN}.rb"
download_url="${server_url}/${REPOSITORY}/releases/download/v${VERSION}/${archive_name}"

mkdir -p "$DIST_DIR"

COMUX_VERSION="$VERSION" \
COMUX_BUILD_NUMBER="$BUILD_NUMBER" \
"$ROOT_DIR/scripts/build-app.sh" >/dev/null

rm -f "$archive_path"
ditto -c -k --keepParent "$ROOT_DIR/.build/apple/${APP_FILENAME}" "$archive_path"

sha256_value="$(shasum -a 256 "$archive_path" | awk '{print $1}')"

cat > "$cask_path" <<EOF
cask "${CASK_TOKEN}" do
  version "${VERSION}"
  sha256 "${sha256_value}"

  url "${download_url}"
  name "${APP_NAME}"
  desc "macOS menu bar app to track and sort Codex account limits"
  homepage "${HOMEPAGE}"
  depends_on macos: ">= :sonoma"

  app "${APP_FILENAME}"

  zap trash: [
    "~/.comux",
  ]
end
EOF

printf 'archive=%s\n' "$archive_path"
printf 'sha256=%s\n' "$sha256_value"
printf 'cask=%s\n' "$cask_path"
