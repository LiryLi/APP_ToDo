# sync_to_github.ps1 — APP_ToDo 每晚自动同步脚本
# 供定时任务调用：提交所有变更并推送到 GitHub main 分支
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath "E:\APP_桌面TODO\project"

git add -A
$status = git status --porcelain
if ($status) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
    git commit -m "auto sync $ts"
}

# 远端有新提交时先变基，再推送
git pull --rebase origin main
git push origin main

if ($LASTEXITCODE -eq 0) { "sync ok: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" } else { "sync FAILED: $LASTEXITCODE"; exit 1 }
