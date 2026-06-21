#Requires -RunAsAdministrator
<#
    WinOptimizer.ps1
    Script de otimização do Windows: limpeza de disco, RAM, startup,
    serviços, energia e tarefas agendadas.

    Como usar:
      1. Abra o PowerShell como Administrador
      2. Se necessário, libere a execução de scripts nesta sessão:
         Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
      3. Rode: .\WinOptimizer.ps1
#>

# ============================================================
#  CONFIG / UTILITÁRIOS
# ============================================================

$LogFile = "$PSScriptRoot\WinOptimizer.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "WARN" { Write-Host $line -ForegroundColor Yellow }
        "ERR"  { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Confirm-Action {
    param([string]$Question)
    $resp = Read-Host "$Question (S/N)"
    return ($resp -eq "S" -or $resp -eq "s")
}

function Show-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "  $Title" -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
}

Write-Log "=== WinOptimizer iniciado ==="

# ============================================================
#  1. LIMPEZA DE DISCO
# ============================================================

function Optimize-Disk {
    Show-Header "Limpeza de disco"

    $paths = @(
        "$env:TEMP\*",
        "$env:WINDIR\Temp\*",
        "$env:WINDIR\Prefetch\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
        "$env:WINDIR\SoftwareDistribution\Download\*"
    )

    $totalFreedMB = 0

    foreach ($path in $paths) {
        try {
            $items = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            $sizeBytes = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($sizeBytes) { $totalFreedMB += [math]::Round($sizeBytes / 1MB, 2) }

            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Limpo: $path"
        }
        catch {
            Write-Log "Falha ao limpar $path : $($_.Exception.Message)" "WARN"
        }
    }

    # Esvazia a lixeira
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log "Lixeira esvaziada."
    }
    catch {
        Write-Log "Não foi possível esvaziar a lixeira (pode já estar vazia)." "WARN"
    }

    Write-Log "Limpeza de disco concluída. ~$totalFreedMB MB liberados (estimativa)."
}

# ============================================================
#  2. LIMPEZA DE MEMÓRIA RAM
# ============================================================

function Optimize-Memory {
    Show-Header "Otimização de memória RAM"

    # Lista processos consumindo mais RAM (top 5), só para log informativo
    $topMem = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5
    foreach ($p in $topMem) {
        $mb = [math]::Round($p.WorkingSet / 1MB, 1)
        Write-Log "Top RAM: $($p.ProcessName) - $mb MB"
    }

    # Limpa o working set de processos que não são críticos do sistema
    $protected = @("System", "Idle", "Registry", "smss", "csrss", "wininit", "services", "lsass", "winlogon")

    Get-Process | Where-Object { $protected -notcontains $_.ProcessName } | ForEach-Object {
        try {
            [void]$_.MinWorkingSet
            $_.MinWorkingSet = -1
            $_.MaxWorkingSet = -1
        }
        catch { }
    }

    Write-Log "Working sets ajustados para processos não críticos."

    # Limpa a Standby List via SetSystemFileCacheSize (requer privilégio)
    try {
        Add-Type -Namespace Win32 -Name Memory -MemberDefinition @"
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
"@
        Get-Process | ForEach-Object {
            try { [Win32.Memory]::EmptyWorkingSet($_.Handle) | Out-Null } catch {}
        }
        Write-Log "EmptyWorkingSet aplicado aos processos acessíveis."
    }
    catch {
        Write-Log "Falha ao aplicar EmptyWorkingSet: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================
#  3. GERENCIAMENTO DE INICIALIZAÇÃO (STARTUP)
# ============================================================

function Show-StartupItems {
    Show-Header "Programas de inicialização"

    $items = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location

    if (-not $items) {
        Write-Log "Nenhum item de inicialização encontrado."
        return
    }

    $i = 1
    foreach ($item in $items) {
        Write-Host "[$i] $($item.Name)  ->  $($item.Command)"
        $i++
    }

    Write-Log "Listagem de itens de inicialização exibida ($($items.Count) itens)."
    Write-Host ""
    Write-Host "Para desabilitar algum item manualmente, use o Gerenciador de Tarefas > Inicializar," -ForegroundColor Yellow
    Write-Host "ou rode: Disable-ScheduledTask / remova a chave do registro correspondente." -ForegroundColor Yellow
}

# ============================================================
#  4. SERVIÇOS DESNECESSÁRIOS
# ============================================================

function Optimize-Services {
    Show-Header "Serviços não essenciais"

    # Lista conservadora — serviços comumente seguros de desabilitar
    # em uso doméstico/comum. Revise antes de aplicar em ambiente corporativo.
    $servicesToDisable = @(
        "DiagTrack",                # Telemetria (Connected User Experiences)
        "dmwappushservice",         # Telemetria WAP Push
        "RetailDemo",               # Modo demonstração de loja
        "MapsBroker",               # Download de mapas offline
        "WMPNetworkSvc",            # Compartilhamento de rede do Windows Media Player
        "RemoteRegistry",           # Edição remota de registro (risco de segurança se ligado)
        "Fax"                       # Serviço de fax
    )

    foreach ($svcName in $servicesToDisable) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svcName -StartupType Disabled
                Write-Log "Serviço desabilitado: $svcName"
            }
            catch {
                Write-Log "Falha ao desabilitar $svcName : $($_.Exception.Message)" "WARN"
            }
        }
    }
}

