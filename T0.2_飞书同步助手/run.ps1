# run.ps1 - T0.2 飞书同步助手 启动/停止
# 用法:  .\run.ps1           后台启动守护进程
#        .\run.ps1 -Foreground 前台运行(调试, 可直接看日志)
#        .\run.ps1 -Stop       停止守护进程
param([switch]$Foreground, [switch]$Stop)

$dir = $PSScriptRoot
$daemon = Join-Path $dir 'daemon.py'

if ($Stop) {
    $found = Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'daemon\.py' }
    foreach ($proc in $found) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }
    }
    if ($found) { "已停止 $($found.Count) 个守护进程" } else { '没有在运行的守护进程' }
    exit 0
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host '未找到 python，请先安装 Python 3（勾选 Add to PATH）'
    exit 1
}

# 首次运行自动安装依赖
python -m pip install --quiet lark-oapi

$cfg = Join-Path $dir 'config.json'
if (-not (Test-Path -LiteralPath $cfg)) {
    Write-Host '缺少 config.json'
    exit 1
}
$rawCfg = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
if ($rawCfg -match 'xxxx|粘贴') {
    Write-Host 'config.json 里的 app_id / app_secret 还没填，请先按 说明.md 完成应用创建。'
    exit 1
}

$py = (Get-Command python).Source
if (-not $py) { $py = 'python' }

if ($Foreground) {
    & $py $daemon
}
else {
    Start-Process -WindowStyle Hidden -FilePath $py -ArgumentList ('"{0}"' -f $daemon) -WorkingDirectory $dir
    Start-Sleep -Seconds 2
    Write-Host '守护进程已后台启动。日志: daemon.log；停止: .\run.ps1 -Stop'
}
