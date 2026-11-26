# apply-patch.ps1 —— 给 @reed-io/dsh-explorer-open 打上本仓库的外挂补丁。
#
# 当前两处补丁：
#   1. client.js         右键打开工程时续接最近会话                        [patch:jump-to-latest]
#   2. lib/registry.js   菜单改经 wscript 转发，点菜单不再闪 PowerShell 窗口  [patch:hidden-console]
#
# 幂等：已打过则直接跳过；插件升级后（原版锚点还在）自动备份并重新打上。
#
# 用法:
#   powershell -File apply-patch.ps1           # 检查并打补丁（推荐每次升级插件/DSH 后运行）
#   powershell -File apply-patch.ps1 -Check    # 只检查状态不修改: 0=已打 2=未打 3=锚点丢失
#   powershell -File apply-patch.ps1 -Revert   # 还原到最近一次打补丁前的备份
#   powershell -File apply-patch.ps1 -ProfileDir <dir>   # 目标不是默认的 desktop profile
param(
  [switch]$Check,
  [switch]$Revert,
  [string]$ProfileDir = ''
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# 插件装在哪个 profile：-ProfileDir > 环境变量 DSH_PROFILE_DIR > 默认 desktop
$profileDir = if ($ProfileDir -ne '') { $ProfileDir }
  elseif ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR }
  else { Join-Path $env:USERPROFILE '.dsh\profiles\desktop' }
$pluginDir = Join-Path $profileDir 'node_modules\@reed-io\dsh-explorer-open'
# 启动器、菜单图标、config.json 的固定位置；插件每次启动都会把 launch.ps1 同步到这里
$stateDir = Join-Path $env:USERPROFILE '.dsh\dsh-explorer-open'