# ============================================================
#  5. PLANO DE ENERGIA
# ============================================================

function Optimize-Power {
    Show-Header "Plano de energia"

    try {
        # GUID padrão do plano "Alto desempenho"
        $highPerf = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        powercfg /setactive $highPerf
        Write-Log "Plano de energia definido para Alto Desempenho."
    }
    catch {
        Write-Log "Falha ao definir plano de energia: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================
#  6. TAREFAS AGENDADAS DESNECESSÁRIAS
# ============================================================

function Optimize-ScheduledTasks {
    Show-Header "Tarefas agendadas"

    $tasksToDisable = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
    )

    foreach ($task in $tasksToDisable) {
        try {
            Disable-ScheduledTask -TaskPath (Split-Path $task -Parent) `
                                   -TaskName (Split-Path $task -Leaf) `
                                   -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Tarefa desabilitada: $task"
        }
        catch {
            Write-Log "Falha ao desabilitar tarefa $task : $($_.Exception.Message)" "WARN"
        }
    }
}

# ============================================================
#  7. REDE — DESABILITAR TELEMETRIA
# ============================================================

function Optimize-Network {
    Show-Header "Rede e telemetria"

    try {
        # Desabilita telemetria via registro (nível básico)
        $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -Path $regPath -Name "AllowTelemetry" -Value 0 -Type DWord
        Write-Log "Telemetria reduzida ao mínimo (AllowTelemetry = 0)."
    }
    catch {
        Write-Log "Falha ao ajustar telemetria: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================

function Show-Menu {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "          WinOptimizer - PowerShell" -ForegroundColor Magenta
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "[1] Limpeza de disco"
    Write-Host "[2] Otimizar memória RAM"
    Write-Host "[3] Listar itens de inicialização"
    Write-Host "[4] Desabilitar serviços desnecessários"
    Write-Host "[5] Plano de energia (Alto desempenho)"
    Write-Host "[6] Desabilitar tarefas agendadas inúteis"
    Write-Host "[7] Reduzir telemetria de rede"
    Write-Host "[8] EXECUTAR TUDO (otimização completa)"
    Write-Host "[0] Sair"
    Write-Host ""
}

do {
    Show-Menu
    $choice = Read-Host "Escolha uma opção"

    switch ($choice) {
        "1" { Optimize-Disk }
        "2" { Optimize-Memory }
        "3" { Show-StartupItems }
        "4" { if (Confirm-Action "Tem certeza que deseja desabilitar serviços?") { Optimize-Services } }
        "5" { Optimize-Power }
        "6" { Optimize-ScheduledTasks }
        "7" { Optimize-Network }
        "8" {
            if (Confirm-Action "Isso vai executar TODAS as otimizações. Continuar?") {
                Optimize-Disk
                Optimize-Memory
                Show-StartupItems
                Optimize-Services
                Optimize-Power
                Optimize-ScheduledTasks
                Optimize-Network
                Write-Log "=== Otimização completa finalizada ==="
                Write-Host ""
                Write-Host "Otimização completa! Log salvo em: $LogFile" -ForegroundColor Green
                Write-Host ""
                Write-Host "Algumas mudanças (serviços, tarefas agendadas, telemetria) só" -ForegroundColor Yellow
                Write-Host "fazem efeito completo após reiniciar o PC." -ForegroundColor Yellow
                if (Confirm-Action "Deseja reiniciar o computador agora?") {
                    Write-Log "Reinício solicitado pelo usuário após otimização completa."
                    Write-Host "Reiniciando em 10 segundos... (Ctrl+C para cancelar)" -ForegroundColor Red
                    Start-Sleep -Seconds 10
                    Restart-Computer -Force
                }
            }
        }
        "0" { Write-Log "=== WinOptimizer encerrado pelo usuário ===" }
        default { Write-Host "Opção inválida." -ForegroundColor Red }
    }

    if ($choice -ne "0") {
        Write-Host ""
        Read-Host "Pressione Enter para voltar ao menu"
    }

} while ($choice -ne "0")