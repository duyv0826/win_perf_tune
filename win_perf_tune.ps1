<#
.SYNOPSIS
    Windows 10/11 性能优化脚本（安全克制演示版，可测试）

.DESCRIPTION
    设计原则（与 Python 版 system_optimizer 一致：只读优先、写操作可控、可回滚、高危项默认关闭）：
      1) 创建系统还原点（回滚基线，并验证创建结果）
      2) 只读采集「优化前」指标
      3) 仅默认执行【安全】清理（临时文件 / 回收站 / DNS 缓存 / 更新组件）
      4) 【高危】项（禁用启动项 / 优化服务 / 调整虚拟内存）默认关闭，需显式 -ApplyRisky
      5) 采集「优化后」指标并输出对比表
    注：管理员环境下功能最完整（还原点 / DISM 需提权）；非管理员时相关步骤 try/catch 降级，
    仅告警不崩溃。脚本以函数组织，dot-source 加载不触发主流程，便于 Pester 测试。
    脚本以 UTF-8 with BOM 保存，避免 Windows PowerShell 5.1 按 GBK 误读中文。

.PARAMETER ApplyRisky
    启用高危优化（禁用启动项 / 服务优化 / 虚拟内存调整）。默认关闭。
.PARAMETER WhatIf
    预演模式：报告将要执行的操作，不实际修改任何内容。
.PARAMETER SkipRestorePoint
    跳过创建系统还原点（不推荐）。
#>
param(
    [switch]$ApplyRisky,
    [switch]$WhatIf,
    [switch]$SkipRestorePoint
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $tag = switch ($Level) { 'OK' { '[+]' } 'WARN' { '[!]' } 'ERR' { '[x]' } default { '[*]' } }
    Write-Host "$ts $tag $Msg"
}

# ---------- 权限与还原点 ----------

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 薄封装：将 Checkpoint-Computer 调用收敛到单一函数，便于在 Pester 中稳定 mock
# （Checkpoint-Computer 在本环境解析为 Alias，直接 mock 会被别名遮蔽而失效）。
function Invoke-CheckpointComputer {
    param([string]$Description)
    Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS
}

function New-RestorePoint {
    param([string]$Description)
    if ($WhatIf) { Write-Log "WhatIf: 将创建系统还原点：$Description"; return $true }
    try {
        Invoke-CheckpointComputer -Description $Description
        # 验证：查询最新还原点是否包含本次时间戳描述
        $stamp = Get-Date -Format yyyyMMddHHmm
        $latest = Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
            Sort-Object -Property CreationTime | Select-Object -Last 1
        if ($latest -and $latest.Description -like "*$stamp*") {
            Write-Log '还原点已创建并验证' 'OK'; return $true
        }
        Write-Log '还原点创建请求已提交（验证信息暂不可用）' 'OK'; return $true
    }
    catch {
        Write-Log "还原点创建失败：$_（请以管理员运行，或手动创建后继续）" 'WARN'
        return $false
    }
}

# ---------- 安全清理（均容错，单文件/单步骤失败不中断整体流程） ----------

function Clear-DnsCache {
    if ($WhatIf) { Write-Log 'WhatIf: 将刷新 DNS 缓存'; return }
    try { ipconfig /flushdns | Out-Null; Write-Log 'DNS 缓存已刷新' 'OK' }
    catch { Write-Log "DNS 刷新失败：$_" 'WARN' }
}

function Clear-TempFiles {
    $items = Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue
    $cnt = 0; $skipped = 0
    foreach ($it in $items) {
        if ($WhatIf) { $cnt++; continue }
        try {
            Remove-Item $it.FullName -Recurse -Force -ErrorAction Stop
            $cnt++
        }
        catch {
            # 文件被占用 / 无权限（常见于正在运行的程序），跳过该项
            $skipped++
        }
    }
    Write-Log ("已清理临时文件约 {0} 项（跳过 {1} 项被占用/无权限）" -f $cnt, $skipped) 'OK'
    return @{ Cleaned = $cnt; Skipped = $skipped }
}

function Clear-RecycleBinSafe {
    if ($WhatIf) { Write-Log 'WhatIf: 将清空回收站'; return }
    try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log '回收站已清空' 'OK' }
    catch { Write-Log "回收站清空跳过（可能为空或无权限）：$_" 'WARN' }
}

function Invoke-DismCleanup {
    if ($WhatIf) { Write-Log 'WhatIf: 将执行 DISM 清理'; return }
    try { DISM /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null; Write-Log '更新组件清理完成' 'OK' }
    catch { Write-Log "更新组件清理跳过（需管理员或无需清理）：$_" 'WARN' }
}

# ---------- 指标采集（只读） ----------

