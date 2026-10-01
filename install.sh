#!/bin/bash
#
# LoFi FX OFX plugin installer for macOS
#
# Downloads the latest macOS release asset for each plugin, verifies the
# GitHub-provided SHA-256 digest, removes Apple's quarantine attribute, and
# installs the OFX bundles where DaVinci Resolve looks for them.
#
# Usage:
#   ./install.sh                 Install system-wide (recommended)
#   ./install.sh --user          Install for the current user
#   ./install.sh --dry-run       Download and verify, but do not install
#   ./install.sh --help
#

set -euo pipefail

readonly OFX_SYSTEM_DIR="/Library/OFX/Plugins"
readonly OFX_USER_DIR="$HOME/Library/OFX/Plugins"
readonly RESOLVE_CACHE="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/OFXPluginCacheV2.xml"
readonly API_ROOT="https://api.github.com/repos/lofi-fx"
readonly CAMERA_MATCH_ASSET_URL="https://github.com/lofi-fx/camera-match/releases/download/v0.9-beta/LoFiFxCameraMatch-macOS-v0.9-beta.zip"

INSTALL_DIR="$OFX_SYSTEM_DIR"
USE_SUDO=1
DRY_RUN=0
WORK_DIR=""

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
LoFi FX OFX plugin installer for macOS

Usage:
  ./install.sh                 Install system-wide (recommended)
  ./install.sh --user          Install for the current user
  ./install.sh --dry-run       Download and verify, but do not install
  ./install.sh --help
EOF
}

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        /bin/rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for arg in "$@"; do
    case "$arg" in
        --user)
            INSTALL_DIR="$OFX_USER_DIR"
            USE_SUDO=0
            ;;
        --system)
            INSTALL_DIR="$OFX_SYSTEM_DIR"
            USE_SUDO=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $arg"
            ;;
    esac
done

[ "$(/usr/bin/uname -s)" = "Darwin" ] || die "this installer only supports macOS"

for command in /usr/bin/curl /usr/bin/unzip /usr/bin/find /usr/bin/ditto /usr/bin/xattr /usr/bin/shasum /usr/bin/mktemp; do
    [ -x "$command" ] || die "required macOS tool is missing: $command"
done

if [ "$USE_SUDO" -eq 1 ] && [ "$(/usr/bin/id -u)" -ne 0 ]; then
    [ -x /usr/bin/sudo ] || die "sudo is required for a system-wide install"
fi

if /usr/bin/pgrep -x Resolve >/dev/null 2>&1; then
    die "DaVinci Resolve is running. Quit Resolve and run this installer again."
fi

run_privileged() {
    if [ "$USE_SUDO" -eq 1 ] && [ "$(/usr/bin/id -u)" -ne 0 ]; then
        /usr/bin/sudo "$@"
    else
        "$@"
    fi
}