function Read-Utf8([string]$path) {
  [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
}
function Write-Utf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

# 每处补丁：显示名、目标文件、仓库里的补丁版、判定标记、升级后仍应存在的原版锚点
$patches = @(
  @{
    Name   = 'client.js（续接最近会话）'
    Stem   = 'client'
    Target = Join-Path $pluginDir 'client.js'
    Source = Join-Path $here 'patched-client.js'
    Marker = '[patch:jump-to-latest]'
    Anchor = '不关心有没有旧会话：每次都新建一个'
  },
  @{
    Name   = 'lib/registry.js（不闪窗口）'
    Stem   = 'registry'
    Target = Join-Path $pluginDir 'lib\registry.js'
    Source = Join-Path $here 'patched-registry.js'
    Marker = '[patch:hidden-console]'
    Anchor = 'return `"${POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "${scriptPath}" "%V"`'
  }
)

# 菜单命令：补丁版经 wscript 无窗口转发，原版直接调 powershell
$cmdPatched = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + (Join-Path $stateDir 'launch.vbs') + '" "%V"'
$cmdPristine = '"' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') +
  '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $stateDir 'launch.ps1') + '" "%V"'

# 旧式菜单的三个挂载点；只改已经存在的键，不凭空创建菜单项
$shellKeys = @(
  'Software\Classes\Directory\Background\shell\OpenWithDsh\command',
  'Software\Classes\Directory\shell\OpenWithDsh\command',
  'Software\Classes\*\shell\OpenWithDsh\command'
)

function Set-MenuCommand([string]$value) {
  $changed = 0
  foreach ($sub in $shellKeys) {
    $key = $null
    try {
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
      if ($null -eq $key) { continue }
      $key.SetValue('', $value, [Microsoft.Win32.RegistryValueKind]::String)
      $changed++
    } finally {
      if ($null -ne $key) { $key.Close() }
    }
  }
  return $changed
}

$version = ''
try {
  $version = ([System.IO.File]::ReadAllText((Join-Path $pluginDir 'package.json'), [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).version
} catch { }

foreach ($p in $patches) {
  if (-not (Test-Path -LiteralPath $p.Target)) {
    Write-Host "[ERR] 未找到安装的 $($p.Name): $($p.Target)"
    Write-Host '      插件还没装？先运行 install-plugin.ps1'
    exit 1
  }
}

$vbsSource = Join-Path $here 'launch.vbs'
$vbsTarget = Join-Path $stateDir 'launch.vbs'

if ($Revert) {
  foreach ($p in $patches) {
    # 优先用打补丁前自动生成的带时间戳备份；没有时退回仓库归档的上游原版
    $bak = Get-ChildItem -LiteralPath $here -Filter "original-$($p.Stem).*.js" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime | Select-Object -Last 1
    $pinned = $false
    if (-not $bak) {
      $bak = Get-Item -LiteralPath (Join-Path $here "original-$($p.Stem).js") -ErrorAction SilentlyContinue
      $pinned = $null -ne $bak
    }
    if (-not $bak) { Write-Host "[ERR] $($p.Name) 没有可还原的备份"; exit 1 }
    Copy-Item -LiteralPath $bak.FullName -Destination $p.Target -Force
    Write-Host "[OK] $($p.Name) 已从 $($bak.Name) 还原"
    if ($pinned) {
      Write-Host '     注意：这是仓库归档的上游原版；若已装插件版本不同，还原后请重新安装对应版本。'
    }
  }
  Remove-Item -LiteralPath $vbsTarget -Force -ErrorAction SilentlyContinue
  [void](Set-MenuCommand $cmdPristine)
  Write-Host '[OK] 菜单命令已改回直接调用 powershell（记得重启 DSH）'
  exit 0
}

$status = 0
if (-not (Test-Path -LiteralPath $vbsTarget)) { $status = 2 }
foreach ($p in $patches) {
  $current = Read-Utf8 $p.Target
  if ($current.Contains($p.Marker)) { continue }
  if ($current.Contains($p.Anchor)) {
    $status = 2
    Write-Host "[WARN] $($p.Name) 补丁未打上"
  } else {
    Write-Host "[ERR] $($p.Name) 找不到原版锚点 —— 插件已升级且相关代码变了。"
    Write-Host '      处理步骤：'
    Write-Host "        1. 对比 original-$($p.Stem).js（旧原版）与当前安装的对应文件"
    Write-Host "        2. 把差异合进 patched-$($p.Stem).js，保留 $($p.Marker) 标记"
    Write-Host '        3. 重跑本脚本'
    exit 3
  }
}

if ($Check) {
  if ($status -eq 0) { Write-Host '[OK] 补丁都已在位，无需处理' }
  else { Write-Host '[WARN] 有补丁未打上（不带参数运行本脚本即可打上）' }
  exit $status
}

# 1) 无窗口启动器：必须和 launch.ps1 放在同一目录
if (-not (Test-Path -LiteralPath $vbsSource)) {
  Write-Host "[ERR] 缺少补丁文件: $vbsSource"
  exit 4
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$needVbs = -not (Test-Path -LiteralPath $vbsTarget)
if (-not $needVbs) {
  $needVbs = (Get-FileHash -LiteralPath $vbsTarget).Hash -ne (Get-FileHash -LiteralPath $vbsSource).Hash
}
if ($needVbs) {
  Copy-Item -LiteralPath $vbsSource -Destination $vbsTarget -Force
  Write-Host '[OK] 已放置无窗口启动器 launch.vbs'
}

# 2) 逐个文件打补丁，写前先备份，写完再校验，失败自动回滚
foreach ($p in $patches) {
  $current = Read-Utf8 $p.Target
  if ($current.Contains($p.Marker)) {
    Write-Host "[OK] $($p.Name) 已在位"
    continue
  }
  if (-not (Test-Path -LiteralPath $p.Source)) {
    Write-Host "[ERR] 缺少补丁源文件: $($p.Source)"
    exit 4
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bakName = "original-$($p.Stem).$version.$stamp.js"
  $bakPath = Join-Path $here $bakName
  Copy-Item -LiteralPath $p.Target -Destination $bakPath
  # Copy-Item 会保留源文件时间戳，而 -Revert 按备份时间取最新一份，这里显式改成现在
  (Get-Item -LiteralPath $bakPath).LastWriteTime = Get-Date

  Write-Utf8 $p.Target (Read-Utf8 $p.Source)

  $after = Read-Utf8 $p.Target
  if (-not $after.Contains($p.Marker)) {
    Copy-Item -LiteralPath $bakPath -Destination $p.Target -Force
    Write-Host "[ERR] $($p.Name) 写入校验失败，已回滚"
    exit 5
  }
  Write-Host "[OK] $($p.Name) 已打上（插件 $version，备份 $bakName）"
}

# 3) 菜单命令立刻切到 wscript，不用等下次启动 DSH 才更新注册表
$changed = Set-MenuCommand $cmdPatched
if ($changed -gt 0) { Write-Host "[OK] 已更新 $changed 处右键菜单命令" }

Write-Host ''
Write-Host '完成。重启 DeepSeek Harness 并刷新页面后生效。'
exit 0