function Get-Snapshot {
    try {
        $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop).CounterSamples.CookedValue
    }
    catch { $cpu = 0 }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $memUsedGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
        $memTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    }
    catch { $memUsedGB = 0; $memTotalGB = 0 }
    try { $disk = Get-PSDrive C -ErrorAction Stop } catch { $disk = $null }
    $diskFree = if ($disk) { [math]::Round($disk.Free / 1GB, 2) } else { 0 }
    $dns = try { (Get-DnsClientCache -ErrorAction SilentlyContinue | Measure-Object).Count } catch { 0 }
    $startup = try { (Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Measure-Object).Count } catch { 0 }
    $svc = try { (Get-Service | Where-Object { $_.Status -eq 'Running' } | Measure-Object).Count } catch { 0 }
    [PSCustomObject]@{
        CPU_percent      = [math]::Round($cpu, 1)
        MemUsed_GB       = $memUsedGB
        MemTotal_GB      = $memTotalGB
        DiskFree_GB      = $diskFree
        DNSCache_entries = $dns
        StartupItems     = $startup
        RunningServices  = $svc
    }
}

# ---------- 对比表 ----------

function Show-Comparison($before, $after) {
    Write-Host "`n========== 优化前后性能对比 =========="
    $rows = @(
        @{ 指标 = 'CPU 占用率(%)'; 前 = $before.CPU_percent;      后 = $after.CPU_percent;       说明 = '随负载波动，非优化直接收益' }
        @{ 指标 = '内存已用(GB)';  前 = $before.MemUsed_GB;       后 = $after.MemUsed_GB;        说明 = '清理后可能略降' }
        @{ 指标 = '内存总量(GB)';  前 = $before.MemTotal_GB;      后 = $after.MemTotal_GB;       说明 = '不变' }
        @{ 指标 = 'C盘剩余(GB)';   前 = $before.DiskFree_GB;      后 = $after.DiskFree_GB;       说明 = '临时/更新清理后上升' }
        @{ 指标 = 'DNS缓存条目';   前 = $before.DNSCache_entries; 后 = $after.DNSCache_entries;   说明 = 'flushdns 已执行；缓存随后被网络活动重新填充' }
        @{ 指标 = '启动项数量';    前 = $before.StartupItems;     后 = $after.StartupItems;      说明 = '仅 -ApplyRisky 时变化' }
        @{ 指标 = '运行服务数';    前 = $before.RunningServices;  后 = $after.RunningServices;   说明 = '仅 -ApplyRisky 时变化' }
    )
    foreach ($r in $rows) {
        Write-Host ('{0,-14} {1,10} -> {2,10}  | {3}' -f $r.指标, $r.前, $r.后, $r.说明)
    }
    Write-Host '========================================='
}

# ---------- 高危项（默认关闭） ----------

function Invoke-RiskyOptimization {
    Write-Log '*** 高危优化已启用（请确认已创建还原点）***' 'WARN'
    # 启动项：仅评估并提示，需人工核对白名单后才真正禁用
    Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '过时工具|冗余' } |
        ForEach-Object { Write-Log ("  [待人工确认] 将禁用：{0}" -f $_.Name) 'WARN' }
    # 服务：仅把明确可延迟的非关键服务设为 Manual，绝不 Disable 关键服务
    $candidates = @('DiagTrack', 'SysMain')
    foreach ($s in $candidates) {
        if (Get-Service $s -ErrorAction SilentlyContinue) {
            try { Set-Service $s -StartupType Manual; Write-Log ("  服务 {0} -> Manual" -f $s) 'WARN' }
            catch { Write-Log ("  服务 {0} 调整失败：{1}" -f $s, $_) 'WARN' }
        }
    }
    Write-Log '虚拟内存调整：默认不执行（高风险，建议人工在「高级系统设置」中操作）' 'WARN'
}

# ---------- 主流程 ----------

function Start-CleanupFlow {
    $isAdmin = Test-IsAdmin
    if (-not $isAdmin) {
        Write-Log '当前非管理员会话：还原点 / DISM 等需提权步骤将跳过或告警，其余清理照常。' 'WARN'
    }

    if (-not $SkipRestorePoint) {
        Write-Log '创建系统还原点（回滚基线）...'
        $null = New-RestorePoint -Description "win_perf_tune_$(Get-Date -Format yyyyMMddHHmm)"
    }

    Write-Log '采集「优化前」指标...'
    $before = Get-Snapshot

    Write-Log '执行安全清理（删除前建议确认；可用 -WhatIf 预演）...'
    Clear-DnsCache
    Write-Log "清理用户临时目录 $env:TEMP ..."
    $null = Clear-TempFiles
    Clear-RecycleBinSafe
    Invoke-DismCleanup

    if ($ApplyRisky) { Invoke-RiskyOptimization }
    else { Write-Log '高危优化（启动项/服务/虚拟内存）已跳过（默认安全）。需要时加 -ApplyRisky。' }

    Write-Log '采集「优化后」指标...'
    $after = Get-Snapshot
    Show-Comparison $before $after
    Write-Log '完成。如有异常，可用系统还原点回滚。' 'OK'
}

# 仅当「直接以 powershell -File 运行」时执行主流程：
#   - 被 Pester 测试 dot-source 加载前会设置 $env:WPT_TEST='1'，此时只定义函数不触发清理；
#   - 直接 -File 运行（WPT_TEST 未设置）才执行并显式 exit 0，避免泄漏原生命令退出码（如 740）。
if ($env:WPT_TEST -ne '1') {
    Start-CleanupFlow
    exit 0
}
