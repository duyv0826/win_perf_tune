# 用法: 在脚本所在目录执行  powershell -ExecutionPolicy Bypass -File .\run_pester.ps1
# 退出码 = 失败用例数（0 表示全绿）。
# 运行 Pester 测试套件（确保加载用户目录下的 6.0.1，而非系统目录的 3.x）
# 仅“按需把用户模块目录前置”，不重建整条 PSModulePath —— 旧版重建逻辑在本机会误删用户目录导致 Import-Module 失败。
$userMods = "$HOME\Documents\WindowsPowerShell\Modules"
$dirs = $env:PSModulePath -split ';' | Where-Object { $_ }
if ($userMods -notin $dirs) { $env:PSModulePath = $userMods + ';' + $env:PSModulePath }
Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module Pester -RequiredVersion 6.0.1 -Force -ErrorAction Stop
Write-Host ("Active Pester: " + (Get-Module Pester).Version.ToString())
$r = Invoke-Pester -Path .\win_perf_tune.Tests.ps1 -PassThru
Write-Host ("`n===== SUMMARY: Passed={0} Failed={1} Skipped={2} =====" -f $r.PassedCount, $r.FailedCount, $r.SkippedCount)
exit $r.FailedCount
