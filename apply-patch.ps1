# apply-patch.ps1 —— 把外挂补丁重新打到 @reed-io/dsh-explorer-open 的 client.js 上。
# 幂等：已打过则直接退出；插件升级后（原版锚点还在）自动备份并重新打上。
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
$target = Join-Path $pluginDir 'client.js'
$patchedSrc = Join-Path $here 'patched-client.js'
$marker = '[patch:jump-to-latest]'
# 原版 client.js 里 handle() 的特征注释——新版插件若改了这段逻辑，锚点会消失
$anchor = '不关心有没有旧会话：每次都新建一个'

function Read-Utf8([string]$path) {
  [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
}
function Write-Utf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path -LiteralPath $target)) {
  Write-Host "[ERR] 未找到已安装的 client.js: $target"
  Write-Host '      插件还没装？先运行 install-plugin.ps1'
  exit 1
}

$current = Read-Utf8 $target

if ($Revert) {
  # 优先用打补丁前自动生成的带时间戳备份；仓库里没有这类备份时退回 original-client.js 基线
  $bak = Get-ChildItem -LiteralPath $here -Filter 'original-client.*.js' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
  $pinned = $false
  if (-not $bak) {
    $bak = Get-Item -LiteralPath (Join-Path $here 'original-client.js') -ErrorAction SilentlyContinue
    $pinned = $null -ne $bak
  }
  if (-not $bak) { Write-Host '[ERR] 没有可还原的备份'; exit 1 }
  Copy-Item -LiteralPath $bak.FullName -Destination $target -Force
  Write-Host "[OK] 已从 $($bak.Name) 还原（记得刷新页面）"
  if ($pinned) {
    Write-Host '     注意：这是仓库归档的 0.1.6 原版；若已装插件版本不同，还原后请重新安装对应版本。'
  }
  exit 0
}

if ($current.Contains($marker)) {
  Write-Host '[OK] 补丁已在位，无需处理'
  exit 0
}

if ($Check) {
  Write-Host '[WARN] 补丁未打上（运行本脚本不带参数即可打上）'
  exit 2
}

if (-not $current.Contains($anchor)) {
  Write-Host '[ERR] 未找到原版锚点代码 —— 插件已升级且 handle() 逻辑变了。'
  Write-Host '      处理步骤：'
  Write-Host '        1. 对比 original-client.js（旧原版）与当前 client.js（新原版）'
  Write-Host '        2. 把新原版里对应的改动合并进 patched-client.js，保留 [patch:jump-to-latest] 标记'
  Write-Host '        3. 重跑本脚本'
  exit 3
}

if (-not (Test-Path -LiteralPath $patchedSrc)) {
  Write-Host "[ERR] 缺少补丁源文件: $patchedSrc"
  exit 4
}

# 打补丁前备份当前（未打补丁的）版本，文件名带插件版本与时间戳
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$version = ''
try { $version = ([System.IO.File]::ReadAllText((Join-Path $pluginDir 'package.json'), [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).version } catch { }
$bakName = "original-client.$version.$stamp.js"
$bakPath = Join-Path $here $bakName
Copy-Item -LiteralPath $target -Destination $bakPath
# Copy-Item 会保留源文件的时间戳，而 -Revert 是按备份时间取最新的一份，这里显式改成现在
(Get-Item -LiteralPath $bakPath).LastWriteTime = Get-Date

Write-Utf8 $target (Read-Utf8 $patchedSrc)

$after = Read-Utf8 $target
if (-not $after.Contains($marker)) {
  Copy-Item -LiteralPath (Join-Path $here $bakName) -Destination $target -Force
  Write-Host '[ERR] 写入校验失败，已回滚'
  exit 5
}

Write-Host "[OK] 补丁已应用（插件 $version，备份 $bakName）"
Write-Host '     重启 DeepSeek Harness 并刷新页面后生效。'
exit 0
