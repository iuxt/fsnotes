#!/bin/bash
# Xcode build phase for both macOS targets. End users need no Git LFS install.
set -euo pipefail

lfs_source="${GIT_LFS_EXECUTABLE:-}"
if [[ -z "$lfs_source" ]]; then
    for candidate in /opt/homebrew/bin/git-lfs /usr/local/bin/git-lfs "$(command -v git-lfs || true)"; do
        if [[ -x "$candidate" ]]; then
            lfs_source="$candidate"
            break
        fi
    done
fi
if [[ ! -x "$lfs_source" ]]; then
    echo 'error: Install git-lfs on the build machine (brew install git-lfs), or set GIT_LFS_EXECUTABLE to its absolute path.' >&2
    exit 1
fi

# /usr/bin/git is an xcrun shim, which cannot run inside App Sandbox. Embed
# the actual Git executable and its keychain credential helper used by LFS.
git_source="${GIT_EXECUTABLE:-$(/usr/bin/xcrun --find git)}"
credential_source="${GIT_CREDENTIAL_OSXKEYCHAIN_EXECUTABLE:-$("$git_source" --exec-path)/git-credential-osxkeychain}"
helper_dir="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
resource_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$helper_dir" "$resource_dir"
for tool in git git-lfs git-credential-osxkeychain; do
    case "$tool" in
        git) source="$git_source" ;;
        git-lfs) source="$lfs_source" ;;
        git-credential-osxkeychain) source="$credential_source" ;;
    esac
    # Reject an architecture mismatch before shipping a broken app.
    for architecture in $ARCHS; do
        /usr/bin/lipo "$source" -verify_arch "$architecture"
    done
    helper="$helper_dir/$tool"
    /bin/cp -L "$source" "$helper"
    /bin/chmod 755 "$helper"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
        signing_options=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}"
            --identifier "$PRODUCT_BUNDLE_IDENTIFIER.$tool"
            --entitlements "$SRCROOT/FSNotes/GitLFS.entitlements")
        if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == YES ]]; then
            signing_options+=(--options runtime)
        fi
        /usr/bin/codesign "${signing_options[@]}" "$helper"
    fi
done
# Local Git remotes invoke these built-in commands by executable name.
for tool in git-upload-pack git-receive-pack; do
    /bin/ln -sf git "$helper_dir/$tool"
done
for license in GitLFS-LICENSE.md Git-LICENSE.txt; do
    /bin/cp "$SRCROOT/Resources/$license" "$resource_dir/$license"
done
