#!/usr/bin/env bash
# Download the plugin release binary and verify it against the published
# checksums before it ever lands in Vault's plugin directory.
#
# This mirrors what a customer does in production: pull the release, verify the
# checksum, drop it in the plugin dir, register it by the *binary's* SHA256.
# The archive's checksum is what _SHA256SUMS covers; the binary inside has a
# different hash, and that second one is what `vault plugin register` wants.

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_cmd curl
require_cmd unzip
require_cmd shasum

# Match the container's architecture, not the host's. Under Docker Desktop on
# Apple Silicon these agree (linux/arm64), but being explicit means this still
# works on an amd64 machine or a cross-arch daemon.
GOOS=linux
GOARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo arm64)"

ARCHIVE="${PLUGIN_NAME}_${PLUGIN_VERSION}_${GOOS}_${GOARCH}.zip"
SUMS="${PLUGIN_NAME}_${PLUGIN_VERSION}_SHA256SUMS"
BASE="https://github.com/ausmartway/${PLUGIN_NAME}/releases/download/v${PLUGIN_VERSION}"
CACHE="$REPO_ROOT/.plugin-cache"

mkdir -p "$CACHE" "$PLUGIN_DIR"

echo "==> Downloading ${ARCHIVE} (${GOOS}/${GOARCH})"
curl -fsSL -o "$CACHE/$ARCHIVE" "$BASE/$ARCHIVE"
curl -fsSL -o "$CACHE/$SUMS" "$BASE/$SUMS"

echo "==> Verifying archive checksum against $SUMS"
(
    cd "$CACHE"
    # Check only our archive: the sums file covers every platform, and the
    # others are not downloaded, so a bare `shasum -c` would report failures
    # for files that were never meant to be here.
    grep " \*\?${ARCHIVE}\$" "$SUMS" | shasum -a 256 -c -
)

echo "==> Extracting to plugins/"
# Only the binary, and nothing else: Vault's -dev-plugin-dir tries to execute
# every file it finds in the plugin directory, so a stray README or checksum
# sidecar in there stops the server from booting.
unzip -j -o -q "$CACHE/$ARCHIVE" "$PLUGIN_NAME" -d "$PLUGIN_DIR"
chmod +x "$PLUGIN_DIR/$PLUGIN_NAME"

# The registration hash. Recomputed here so it is visible in setup output and
# so demo.sh can show the same command a customer would run in production.
# Kept in .plugin-cache, not plugins/, for the reason above.
BINARY_SHA="$(shasum -a 256 "$PLUGIN_DIR/$PLUGIN_NAME" | cut -d' ' -f1)"
echo "$BINARY_SHA" >"$CACHE/binary.sha256"

echo "==> Plugin ready: plugins/$PLUGIN_NAME"
echo "    binary sha256: $BINARY_SHA"
