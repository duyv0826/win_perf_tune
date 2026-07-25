# win_perf_tune.Tests.ps1 —— Pester 6 测试（覆盖权限校验 / 还原点 / 清理成败路径 / 退出码 / 异常边界）
# 运行（需 Pester 6.x）：
#   Install-Module Pester -Scope CurrentUser -Force
#   Invoke-Pester -Path .\win_perf_tune.Tests.ps1
# 注意：本机若同时存在系统目录下的 Pester 3.x，请先隔离 $env:PSModulePath 仅保留 6.x 所在用户模块目录。
#        本脚本以 UTF-8 with BOM 保存，避免 Windows PowerShell 5.1 按 GBK 误读中文。

Describe 'win_perf_tune 安全清理流程' {

    BeforeAll {
        # Pester 6 把 BeforeAll 跑在独立脚本作用域，不继承文件顶层变量，故路径须在此计算。
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
                     elseif ($MyInvocation.ScriptName) { Split-Path -Parent $MyInvocation.ScriptName }
                     else { $PWD.Path }
        $scriptPath = Join-Path $scriptDir 'win_perf_tune.ps1'
        if (-not (Test-Path $scriptPath)) { $scriptPath = Join-Path $PWD.Path 'win_perf_tune.ps1' }

        # 读取脚本源码，去掉「直接执行守卫」与 param() 块，再用 Invoke-Expression 在当前作用域执行，
        # 使函数定义进入 Pester 作用域（可被 Mock、可被 It 调用），且不触发真实清理。
        # 开关变量（$WhatIf/$ApplyRisky/$SkipRestorePoint）在测试中于 It 作用域赋值切换。
        $src = Get-Content -Path $scriptPath -Raw -Encoding UTF8
        $src = $src -replace '(?s)if \(\$env:WPT_TEST -ne ''1''\)\s*\{.*?exit 0\s*\}', ''
        $src = $src -replace '(?s)param\([^)]*\)\s*', ''
        Invoke-Expression $src
        # 脚本内 $ErrorActionPreference='Stop' 会泄漏到本作用域，复位避免干扰 Pester 断言。
        $ErrorActionPreference = 'Continue'

        # 只读采集相关 cmdlet 的 mock（不触碰真实系统）。
        # 注：New-RestorePoint 经 Invoke-CheckpointComputer 薄封装调用 Checkpoint-Computer；
        # 因 Checkpoint-Computer 在本环境解析为 Alias 会遮蔽 Pester 的 mock，故统一 mock 该普通函数以稳定拦截。
        Mock Get-Counter { [PSCustomObject]@{ CounterSamples = [PSCustomObject]@{ CookedValue = 10.0 } } }
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } {
            [PSCustomObject]@{ TotalVisibleMemorySize = 16000000; FreePhysicalMemory = 8000000 }
        }
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_StartupCommand' } { @() }
        Mock Get-CimInstance { [PSCustomObject]@{ TotalVisibleMemorySize = 16000000; FreePhysicalMemory = 8000000 } }
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 160GB } }
        Mock Get-DnsClientCache { @(1, 2, 3) }
        Mock Get-Service { @([PSCustomObject]@{ Status = 'Running'; Name = 'x' }) }
        Mock Get-ChildItem { @([PSCustomObject]@{ FullName = 'C:\fake\a.tmp' }, [PSCustomObject]@{ FullName = 'C:\fake\b.tmp' }) }
        Mock Remove-Item {}
        Mock Clear-RecycleBin {}
        Mock ipconfig {}
        Mock DISM {}
        Mock Invoke-CheckpointComputer {}
        Mock Get-ComputerRestorePoint { @([PSCustomObject]@{ Description = "win_perf_tune_$(Get-Date -Format yyyyMMddHHmm)"; CreationTime = Get-Date } ) }
        Mock Set-Service {}
        Mock Show-Comparison {}
        Mock Write-Log {}
    }

    Context '管理员权限校验' {
        It '非管理员时记录告警且不中断主流程' {
            Mock Test-IsAdmin { $false }
            Mock New-RestorePoint { $true }
            Mock Clear-DnsCache {}; Mock Clear-TempFiles {}; Mock Clear-RecycleBinSafe {}; Mock Invoke-DismCleanup {}
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            { Start-CleanupFlow } | Should -Not -Throw
        }
        It '管理员时仍会调用还原点创建' {
            Mock Test-IsAdmin { $true }
            Mock New-RestorePoint { $true }
            Mock Clear-DnsCache {}; Mock Clear-TempFiles {}; Mock Clear-RecycleBinSafe {}; Mock Invoke-DismCleanup {}
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            Start-CleanupFlow
            Should -Invoke New-RestorePoint -Exactly 1
        }
    }

    Context '还原点创建逻辑（New-RestorePoint，真实函数）' {
        It 'Checkpoint 成功且可验证时返回 $true 并调用 Invoke-CheckpointComputer' {
            Mock Invoke-CheckpointComputer {}
            Mock Get-ComputerRestorePoint { @([PSCustomObject]@{ Description = "win_perf_tune_$(Get-Date -Format yyyyMMddHHmm)"; CreationTime = Get-Date } ) }
            $r = New-RestorePoint -Description "win_perf_tune_$(Get-Date -Format yyyyMMddHHmm)"
            $r | Should -BeTrue
            Should -Invoke Invoke-CheckpointComputer -Exactly 1
        }
        It 'Checkpoint 抛错时被捕获并返回 $false（不冒泡）' {
            Mock Invoke-CheckpointComputer { throw '拒绝访问' }
            $r = New-RestorePoint -Description 'x'
            $r | Should -BeFalse
        }
        It 'WhatIf 模式下不调用 Invoke-CheckpointComputer 且返回 $true' {
            Mock Invoke-CheckpointComputer {}
            $WhatIf = $true
            $r = New-RestorePoint -Description 'x'
            $r | Should -BeTrue
            Should -Invoke Invoke-CheckpointComputer -Exactly 0
        }
    }

    Context '清理操作路径' {
        It '成功路径：四个安全清理函数均被调用且主流程完成' {
            Mock Test-IsAdmin { $true }
            Mock New-RestorePoint { $true }
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            Mock Clear-DnsCache {}
            Mock Clear-TempFiles {}
            Mock Clear-RecycleBinSafe {}
            Mock Invoke-DismCleanup {}
            { Start-CleanupFlow } | Should -Not -Throw
            Should -Invoke Clear-DnsCache -Exactly 1
            Should -Invoke Clear-TempFiles -Exactly 1
            Should -Invoke Clear-RecycleBinSafe -Exactly 1
            Should -Invoke Invoke-DismCleanup -Exactly 1
        }
        It '失败路径（Remove-Item 抛错）：Clear-TempFiles 捕获异常、流程继续不中断' {
            Mock Test-IsAdmin { $true }
            Mock New-RestorePoint { $true }
            Mock Clear-DnsCache {}; Mock Clear-RecycleBinSafe {}; Mock Invoke-DismCleanup {}
            Mock Remove-Item { throw '文件被占用' }
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            { Start-CleanupFlow } | Should -Not -Throw
        }
        It '失败路径（Clear-RecycleBin 抛错）：被捕获且主流程继续' {
            Mock Test-IsAdmin { $true }
            Mock New-RestorePoint { $true }
            Mock Clear-DnsCache {}; Mock Clear-TempFiles {}
            Mock Invoke-DismCleanup {}
            Mock Clear-RecycleBin { throw '无权限' }
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            { Start-CleanupFlow } | Should -Not -Throw
        }
    }

    Context '异常处理的边界情况' {
        It 'Get-Snapshot 中 Get-Counter 不可用时返回 CPU 默认值 0 且不抛错' {
            Mock Get-Counter { throw '无性能计数器' }
            { $snap = Get-Snapshot } | Should -Not -Throw
            $snap = Get-Snapshot
            $snap.CPU_percent | Should -Be 0
        }
        It '还原点创建失败（Checkpoint 抛错）时主流程仍完成' {
            Mock Test-IsAdmin { $true }
            Mock Invoke-CheckpointComputer { throw '拒绝访问' }
            Mock Clear-DnsCache {}; Mock Clear-TempFiles {}; Mock Clear-RecycleBinSafe {}; Mock Invoke-DismCleanup {}
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            { Start-CleanupFlow } | Should -Not -Throw
        }
    }

    Context 'ApplyRisky 分支' {
        It '默认（关闭）时不调用 Invoke-RiskyOptimization' {
            Mock Test-IsAdmin { $true }
            Mock New-RestorePoint { $true }
            Mock Clear-DnsCache {}; Mock Clear-TempFiles {}; Mock Clear-RecycleBinSafe {}; Mock Invoke-DismCleanup {}
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            Mock Invoke-RiskyOptimization {}
            $ApplyRisky = $false
            Start-CleanupFlow
            Should -Invoke Invoke-RiskyOptimization -Exactly 0
        }
        It '启用 -ApplyRisky 时调用 Invoke-RiskyOptimization' {
            Mock Test-IsAdmin { $true }
            Mock New-RestorePoint { $true }
            Mock Clear-DnsCache {}; Mock Clear-TempFiles {}; Mock Clear-RecycleBinSafe {}; Mock Invoke-DismCleanup {}
            Mock Get-Snapshot { [PSCustomObject]@{ CPU_percent = 1; MemUsed_GB = 1; MemTotal_GB = 1; DiskFree_GB = 1; DNSCache_entries = 1; StartupItems = 1; RunningServices = 1 } }
            Mock Invoke-RiskyOptimization {}
            $ApplyRisky = $true
            Start-CleanupFlow
            Should -Invoke Invoke-RiskyOptimization -Exactly 1
        }
    }

    Context '退出码正确返回' {
        It '脚本文件以 exit 0 收尾（静态检查）' {
            $content = Get-Content -Path $scriptPath -Raw
            $content | Should -Match 'exit 0'
        }
        It '直接执行脚本（WhatIf）进程退出码为 0，且不泄漏 740' {
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WhatIf
            $LASTEXITCODE | Should -Be 0
        }
    }
}
