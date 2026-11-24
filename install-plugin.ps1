# install-plugin.ps1 —— 在 DSH desktop profile 里安装/升级插件，处理已知坑，最后自动重打外挂补丁。
#
# 已知坑（本脚本都已处理）:
#   1. ~/.npmrc 里配了 127.0.0.1:31180/31181 代理，代理软件没开时 pnpm 全部 ECONNREFUSED
#      → 脚本用临时 npmrc（npmmirror 直连）覆盖，不改你的全局配置。
#   2. dsh-diff-review 只存在于 GitHub、不在任何 npm registry，pnpm 重新解析它会 404
#      → 脚本先备份它的模块目录、临时从 package.json 摘除，装完原样还原。
#   3. 装完/升完后 client.js 会变回原版 → 脚本最后自动调用 apply-patch.ps1 重打补丁。
#
# 用法:
#   powershell -File install-plugin.ps1                          # 装/升级 explorer-open 到最新
#   powershell -File install-plugin.ps1 -Name <pkg> -Version <v> # 指定包名/版本
#   powershell -File install-plugin.ps1 -ProfileDir <dir>        # 目标不是默认的 desktop profile
param(
  [string]$Name = '@reed-io/dsh-explorer-open',
  [string]$Version = '',
  [string]$ProfileDir = '',
  [string]$Node = '',
  [string]$Pnpm = ''
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileDir = if ($ProfileDir -ne '') { $ProfileDir }
  elseif ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR }
  else { Join-Path $env:USERPROFILE '.dsh\profiles\desktop' }

# DSH 自带的 node/pnpm：优先命令行参数，否则在 dsh-runtimes 下挑一个装了 node 的运行时
if ($Node -eq '' -or $Pnpm -eq '') {
  $runtimeRoot = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
  $runtime = Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'dependencies\node\bin\node.exe') } |
    Sort-Object LastWriteTime | Select-Object -Last 1
  if ($runtime) {
    if ($Node -eq '') { $Node = Join-Path $runtime.FullName 'dependencies\node\bin\node.exe' }
    if ($Pnpm -eq '') { $Pnpm = Join-Path $runtime.FullName 'dependencies\pnpm\bin\pnpm.cjs' }
  }
}
$pkgJsonPath = Join-Path $profileDir 'package.json'

if (-not (Test-Path -LiteralPath $profileDir)) { Write-Host "[ERR] profile 目录不存在: $profileDir"; exit 1 }
if (-not (Test-Path -LiteralPath $Node)) { Write-Host "[ERR] 找不到自带 node: $Node"; Write-Host '      用 -Node 指定，或先启动一次 dsh 让它准备好运行时'; exit 1 }
if (-not (Test-Path -LiteralPath $Pnpm)) { Write-Host "[ERR] 找不到自带 pnpm: $Pnpm"; Write-Host '      用 -Pnpm 指定'; exit 1 }

$spec = if ($Version -ne '') { "$Name@$Version" } else { $Name }

function Read-Pkg { [System.IO.File]::ReadAllText($pkgJsonPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }
function Write-Pkg($pkg) {
  Write-Utf8Raw $pkgJsonPath (($pkg | ConvertTo-Json -Depth 10) + "`n")
}
function Write-Utf8Raw([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

# 1) 绕开死代理：临时 npmrc（不改全局 ~/.npmrc）
$npmrc = Join-Path $env:TEMP 'dsh-plugin-install.npmrc'
Write-Utf8Raw $npmrc "registry=https://registry.npmmirror.com/`nstrict-ssl=false`n"
$env:npm_config_userconfig = $npmrc
$env:npm_config_proxy = ''
$env:npm_config_https_proxy = ''

# 2) 摘除 dsh-diff-review（GitHub 专属包，registry 404），失败也保证还原
$diffDir = Join-Path $profileDir 'node_modules\dsh-diff-review'
$diffBak = Join-Path $profileDir 'dsh-diff-review-backup'
$pkg = Read-Pkg
$hadDiff = $null -ne $pkg.dependencies.PSObject.Properties['dsh-diff-review']
if ($hadDiff) {
  if (Test-Path -LiteralPath $diffDir) {
    if (Test-Path -LiteralPath $diffBak) { Remove-Item -LiteralPath $diffBak -Recurse -Force }
    Copy-Item -LiteralPath $diffDir -Destination $diffBak -Recurse -Force
  }
  $deps = [ordered]@{}
  foreach ($k in $pkg.dependencies.PSObject.Properties.Name) {
    if ($k -ne 'dsh-diff-review') { $deps[$k] = $pkg.dependencies.$k }
  }
  $pkg.dependencies = [pscustomobject]$deps
  Write-Pkg $pkg
}

$code = -1
try {
  Push-Location $profileDir
  try {
    & $node $pnpm add $spec
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
  }
}
finally {
  # 3) 还原 dsh-diff-review：package.json 条目 + 模块目录
  if ($hadDiff) {
    $pkg = Read-Pkg
    $deps = [ordered]@{}
    foreach ($k in $pkg.dependencies.PSObject.Properties.Name) { $deps[$k] = $pkg.dependencies.$k }
    if (-not $deps.Contains('dsh-diff-review')) { $deps['dsh-diff-review'] = '1.0.6' }
    $pkg.dependencies = [pscustomobject]$deps
    Write-Pkg $pkg
    if (-not (Test-Path -LiteralPath $diffDir)) {
      $ignored = Join-Path $profileDir 'node_modules\.ignored\dsh-diff-review'
      if (Test-Path -LiteralPath $ignored) { Move-Item -LiteralPath $ignored -Destination $diffDir }
      elseif (Test-Path -LiteralPath $diffBak) { Copy-Item -LiteralPath $diffBak -Destination $diffDir -Recurse }
    }
    if (Test-Path -LiteralPath $diffBak) { Remove-Item -LiteralPath $diffBak -Recurse -Force }
  }
}

if ($code -ne 0) {
  Write-Host "[ERR] pnpm add 失败 (exit $code)"
  exit $code
}

# 4) 确保 bundle 挂进启动列表（dsh.profile.bundles）
$pkg = Read-Pkg
$bundles = @($pkg.dsh.profile.bundles)
if ($bundles -notcontains $Name) {
  $pkg.dsh.profile.bundles = @($bundles + $Name)
  Write-Pkg $pkg
  Write-Host "[OK] 已把 $Name 加入 dsh.profile.bundles"
}

# 5) 重打外挂补丁（升级后 client.js 会变回原版）
& (Join-Path $here 'apply-patch.ps1')
$patchCode = $LASTEXITCODE
if ($patchCode -eq 3) {
  Write-Host ''
  Write-Host '[WARN] 插件大改了 handle()，需要人工合并补丁（见 apply-patch.ps1 输出的步骤）'
}
Write-Host ''
Write-Host '完成。重启 DeepSeek Harness 并刷新页面后生效。'
exit $patchCode
