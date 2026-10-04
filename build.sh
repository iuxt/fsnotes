#!/bin/bash
# Build and install the macOS app. Run from any directory: /path/to/fsnotes/build.sh
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${FSNOTES_BUILD_DIR:-$project_dir/.build}"
install_dir="${FSNOTES_INSTALL_DIR:-/Applications}"
configuration="Release"
stage_dir=""
install_done=false
needs_sudo=false

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

run_install() {
    if [[ "$needs_sudo" == true ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$stage_dir" ]]; then
        if [[ "$install_done" == false ]] && run_install test -e "$stage_dir/previous.app"; then
            if [[ ! -e "$destination" && ! -L "$destination" ]] &&
                run_install /bin/mv "$stage_dir/previous.app" "$destination"; then
                printf '已恢复原来的 %s\n' "$destination" >&2
            else
                printf '旧版本保留在 %s/previous.app，请手动恢复。\n' "$stage_dir" >&2
                exit "$status"
            fi
        fi
        if ! run_install /bin/rm -rf "$stage_dir"; then
            printf '临时安装目录未能清理：%s\n' "$stage_dir" >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(uname -s)" == Darwin ]] || fail '此脚本需要 macOS 和完整的 Xcode。'
command -v xcodebuild >/dev/null 2>&1 || fail '未找到 xcodebuild，请先安装 Xcode。'
xcodebuild -version >/dev/null 2>&1 || fail 'Xcode 未配置，请使用 xcode-select 选择完整的 Xcode。'
[[ -d "$project_dir/FSNotes.xcodeproj" ]] || fail '未找到 FSNotes.xcodeproj。'
[[ "$build_dir" == /* && "$install_dir" == /* ]] || fail '构建目录和安装目录必须使用绝对路径。'
[[ -d "$install_dir" ]] || fail "安装目录不存在：$install_dir"
destination="$install_dir/FSNotes.app"
[[ ! -L "$destination" ]] || fail "安装位置是符号链接，请先检查：$destination"
[[ ! -e "$destination" || -d "$destination/Contents" ]] || fail "安装位置不是应用包：$destination"

mkdir -p "$build_dir"
printf '正在构建 FSNotes（%s）…\n构建日志：%s/build.log\n' "$configuration" "$build_dir"
if ! xcodebuild \
    -project "$project_dir/FSNotes.xcodeproj" \
    -scheme FSNotes \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$build_dir" \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE= \
    PROVISIONING_PROFILE_SPECIFIER= \
    build 2>&1 | tee "$build_dir/build.log"; then
    fail "构建失败，已安装的应用未改动。请查看 $build_dir/build.log"
fi

app="$build_dir/Build/Products/$configuration/FSNotes.app"
[[ -x "$app/Contents/MacOS/FSNotes" && -f "$app/Contents/Info.plist" ]] || fail "未找到完整的构建产物：$app"
/usr/bin/codesign --verify --deep --strict "$app" || fail '构建产物签名校验失败。'

if [[ ! -w "$install_dir" ]]; then
    printf '安装到 %s 需要管理员权限。\n' "$install_dir"
    sudo -v || fail '未能获取安装权限。'
    needs_sudo=true
fi

# Copy and verify the complete new app before moving the existing installation.
stage_dir="$(run_install /usr/bin/mktemp -d "$install_dir/.fsnotes-install.XXXXXX")"
run_install /usr/bin/ditto "$app" "$stage_dir/FSNotes.app"
run_install /usr/bin/codesign --verify --deep --strict "$stage_dir/FSNotes.app"

if pgrep -x FSNotes >/dev/null 2>&1; then
    printf '正在退出 FSNotes，以便更新…\n'
    /usr/bin/osascript -e 'tell application "FSNotes" to quit' || fail '无法退出 FSNotes，请手动退出后重试。'
    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! pgrep -x FSNotes >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if pgrep -x FSNotes >/dev/null 2>&1; then
        fail 'FSNotes 仍在运行（可能有待处理的对话框），请退出后重试。'
    fi
fi

if [[ -e "$destination" || -L "$destination" ]]; then
    [[ ! -L "$destination" && -d "$destination/Contents" ]] || fail '安装位置已变化，请检查后重试。'
    run_install /bin/mv "$destination" "$stage_dir/previous.app"
fi
run_install /bin/mv "$stage_dir/FSNotes.app" "$destination"
install_done=true
printf '已安装／更新：%s\n可运行：open "%s"\n' "$destination" "$destination"
