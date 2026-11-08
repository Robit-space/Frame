# Frame v3.0.1 combined repair + FrameApp Chinese localization + Actions build
# Run from the root of your Robit-space/Frame clone in Windows PowerShell 5.1+.
$ErrorActionPreference = "Stop"

$ExpectedHead = "9b1c974126e5f480ee622ce4b9ee94d8a72aee29"
$FrameAppCommit = "c673963dd6b2d6852096a4b396a624169383ef20"
$Branch = "fix/frame-301-combined"
$FrameAppRepo = "https://github.com/Zerui18/FrameApp.git"
$TempApp = Join-Path $env:TEMP ("FrameApp-" + [guid]::NewGuid().ToString("N"))

function Fail($Message) { throw $Message }

function Replace-Exact {
    param([string]$Path, [string]$Old, [string]$New, [int]$Expected = 1)
    $full = Join-Path (Get-Location) $Path
    if (!(Test-Path $full)) { Fail "Missing file: $Path" }
    $content = [IO.File]::ReadAllText($full)
    $count = ([regex]::Matches($content, [regex]::Escape($Old))).Count
    if ($count -ne $Expected) {
        Fail "Replacement check failed in $Path. Expected $Expected occurrence(s), found $count. No automatic guess was made."
    }
    $content = $content.Replace($Old, $New)
    [IO.File]::WriteAllText($full, $content, [Text.UTF8Encoding]::new($false))
}

function Replace-AppExact {
    param([string]$Path, [string]$Old, [string]$New, [int]$Expected = 1)
    $full = Join-Path $TempApp $Path
    if (!(Test-Path $full)) { Fail "Missing FrameApp file: $Path" }
    $content = [IO.File]::ReadAllText($full)
    $count = ([regex]::Matches($content, [regex]::Escape($Old))).Count
    if ($count -ne $Expected) {
        Fail "FrameApp replacement check failed in $Path. Expected $Expected occurrence(s), found $count."
    }
    $content = $content.Replace($Old, $New)
    [IO.File]::WriteAllText($full, $content, [Text.UTF8Encoding]::new($false))
}

