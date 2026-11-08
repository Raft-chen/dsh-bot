# ===================================================================
#  reapply-patches.ps1
#
#  重新应用 dsh-lark-bot 运行所需的两处源码补丁（幂等，可反复运行）。
#
#  补丁 1  dsh-app-boot      HMR 服务作用域不匹配 -> 整个 profile 启动失败
#  补丁 2  dsh-llm-deepseek  模型 id 过期（deepseek-v4-flash -> deepseek-flash）
#
#  什么时候需要跑：
#    * 升级了 dsh-lark-bot
#    * 重装了 DSH 运行时 / 重建了 profile
#    * 执行过 pnpm install --force
#    * bot 又开始"执行出错"，或任务全部 failed
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File .\reapply-patches.ps1
#
#    指定 DSH_HOME：
#    powershell -ExecutionPolicy Bypass -File .\reapply-patches.ps1 -DshHome "E:\dsh"
# ===================================================================

[CmdletBinding()]
param(
    [string]$DshHome = $env:DSH_HOME
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DshHome)) {
    # 常见默认位置
    $candidates = @('D:\dsh', "$env:USERPROFILE\.dsh")
    $DshHome = $candidates | Where-Object { Test-Path (Join-Path $_ 'profiles') } | Select-Object -First 1
}

Write-Host ""
Write-Host "  dsh-bot 补丁修复工具" -ForegroundColor Cyan
Write-Host "  ===================================================="

if ([string]::IsNullOrWhiteSpace($DshHome) -or -not (Test-Path $DshHome)) {
    Write-Host "  [X] 找不到 DSH_HOME，请用 -DshHome 指定" -ForegroundColor Red
    Write-Host "      例如: -DshHome `"D:\dsh`"" -ForegroundColor DarkGray
    exit 1
}

Write-Host "  DSH_HOME: $DshHome"
Write-Host ""

$profilesRoot = Join-Path $DshHome 'profiles\node_modules\.pnpm'
if (-not (Test-Path $profilesRoot)) {
    Write-Host "  [X] 找不到 pnpm 目录: $profilesRoot" -ForegroundColor Red
    exit 1
}

$patched = 0
$skipped = 0
$failed  = 0

# ---------------------------------------------------------------
# 补丁 1: dsh-app-boot —— HMR 服务作用域
# ---------------------------------------------------------------
Write-Host "  [1/2] dsh-app-boot (HMR 服务作用域)..."

$appBootDirs = Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like '@deepseek-ai+dsh-app-boot@*' }

if (-not $appBootDirs) {
    Write-Host "        未找到 dsh-app-boot，跳过" -ForegroundColor Yellow
}

foreach ($dir in $appBootDirs) {
    $file = Join-Path $dir.FullName 'node_modules\@deepseek-ai\dsh-app-boot\lib\index.js'
    if (-not (Test-Path $file)) { continue }

    try {
        $content = [System.IO.File]::ReadAllText($file)
    } catch {
        Write-Host "        [X] 读取失败: $($dir.Name)" -ForegroundColor Yellow
        $failed++
        continue
    }

    if ($content -match 'No HMR service reachable') {
        Write-Host "        已修补，跳过: $($dir.Name)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    $oldBlock = @'
async function watchUserPatches(ctx, options) {
	const { binName, filename, compose = (patches) => patches } = options;
	const hmr = ctx.get("hmr");
	if (hmr === void 0) throw new Error(`${binName}: user patch-layer watching requires the Cordis HMR service`);
	const entry = bootstrapIncludes.get(ctx);
'@

    $newBlock = @'
async function watchUserPatches(ctx, options) {
	const { binName, filename, compose = (patches) => patches } = options;
	let hmr = ctx.get("hmr");
	if (hmr === void 0) {
		// The HMR service may live in a child fiber scope rather than on the root
		// context (seen with cordis-plugin-hmr 1.0.17 on dsh 0.1.0-rc.8). Try the
		// scoped lookups before giving up, so patch-file hot reload still works.
		for (const scopeName of ["loader", "include"]) {
			try {
				const scope = ctx.get(scopeName);
				const scoped = scope !== void 0 && typeof scope.get === "function" ? scope.get("hmr") : void 0;
				if (scoped !== void 0) { hmr = scoped; break; }
			} catch {}
		}
	}
	if (hmr === void 0) {
		// No HMR service reachable: the profile still boots and the agent still
		// runs, only live patch reloading is unavailable. Returning a no-op
		// disposer keeps startup working instead of failing the whole profile.
		return async () => {};
	}
	const entry = bootstrapIncludes.get(ctx);
'@

    if ($content.Contains($oldBlock)) {
        Copy-Item $file "$file.bak" -Force -ErrorAction SilentlyContinue
        [System.IO.File]::WriteAllText($file, $content.Replace($oldBlock, $newBlock))
        Write-Host "        已修补: $($dir.Name)" -ForegroundColor Green
        $patched++
    } else {
        Write-Host "        [X] 未找到预期代码（版本可能不同）: $($dir.Name)" -ForegroundColor Yellow
        $failed++
    }
}

# ---------------------------------------------------------------
# 补丁 2: dsh-llm-deepseek —— 模型 id
# ---------------------------------------------------------------
Write-Host "  [2/2] dsh-llm-deepseek (模型 id)..."

$llmDirs = Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '@deepseek-ai+dsh-llm-deepse*' }

if (-not $llmDirs) {
    Write-Host "        未找到 dsh-llm-deepseek，跳过" -ForegroundColor Yellow
}

foreach ($dir in $llmDirs) {
    $file = Join-Path $dir.FullName 'node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js'
    if (-not (Test-Path $file)) { continue }

    try {
        $content = [System.IO.File]::ReadAllText($file)
    } catch {
        Write-Host "        [X] 读取失败: $($dir.Name)" -ForegroundColor Yellow
        $failed++
        continue
    }

    if ($content -notmatch '"deepseek-v4-flash"') {
        Write-Host "        已修补，跳过: $($dir.Name)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Copy-Item $file "$file.bak" -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($file, $content.Replace('"deepseek-v4-flash"', '"deepseek-flash"'))
    Write-Host "        已修补: $($dir.Name)" -ForegroundColor Green
    $patched++
}

Write-Host ""
Write-Host "  ===================================================="
$color = if ($failed -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "  完成：$patched 处新修补，$skipped 处已是最新，$failed 处失败" -ForegroundColor $color
Write-Host ""
Write-Host "  提示：pnpm store 用硬链接，同一文件常被多个路径共享，"
Write-Host "        所以补丁通常一次即可覆盖所有副本。"
Write-Host ""
Write-Host "  改完后请重启 bot。"
Write-Host ""

if ($failed -gt 0) { exit 1 }
exit 0
