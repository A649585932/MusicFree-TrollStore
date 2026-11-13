#!/usr/bin/env bash
# =============================================================================
# MusicFree → TrollStore .tipa 一键构建脚本
#
# 原理：
#   1. 仓库自带完整 RN iOS 工程（ios/MusicFree.xcodeproj + Podfile），
#      所以不需要"把 Android 改成 iOS"，只需要编译这个 iOS target。
#   2. TrollStore 通过 CoreTrust 绕过代码签名校验并永久签名，因此产物
#      不需要 Apple 开发者证书：xcodebuild 关掉签名 → 免签名 archive。
#   3. .tipa 本质就是一个 zip：最外层必须是 Payload/MusicFree.app，
#      与 .ipa 结构相同，扩展名换成 .tipa 让 TrollStore 直接识别。
#
# 运行前提：macOS + Xcode + Node >= 18 + CocoaPods（+ 可选 ldid）
# 用法：bash scripts/build-trollstore.sh
#      SCHEME=MusicFreeNew NEW_ARCH=0 SIGN_TOOL=auto bash scripts/build-trollstore.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------------------------- 可覆盖参数 -------------------------------------
# 注意：共享 scheme 文件叫 MusicFreeNew.xcscheme，而 target 名是 MusicFree。
# xcodebuild -scheme 用的是 scheme 文件名，不是 target 名，这里是最常见的踩坑点。
SCHEME="${SCHEME:-MusicFreeNew}"
WORKSPACE="${WORKSPACE:-ios/MusicFree.xcworkspace}"
CONFIGURATION="${CONFIGURATION:-Release}"
SDK="${SDK:-iphoneos}"
APP_NAME="${APP_NAME:-MusicFree.app}"
BUNDLE_ID="${BUNDLE_ID:-app.musicfree.trollstore}"
OUTPUT_NAME="${OUTPUT_NAME:-MusicFree.trollstore.tipa}"

# 0 = 关闭 New Architecture（旧架构兼容最稳，避开 react-native-mmkv 2.x 等旧库）
# 1 = 开启 New Architecture / Bridgeless
NEW_ARCH="${NEW_ARCH:-0}"

# auto | ldid | codesign | none
#   none      —— 默认。官方推荐：免签名 archive 后直接组装 Payload 打包，
#                TrollStore 安装时会用内置 ldid 递归伪签并做 CoreTrust bypass。
#   ldid      —— 越狱/TrollStore 社区标准，把自定义 entitlements 写进所有 Mach-O
#   codesign  —— macOS 自带 ad-hoc 签名（没有 ldid 时回退）
#   auto      —— 有 ldid 就用 ldid，否则 codesign
# 只有需要自定义 entitlements（JIT / 全盘访问 / root helper）时才改这项。
SIGN_TOOL="${SIGN_TOOL:-none}"

SKIP_POD_INSTALL="${SKIP_POD_INSTALL:-0}"
SKIP_NPM="${SKIP_NPM:-0}"

# ---------------------------- 固定路径 ---------------------------------------
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/MusicFree.xcarchive"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGE_DIR="$BUILD_DIR/trollstore"
ENTITLEMENTS="$ROOT/scripts/trollstore.entitlements.plist"
OUTPUT="$BUILD_DIR/$OUTPUT_NAME"

log() { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "必须在 macOS 上执行（xcodebuild / CocoaPods / codesign 都是 macOS 专有）"
command -v xcodebuild >/dev/null 2>&1 || die "找不到 xcodebuild，请先装 Xcode 并 sudo xcode-select -s /Applications/Xcode.app"
[ -f "$ENTITLEMENTS" ] || die "缺少 entitlements 文件：$ENTITLEMENTS"

export RCT_NEW_ARCH_ENABLED="$NEW_ARCH"
export EXPO_NO_TELEMETRY=1
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=8192}"

xcodebuild -version
node --version