try {
    if (!(Test-Path ".git") -or !(Test-Path "Makefile") -or !(Test-Path "src/Tweak.xm")) {
        Fail "Run this script from the root directory of your Frame repository."
    }

    $branchNow = (git branch --show-current).Trim()
    if ($branchNow -ne "v3") { Fail "Expected branch v3; current branch is '$branchNow'." }

    $headNow = (git rev-parse HEAD).Trim()
    if ($headNow -ne $ExpectedHead) { Fail "Unexpected HEAD $headNow. Expected $ExpectedHead. Update/check out the reviewed v3 commit before running." }

    $status = git status --porcelain
    if ($LASTEXITCODE -ne 0) { Fail "Could not read git status." }
    if ($status) { Fail "Working tree is not clean. Commit or stash existing changes first." }

    $origin = (git remote get-url origin).Trim()
    if ($origin -notmatch 'github\.com[:/]Robit-space/Frame(\.git)?$') {
        Fail "origin must point to Robit-space/Frame. Current origin: $origin"
    }

    git show-ref --verify --quiet "refs/heads/$Branch"
    if ($LASTEXITCODE -eq 0) { Fail "Branch $Branch already exists locally. Rename/remove it after checking its contents; this script will not overwrite it." }

    Write-Host "Cloning the pinned FrameApp source..." -ForegroundColor Cyan
    git clone --quiet $FrameAppRepo $TempApp
    if ($LASTEXITCODE -ne 0) { Fail "Could not clone FrameApp." }
    Push-Location $TempApp
    git checkout --quiet $FrameAppCommit
    if ($LASTEXITCODE -ne 0) { Fail "Could not check out pinned FrameApp commit." }
    $appHead = (git rev-parse HEAD).Trim()
    if ($appHead -ne $FrameAppCommit) { Fail "FrameApp pin mismatch: $appHead" }
    Pop-Location

    # --- Frame tweak: migrate the preference key before registerDefaults ---
    Replace-Exact "src/Frame.mm" @'
        // get user defaults & set default values
        bundleDefaults = [[NSUserDefaults alloc] initWithSuiteName: @"com.Zerui.framepreferences"];
        [bundleDefaults registerDefaults: @{
                                            @"isEnabled" : @true,
                                            @"disableOnLPM" : @true,
'@ @'
        // Get user defaults. Migrate the old key before registerDefaults,
        // otherwise the registered default can hide whether a stored value exists.
        bundleDefaults = [[NSUserDefaults alloc] initWithSuiteName: @"com.Zerui.framepreferences"];
        if ([bundleDefaults objectForKey: @"disabledOnLPM"] == nil &&
            [bundleDefaults objectForKey: @"disableOnLPM"] != nil) {
            [bundleDefaults setBool: [bundleDefaults boolForKey: @"disableOnLPM"] forKey: @"disabledOnLPM"];
        }
        [bundleDefaults registerDefaults: @{
                                            @"isEnabled" : @true,
                                            @"disabledOnLPM" : @true,
'@

    Replace-Exact "src/Frame.mm" 'disableOnLPM = [bundleDefaults boolForKey: @"disableOnLPM"];' 'disableOnLPM = [bundleDefaults boolForKey: @"disabledOnLPM"];'
    Replace-Exact "src/Frame.mm" 'KVC_OBSERVE(@"disableOnLPM");' 'KVC_OBSERVE(@"disabledOnLPM");'
    Replace-Exact "src/Frame.mm" 'ELIF_KEYPATH(@"disableOnLPM", disableOnLPM = changeInBool;)' 'ELIF_KEYPATH(@"disabledOnLPM", disableOnLPM = changeInBool; self.enabled = self.isTweakEnabled;)'
    Replace-Exact "src/Frame.mm" 'if ([bundleDefaults boolForKey: @"disableOnLPM"]) {' 'if ([bundleDefaults boolForKey: @"disabledOnLPM"]) {'

    # --- Frame tweak: update wallpaper layer on every layout and identify variants ---
    Replace-Exact "src/SpringBoard.h" @'
@interface SBFWallpaperView : UIView
@property UIView *contentView;
@end
'@ @'
@interface SBFWallpaperView : UIView
@property UIView *contentView;
@property (nonatomic, copy, readonly) NSString *variantCacheIdentifier;
- (void)setGeneratesBlurredImages:(BOOL)value;
@end
'@

    Replace-Exact "src/Tweak.xm" 'else if (%c(SBWallpaperController)) {' 'else if (%c(SBWallpaperViewController)) {'
    Replace-Exact "src/Tweak.xm" @'
		- (void) willMoveToWindow: (UIWindow *) window {
			%orig;
			// Setup wallpaper player.
			// Only do this for coversheet window, which is not covered by the SBWallpaperController hook.
			if ([window isKindOfClass: [%c(SBCoverSheetWindow) class]]) {
				setupWallpaperPlayer(self, true);
			}
		}

		- (void) layoutSubviews {
			%orig;
			if (!self.window || ![self.window isKindOfClass: [%c(SBCoverSheetWindow) class]]) return;

			// Send playerLayer to front and match its frame to that of the current view.
			// Note: for compatibility with SpringArtwork, we let SAViewController's view's layer stay atop :)
			AVPlayerLayer *playerLayer = objc_getAssociatedObject(self, &playerLayerKey);

			// Remove playerLayer from its current superlayer.
			[playerLayer removeFromSuperlayer];

			// Find SAViewController's view's layer.
			CALayer *saLayer;
			for (UIView *view in self.subviews) {
				if ([view.nextResponder isKindOfClass: [%c(SAViewController) class]]) {
					saLayer = view.layer;
					break;
				}
			}

			// Re-add playerLayer.
			if (saLayer != nil)
				[self.layer insertSublayer: playerLayer below: saLayer];
			else
				[self.layer addSublayer: playerLayer];

			// Adjust playerLayer to fit the wallpaperView.
			playerLayer.frame = self.bounds;
		}
'@ @'
		- (void) didMoveToWindow {
			%orig;
			// SpringBoard creates additional wallpaper-view instances during transitions.
			// Use the system variant identifier instead of assuming every coversheet view is lockscreen.
			NSString *variant = self.variantCacheIdentifier;
			if ([variant isEqualToString: @"home"])
				setupWallpaperPlayer(self, false);
			else if ([variant isEqualToString: @"lock"])
				setupWallpaperPlayer(self, true);
			else if (self.window && [self.window isKindOfClass: [%c(SBCoverSheetWindow) class]])
				setupWallpaperPlayer(self, true);
			adjustWallpaperPlayer(self);
		}

		- (void) layoutSubviews {
			%orig;
			AVPlayerLayer *playerLayer = objc_getAssociatedObject(self, &playerLayerKey);
			if (!playerLayer) return;

			// Keep the video filling the view after rotation/resize, without animation.
			[CATransaction begin];
			[CATransaction setDisableActions: YES];
			playerLayer.frame = self.bounds;
			[CATransaction commit];

			// Only coversheet needs the special layer ordering for SpringArtwork.
			if (!self.window || ![self.window isKindOfClass: [%c(SBCoverSheetWindow) class]]) return;
			[playerLayer removeFromSuperlayer];

			CALayer *saLayer = nil;
			for (UIView *view in self.subviews) {
				if ([view.nextResponder isKindOfClass: [%c(SAViewController) class]]) {
					saLayer = view.layer;
					break;
				}
			}
			if (saLayer != nil)
				[self.layer insertSublayer: playerLayer below: saLayer];
			else
				[self.layer addSublayer: playerLayer];
		}
'@

    # Use the selected Theos SDK instead of the original developer's absolute Mac path.
    Replace-Exact "Makefile" 'SYSROOT = /Users/zeruichen/theos/sdks/iPhoneOS13.7.sdk' 'SYSROOT = $(THEOS)/sdks/iPhoneOS15.5.sdk'
    Replace-Exact "framecli/Makefile" 'SYSROOT = /Users/zeruichen/theos/sdks/iPhoneOS13.7.sdk' 'SYSROOT = $(THEOS)/sdks/iPhoneOS15.5.sdk'

    # --- FrameApp: complete user-facing Chinese strings + LPM key + UI toggle ---
    Replace-AppExact "FrameApp/Setting.swift" 'case isEnabled, disabledOnLPM, pauseInApps, syncRingerVolume, fadeEnabled, fadeAlpha, fadeInactivity, fixBlur, videoPath, videoVolume, parallexTrail, parallexNPages, isMuted' 'case isEnabled, disabledOnLPM, pauseInApps, syncRingerVolume, fadeEnabled, fadeAlpha, fadeInactivity, fixBlur, videoPath, videoVolume, parallexTrail, parallexNPages, isMuted'

    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("Settings")' 'Text("设置")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'SettingToggle(title: "Enabled"' 'SettingToggle(title: "启用 Frame"'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'SettingToggle(title: "Disable On LPM"' 'SettingToggle(title: "低电量模式时停用"'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("MASTER")' 'Text("主要设置")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("Enable \"Disable on LPM\" to automatically disable Frame on Low Power Mode.")' 'Text("开启后，设备进入低电量模式时会自动停用 Frame。")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'SettingToggle(title: "Pause in Apps"' 'SettingToggle(title: "打开应用时暂停"'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("Enable \"Pause in Apps\" to save battery.")' 'Text("开启后，进入应用时暂停视频壁纸，以节省电量。")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("FADE")' 'Text("淡出效果")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("Be fully absorbed in your video wallpaper as the home screen icons fade to a set transparency after a set period of inactivity.")' 'Text("主屏幕在一段时间无操作后，图标会逐渐变为设定的透明度。")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'SettingToggle(title: "Sync Ringer Volume"' 'SettingToggle(title: "同步铃声音量"'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("MISC")' 'Text("其他")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("This option allows you to change the ringer volume with the volume buttons when Frame is enabled, by syncing the ringer volume to the media volume.")' 'Text("启用后，Frame 运行时可通过音量键调节铃声音量；铃声音量将与媒体音量同步。")'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'SettingToggle(title: "Fix Blur"' 'SettingToggle(title: "修复背景模糊"'
    Replace-AppExact "FrameApp/MoreTab/MoreTab.swift" 'Text("Enable this option if the folders''/dock''s backgrounds appear fixed despite the video playing below them. It''s side-effect is mild to serious lagging when editing homescreen. Requires a respring to apply.")' 'Text("如果文件夹或 Dock 背景没有随视频壁纸变化，可尝试开启此选项。可能导致编辑主屏幕时卡顿，需要注销并重新启动 SpringBoard 后生效。")'

    Replace-AppExact "FrameApp/MoreTab/FadeSettings.swift" 'Toggle("Fade Enabled"' 'Toggle("启用图标淡出"'
    Replace-AppExact "FrameApp/MoreTab/FadeSettings.swift" '"Fade Alpha: %.2f"' '"淡出透明度：%.2f"'
    Replace-AppExact "FrameApp/MoreTab/FadeSettings.swift" '"Inactivity Duration: %.1f"' '"无操作时长：%.1f 秒"'

    Replace-AppExact "FrameApp/ContentView.swift" 'Text("Catalogue")' 'Text("视频库")'
    Replace-AppExact "FrameApp/ContentView.swift" 'Text("More")' 'Text("设置")'
    Replace-AppExact "FrameApp/CatalogueTab/CatalogueTab.swift" 'Text("Catalogue")' 'Text("视频库")'
    Replace-AppExact "FrameApp/CatalogueTab/CatalogueTab.swift" 'Text("\(model.listingItems.count) videos")' 'Text("\(model.listingItems.count) 个视频")'
    Replace-AppExact "FrameApp/CatalogueTab/CatalogueTab.swift" 'Text("Preview")' 'Text("预览")'
    Replace-AppExact "FrameApp/CatalogueTab/CatalogueTab.swift" 'Text("Download")' 'Text("下载")'
    Replace-AppExact "FrameApp/CatalogueTab/DownloadsList.swift" 'Text("There is no download currently.")' 'Text("当前没有下载任务。")'
    Replace-AppExact "FrameApp/CatalogueTab/DownloadsListRow.swift" 'Text("It shouldn''t be here!")' 'Text("已下载")'
    Replace-AppExact "FrameApp/CatalogueTab/DownloadsListRow.swift" 'Text("Error: \(error.localizedDescription)")' 'Text("下载失败，请重试。")'
    Replace-AppExact "FrameApp/CatalogueTab/DownloadsListRow.swift" 'Text("Paused")' 'Text("已暂停")'
    Replace-AppExact "FrameApp/CatalogueTab/DownloadsListRow.swift" 'Text("Preparing...")' 'Text("准备中…")'
    Replace-AppExact "FrameApp/FrameTab/FrameTab.swift" 'Text("Both")' 'Text("全部")'
    Replace-AppExact "FrameApp/FrameTab/FrameTab.swift" 'Text("Home")' 'Text("主屏幕")'
    Replace-AppExact "FrameApp/FrameTab/FrameTab.swift" 'Text("Lock")' 'Text("锁定屏幕")'
    Replace-AppExact "FrameApp/FrameTab/FrameTabPage.swift" 'Text("~ Empty ~")' 'Text("尚未设置视频")'
    Replace-AppExact "FrameApp/FrameTab/FrameTabPage.swift" 'Text("Choose Video")' 'Text("选择视频")'
    Replace-AppExact "FrameApp/FrameTab/FrameTabPage.swift" 'Text("Unset")' 'Text("取消设置")'
    Replace-AppExact "FrameApp/FrameTab/LibraryView.swift" 'Text("Set").bold()' 'Text("设为壁纸").bold()'
    Replace-AppExact "FrameApp/FrameTab/LibraryView.swift" 'Text("Preview")' 'Text("预览")'
    Replace-AppExact "FrameApp/FrameTab/LibraryView.swift" 'Text("Delete")' 'Text("删除")'
    Replace-AppExact "FrameApp/Views/VideoGalleryView.swift" 'bar.placeholder = "Name"' 'bar.placeholder = "搜索视频名称"'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoView.swift" 'Text("Frame Tweak Not Found")' 'Text("未检测到 Frame 插件")'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoView.swift" 'Text("No compatible Frame tweak found. Please check that you have installed the latest version of the Frame tweak.")' 'Text("未找到兼容的 Frame 插件，请检查是否已安装最新版本。")'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoView.swift" 'Text("Install/Upgrade Frame")' 'Text("安装或更新 Frame")'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoView.swift" 'Text("Dismiss")' 'Text("关闭")'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoModel.swift" 'return "App     v\(versionNumber) (\(buildNumber))"' 'return "应用版本  v\(versionNumber) (\(buildNumber))"'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoModel.swift" 'let updatedVersion = "(Not Installed)"' 'let updatedVersion = "（未安装）"'
    Replace-AppExact "FrameApp/FrameTab/FrameInfoModel.swift" 'self.tweakVersion = "Tweak \(updatedVersion)"' 'self.tweakVersion = "插件版本 \(updatedVersion)"' 
    Replace-AppExact "FrameApp/FrameTab/FrameInfoModel.swift" 'self.tweakVersion = "Tweak \(updatedVersion)"' 'self.tweakVersion = "插件版本 \(updatedVersion)"' 0

    Replace-AppExact "XKAPI/XKAPI.swift" 'return englishNames[name] ?? name' 'return name'
    # Remove the now-unused English category translation dictionary.
    Replace-AppExact "XKAPI/XKAPI.swift" '/// The english translation for the important category names.' '/// Category names are displayed in their original Chinese form.'
    Replace-AppExact "XKAPI/XKAPI.swift" 'fileprivate let englishNames = ["首页" : "Home", "最新" : "New", "推荐" : "Hot", "景观" : "Landscapes", "动漫" : "Anime", "游戏" : "Games", "其它" : "Abstract"]' 'fileprivate let englishNames: [String: String] = [:]'
    Replace-AppExact "XKAPI/Utils.swift" 'Either decryption or unzipping of the xkapi data failed.' 'XKAPI 数据解密或解压失败。'

    # Replace the custom Install build phase with a no-op in the checked-out app source.
    $pbx = Join-Path $TempApp "FrameApp.xcodeproj/project.pbxproj"
    $pbxText = [IO.File]::ReadAllText($pbx)
    $phasePattern = '(?s)([A-F0-9]{24} /\* Install \*/ = \{\s*isa = PBXShellScriptBuildPhase;.*?name = Install;.*?shellPath = /bin/sh;\s*shellScript = )".*?";(\s*\};)'
    $matches = [regex]::Matches($pbxText, $phasePattern)
    if ($matches.Count -ne 1) { Fail "Could not uniquely locate FrameApp Install build phase in project.pbxproj." }
    $pbxText = [regex]::Replace($pbxText, $phasePattern, '$1"exit 0;";$2', 1)
    [IO.File]::WriteAllText($pbx, $pbxText, [Text.UTF8Encoding]::new($false))

    # Save the FrameApp patch as a tracked artifact consumed by GitHub Actions.
    Push-Location $TempApp
    $patch = git diff --binary
    if ($LASTEXITCODE -ne 0 -or !$patch) { Fail "FrameApp patch generation failed." }
    Pop-Location
    $ciDir = Join-Path (Get-Location) "ci"
    New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
    $patchPath = Join-Path $ciDir "frameapp.patch"
    $patch | Set-Content -Path $patchPath -Encoding UTF8

    # --- Workflow: compile FrameApp first, replace bundled legacy app, then package tweak ---
    $workflow = @'
name: Frame Rootless Build

on:
  push:
    branches:
      - v3
      - "fix/**"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    runs-on: macos-14
    steps:
      - name: Checkout Frame
        uses: actions/checkout@v4

      - name: Checkout pinned FrameApp source
        uses: actions/checkout@v4
        with:
          repository: Zerui18/FrameApp
          ref: c673963dd6b2d6852096a4b396a624169383ef20
          path: frameapp-src

      - name: Install build dependencies
        run: |
          brew install make dpkg ldid xz cocoapods

      - name: Apply FrameApp Chinese localization patch
        run: |
          cd frameapp-src
          git apply ../ci/frameapp.patch
          test -f FrameApp.xcworkspace/contents.xcworkspacedata

      - name: Install FrameApp dependencies
        working-directory: frameapp-src
        run: |
          pod install --repo-update

      - name: Build FrameApp
        working-directory: frameapp-src
        run: |
          xcodebuild \
            -workspace Frame.xcworkspace \
            -scheme FrameApp \
            -configuration Release \
            -sdk iphoneos \
            -derivedDataPath "$RUNNER_TEMP/FrameAppDerived" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            build

      - name: Replace bundled FrameApp
        run: |
          APP="$RUNNER_TEMP/FrameAppDerived/Build/Products/Release-iphoneos/FrameApp.app"
          test -d "$APP"
          rm -rf layout/var/jb/Applications/FrameApp.app
          mkdir -p layout/var/jb/Applications
          ditto "$APP" layout/var/jb/Applications/FrameApp.app
          rm -rf layout/var/jb/Applications/FrameApp.app/_CodeSignature
          rm -f layout/var/jb/Applications/FrameApp.app/embedded.mobileprovision
          ldid -Sframeapp-src/FrameApp/FrameApp_.entitlements \
            layout/var/jb/Applications/FrameApp.app/FrameApp

      - name: Checkout Theos
        uses: actions/checkout@v4
        with:
          repository: theos/theos
          ref: 8167f59de02fd32cf45b16bfcb1330dfa5c9974c
          path: theos

      - name: Checkout iOS SDKs
        uses: actions/checkout@v4
        with:
          repository: xybp888/iOS-SDKs
          ref: 4a48e5409f8ea6ac422c44d91b86fa0f8ae010ff
          path: sdk-source

      - name: Prepare SDK
        run: |
          mkdir -p theos/sdks
          cp -R sdk-source/iPhoneOS15.5.sdk theos/sdks/

      - name: Build Rootless package
        env:
          THEOS: ${{ github.workspace }}/theos
        run: |
          gmake package FINALPACKAGE=1 \
            THEOS="$THEOS" \
            SYSROOT="$THEOS/sdks/iPhoneOS15.5.sdk"

      - name: Verify package
        run: |
          find packages -name "*.deb" -type f
          test -n "$(find packages -name '*.deb' -type f)"

      - name: Upload DEB
        uses: actions/upload-artifact@v4
        with:
          name: Frame-Rootless-iOS
          path: packages/*.deb
          if-no-files-found: error
          retention-days: 14
'@
    $workflowPath = Join-Path (Get-Location) ".github/workflows/build.yml"
    [IO.File]::WriteAllText($workflowPath, $workflow, [Text.UTF8Encoding]::new($false))

    # Validate and stage.
    git diff --check
    if ($LASTEXITCODE -ne 0) { Fail "git diff --check failed." }
    git switch -c $Branch
    if ($LASTEXITCODE -ne 0) { Fail "Could not create repair branch." }
    git add src/Frame.mm src/Tweak.xm src/SpringBoard.h Makefile framecli/Makefile .github/workflows/build.yml ci/frameapp.patch
    if ($LASTEXITCODE -ne 0) { Fail "git add failed." }
    git diff --cached --check
    if ($LASTEXITCODE -ne 0) { Fail "Staged diff check failed." }
    Write-Host "`nChange summary:" -ForegroundColor Cyan
    git diff --cached --stat
    Write-Host "`nCreating commit and pushing branch..." -ForegroundColor Cyan
    git commit -m "Fix Frame 3.0.1 rootless build, wallpaper layout and Chinese app UI"
    if ($LASTEXITCODE -ne 0) { Fail "Commit failed." }
    git push -u origin $Branch
    if ($LASTEXITCODE -ne 0) { Fail "Push failed. The local branch and commit are preserved; fix authentication/network and run git push -u origin $Branch." }

    Write-Host "`nDone. Open GitHub Actions for branch $Branch and download the Frame-Rootless-iOS artifact." -ForegroundColor Green
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "No force-push was attempted. Review the working tree before retrying." -ForegroundColor Yellow
    exit 1
}
finally {
    if (Test-Path $TempApp) { Remove-Item -Recurse -Force $TempApp -ErrorAction SilentlyContinue }
}