release_asset() {
    # GitHub's latest endpoint excludes drafts and normally returns the latest
    # published release. The list endpoint is a fallback for repositories whose
    # newest published build is marked as a prerelease.
    local repo="$1"
    local metadata=""

    if ! metadata=$(/usr/bin/curl --fail --silent --show-error --location \
        --retry 3 --connect-timeout 20 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$API_ROOT/$repo/releases/latest" 2>/dev/null); then
        if ! metadata=$(/usr/bin/curl --fail --silent --show-error --location \
            --retry 3 --connect-timeout 20 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$API_ROOT/$repo/releases?per_page=20" 2>/dev/null); then
            if [ "$repo" = "camera-match" ]; then
                # The repository's release download is available even when its
                # GitHub API endpoint is temporarily unavailable. The URL is the
                # release asset supplied by the project maintainer.
                printf 'LoFiFxCameraMatch-macOS-v0.9-beta.zip||%s\n' "$CAMERA_MATCH_ASSET_URL"
                return 0
            fi
            die "could not read a public GitHub release for lofi-fx/$repo"
        fi
    fi

    # The response is formatted JSON from GitHub. This small state machine is
    # sufficient for the release asset fields and avoids requiring jq or Python.
    local match
    match=$(printf '%s\n' "$metadata" | /usr/bin/awk '
        /"name": "/ {
            name = $0
            sub(/^.*"name": "/, "", name)
            sub(/".*$/, "", name)
            wanted = (name ~ /[Mm]acOS/ && name ~ /[.]zip$/)
            digest = ""
        }
        wanted && /"digest": "sha256:/ {
            digest = $0
            sub(/^.*"digest": "sha256:/, "", digest)
            sub(/".*$/, "", digest)
        }
        wanted && /"browser_download_url": "/ {
            url = $0
            sub(/^.*"browser_download_url": "/, "", url)
            sub(/".*$/, "", url)
            print name "|" digest "|" url
            exit
        }
    ')

    [ -n "$match" ] || die "no macOS ZIP release asset was found for lofi-fx/$repo"
    printf '%s\n' "$match"
}

download_plugin() {
    local repo="$1"
    local bundle_name="$2"
    local metadata asset_name digest asset_url archive extract bundle bundle_contents bundle_root checksum

    metadata=$(release_asset "$repo")
    IFS='|' read -r asset_name digest asset_url <<EOF
$metadata
EOF

    archive="$WORK_DIR/$repo.zip"
    extract="$WORK_DIR/$repo"
    /bin/mkdir -p "$extract"

    printf '==> Downloading %s (%s)\n' "$repo" "$asset_name"
    if ! /usr/bin/curl --fail --silent --show-error --location \
        --retry 3 --connect-timeout 20 --progress-bar \
        "$asset_url" -o "$archive"; then
        die "could not download $asset_name"
    fi

    [ -s "$archive" ] || die "GitHub returned an empty archive for $repo"

    if [ -n "$digest" ]; then
        checksum=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
        [ "$checksum" = "$digest" ] || die "SHA-256 verification failed for $asset_name"
        printf '    Verified SHA-256: %s\n' "$checksum"
    else
        printf '    Warning: GitHub did not publish a digest for %s\n' "$asset_name" >&2
    fi

    /usr/bin/unzip -q "$archive" -d "$extract"
    # Releases may contain a normal .ofx.bundle directory or the bundle's
    # Contents directory at the ZIP root. Normalize both forms for install.
    bundle=$(/usr/bin/find "$extract" -type d -name "$bundle_name" -print -quit)
    if [ -n "$bundle" ] && [ -f "$bundle/Contents/Info.plist" ]; then
        bundle_root="$bundle"
    else
        bundle_contents=$(/usr/bin/find "$extract" -type f -path '*/Contents/Info.plist' -print -quit)
        [ -n "$bundle_contents" ] || die "archive $asset_name does not contain an OFX bundle"
        bundle_root="${bundle_contents%/Contents/Info.plist}"
    fi

    # Copy to a controlled staging location before any installation begins.
    /bin/rm -rf "$WORK_DIR/$bundle_name"
    /bin/mkdir -p "$WORK_DIR/$bundle_name"
    /usr/bin/ditto "$bundle_root/Contents" "$WORK_DIR/$bundle_name/Contents"
    /usr/bin/xattr -dr com.apple.quarantine "$WORK_DIR/$bundle_name" 2>/dev/null || true
    printf '    Staged %s\n' "$bundle_name"
}

WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lofi-fx-installer.XXXXXX")

printf 'LoFi FX macOS OFX installer\n'
printf 'Destination: %s\n\n' "$INSTALL_DIR"

# Resolve's standard OFX directory is shared by Resolve and Resolve Studio.
# Stage every plugin first so a missing release cannot produce a partial install.
download_plugin camera-match LoFiFxCameraMatch.ofx.bundle
download_plugin vhs LofiFxVhs.ofx.bundle
download_plugin planar-stabilizer LofiFxPlanarStabilizer.ofx.bundle
download_plugin faux-raw LoFiFxFauxRaw.ofx.bundle
download_plugin Spectra LofiFxSpectra.ofx.bundle

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\nDry run complete. No files were installed.\n'
    exit 0
fi

printf '\n==> Installing OFX bundles\n'
run_privileged /bin/mkdir -p "$INSTALL_DIR"

for bundle_name in \
    LoFiFxCameraMatch.ofx.bundle \
    LofiFxVhs.ofx.bundle \
    LofiFxPlanarStabilizer.ofx.bundle \
    LoFiFxFauxRaw.ofx.bundle \
    LofiFxSpectra.ofx.bundle; do
    target="$INSTALL_DIR/$bundle_name"
    temporary="$INSTALL_DIR/.${bundle_name}.new"

    run_privileged /bin/rm -rf "$temporary"
    run_privileged /usr/bin/ditto "$WORK_DIR/$bundle_name" "$temporary"
    run_privileged /usr/bin/xattr -dr com.apple.quarantine "$temporary" 2>/dev/null || true
    run_privileged /bin/rm -rf "$target"
    run_privileged /bin/mv "$temporary" "$target"
    printf '    Installed %s\n' "$bundle_name"
done

# Resolve caches the discovered OFX plug-ins. Moving the cache aside forces a
# fresh scan on the next launch without destroying it permanently.
if [ -f "$RESOLVE_CACHE" ]; then
    cache_backup="$RESOLVE_CACHE.lofi-fx-backup.$(/bin/date +%Y%m%d%H%M%S)"
    /bin/mv "$RESOLVE_CACHE" "$cache_backup"
    printf '    Reset Resolve plugin cache (backup: %s)\n' "$cache_backup"
fi

printf '\nInstalled all LoFi FX plugins. Launch DaVinci Resolve to load them.\n'
if [ "$USE_SUDO" -eq 0 ]; then
    printf 'Note: this user install uses %s; some Resolve versions scan only %s.\n' "$OFX_USER_DIR" "$OFX_SYSTEM_DIR"
fi