# ---------------------------- 1. JS 依赖 -------------------------------------
log "[1/6] 安装 npm 依赖"
if [ "$SKIP_NPM" != "1" ]; then
    # 上游仓库的 package-lock.json 与 package.json 不同步（缺 fsevents /
    # lightningcss-* 各平台可选包），npm ci 在 npm >= 10 会报 EUSAGE 直接失败。
    # 因此先试 npm ci，失败自动回退 npm install（会顺带修复 lock，不影响构建）。
    if ! npm ci --no-audit --no-fund; then
        echo "⚠️  npm ci 失败（lock 不同步），回退 npm install 自动修复 lockfile…"
        npm install --no-audit --no-fund
    fi
else
    echo "跳过（SKIP_NPM=1）"
fi

# ---------------------------- 2. CocoaPods ----------------------------------
log "[2/6] pod install（生成 .xcworkspace / Pods / ExpoModulesProvider）"
if [ "$SKIP_POD_INSTALL" != "1" ]; then
    if [ -f Gemfile ] && command -v bundle >/dev/null 2>&1; then
        bundle install || echo "⚠️  bundle install 失败，回退到系统 CocoaPods"
        if bundle exec pod --version >/dev/null 2>&1; then
            POD=(bundle exec pod)
        else
            POD=(pod)
        fi
    else
        POD=(pod)
    fi
    ( cd ios && RCT_NEW_ARCH_ENABLED="$NEW_ARCH" "${POD[@]}" install )
else
    echo "跳过（SKIP_POD_INSTALL=1）"
fi

[ -d "$WORKSPACE" ] || die "找不到 workspace：$WORKSPACE（pod install 没成功？）"

# ---------------------------- 3. 免签名 archive -----------------------------
log "[3/6] xcodebuild archive（关闭全部签名）"
rm -rf "$ARCHIVE_PATH"
mkdir -p "$BUILD_DIR"

XCB_ARGS=(
    -workspace "$WORKSPACE"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -sdk "$SDK"
    -destination "generic/platform=iOS"
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    CODE_SIGN_ENTITLEMENTS=""
    DEVELOPMENT_TEAM=""
    PROVISIONING_PROFILE_SPECIFIER=""
    PROVISIONING_PROFILE=""
    ENABLE_BITCODE=NO
    SKIP_INSTALL=NO
    ONLY_ACTIVE_ARCH=NO
    RCT_NEW_ARCH_ENABLED="$NEW_ARCH"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    clean archive
)

# pipefail 保证 xcodebuild 失败时脚本立刻退出，同时把完整日志落盘
xcodebuild "${XCB_ARGS[@]}" 2>&1 | tee "$BUILD_DIR/xcodebuild.log"

APP_SRC="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
[ -d "$APP_SRC" ] || die "archive 里没找到 $APP_NAME，请看 $BUILD_DIR/xcodebuild.log"

# Release 必须把 JS bundle 打进 app，否则装到手机上是白屏
if [ ! -f "$APP_SRC/main.jsbundle" ]; then
    echo "⚠️  警告：未发现 main.jsbundle，检查 xcodebuild.log 中 'Bundle React Native code and images' 阶段是否报错"
else
    echo "✓ main.jsbundle 已内嵌（离线可启动）"
fi

# ---------------------------- 4. 组装 Payload -------------------------------
log "[4/6] 组装 Payload/$APP_NAME"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Payload"
# -Rp 保留符号链接（framework 里的 Versions/Current 等），不跟随、不改权限
cp -Rp "$APP_SRC" "$STAGE_DIR/Payload/"
find "$STAGE_DIR/Payload" -name '.DS_Store' -delete 2>/dev/null || true
find "$STAGE_DIR/Payload" -name '__MACOSX' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# ---------------------------- 5. 伪签名 -------------------------------------
log "[5/6] 伪签名（默认 none：交给 TrollStore 安装时递归伪签 + CoreTrust bypass）"

sign_with_ldid() {
    # ldid -S<plist> 会把 entitlements 应用到 .app 内所有 Mach-O
    ldid -S"$ENTITLEMENTS" "$STAGE_DIR/Payload/$APP_NAME"
    echo "✓ ldid 伪签完成"
}

sign_with_codesign() {
    local app="$STAGE_DIR/Payload/$APP_NAME"
    # 先签嵌套的 frameworks / dylibs / appex，最后签最外层 .app
    if [ -d "$app/Frameworks" ]; then
        find "$app/Frameworks" \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print0 |
            while IFS= read -r -d '' item; do
                codesign --force --sign - --timestamp=none "$item" 2>/dev/null || true
            done
    fi
    codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$app"
    echo "✓ codesign ad-hoc 伪签完成"
}

case "$SIGN_TOOL" in
    none)
        echo "跳过伪签（SIGN_TOOL=none）"
        ;;
    ldid)
        command -v ldid >/dev/null 2>&1 || die "找不到 ldid：brew install ldid，或改用 SIGN_TOOL=codesign"
        sign_with_ldid
        ;;
    codesign)
        sign_with_codesign
        ;;
    auto)
        # 兼容旧调用：auto 仍按"有 ldid 就 ldid、否则 codesign"处理；
        # 新流程默认 SIGN_TOOL=none，不需要任何本地签名工具。
        if command -v ldid >/dev/null 2>&1; then
            sign_with_ldid
        else
            echo "未装 ldid，回退 codesign ad-hoc"
            sign_with_codesign
        fi
        ;;
    *) die "未知 SIGN_TOOL=$SIGN_TOOL（可选 auto|ldid|codesign|none）" ;;
esac

# ---------------------------- 6. 打包 .tipa ---------------------------------
log "[6/6] 打包 .tipa"
rm -f "$OUTPUT"
# -y 关键：把符号链接作为链接存进 zip，而不是展开成实体文件（否则 framework 会坏）
( cd "$STAGE_DIR" && zip -qry "$OUTPUT" Payload -x '*.DS_Store' '*__MACOSX*' )

# ---------------------------- 验证 -------------------------------------------
log "产物校验"
echo "== zip 顶层结构（应只有 Payload/）=="
unzip -Z1 "$OUTPUT" | awk -F/ '{print $1}' | sort -u
echo
echo "== 前 20 项 =="
unzip -l "$OUTPUT" | sed -n '1,20p'
echo
echo "== Info.plist 关键字段 =="
plutil -p "$STAGE_DIR/Payload/$APP_NAME/Info.plist" 2>/dev/null |
    grep -E 'CFBundleIdentifier|CFBundleShortVersionString|MinimumOSVersion|NSAllowsArbitraryLoads|UIFileSharingEnabled|UIBackgroundModes|CFBundleURLTypes' || true
echo
echo "== 签名状态 =="
codesign -dv "$STAGE_DIR/Payload/$APP_NAME" 2>&1 | sed -n '1,12p' || true
echo
echo "== SHA-256 =="
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$OUTPUT"; else openssl dgst -sha256 "$OUTPUT"; fi

printf '\n\033[1;32m✅ 完成：%s\033[0m\n' "$OUTPUT"
cat <<'EOF'

安装步骤：
  1. 把 .tipa 传到 iPhone（AirDrop / 文件 App / Safari 下载均可）
  2. 用 TrollStore 打开该文件 → Install
  3. TrollStore 会以 CoreTrust 永久签名，重启后依然可用，无需每 7 天重签
  4. 首次启动若提示"不受信任的企业开发者"，在 TrollStore 里点
     "Refresh App Registrations"，或 设置 → 通用 → VPN与设备管理 里信任

提示：插件音源若为 http://，已在 Info.plist 放开 ATS；
      状态栏歌词 / 退出应用 / ID3 元数据在 iOS 端为安全降级实现，详见 TROLLSTORE.md。
EOF
