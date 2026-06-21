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

function Get-FreeMemoryMB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1KB, 0)
}

function Optimize-Memory {
    Show-Header "Otimização de memória RAM"

    $freeBefore = Get-FreeMemoryMB
    Write-Log "RAM livre ANTES da otimização: $freeBefore MB"

    # Lista processos consumindo mais RAM (top 5), só para log informativo
    $topMem = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5
    foreach ($p in $topMem) {
        $mb = [math]::Round($p.WorkingSet / 1MB, 1)
        Write-Log "Top RAM: $($p.ProcessName) - $mb MB"
    }

    # Encerra processos zumbis/não-respondendo (com cautela)
    $notResponding = Get-Process | Where-Object { $_.Responding -eq $false }
    foreach ($p in $notResponding) {
        try {
            Write-Log "Processo não responde, encerrando: $($p.ProcessName) (PID $($p.Id))" "WARN"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # Carrega as APIs nativas necessárias (psapi + ntdll)
    if (-not ("Win32.Memory" -as [type])) {
        Add-Type -Namespace Win32 -Name Memory -MemberDefinition @"
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);

[DllImport("ntdll.dll")]
public static extern int NtSetSystemInformation(
    int SystemInformationClass,
    IntPtr SystemInformation,
    int SystemInformationLength);
"@
    }

    # Limpa o working set de processos que não são críticos do sistema
    $protected = @("System", "Idle", "Registry", "smss", "csrss", "wininit", "services", "lsass", "winlogon")

    $cleaned = 0
    Get-Process | Where-Object { $protected -notcontains $_.ProcessName } | ForEach-Object {
        try {
            $_.MinWorkingSet = -1
            $_.MaxWorkingSet = -1
            [Win32.Memory]::EmptyWorkingSet($_.Handle) | Out-Null
            $cleaned++
        }
        catch { }
    }
    Write-Log "Working sets limpos em $cleaned processos."

    # Limpa a Standby List do sistema (cache de arquivos em RAM)
    # SystemMemoryListInformation = 80 ; MemoryPurgeStandbyList = 4
    try {
        $infoClass = 80
        $purgeStandbyList = 4
        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, $purgeStandbyList)

        $result = [Win32.Memory]::NtSetSystemInformation($infoClass, $ptr, 4)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)

        if ($result -eq 0) {
            Write-Log "Standby List do sistema limpa com sucesso (cache de RAM liberado)."
        }
        else {
            Write-Log "NtSetSystemInformation retornou código $result (pode precisar de privilégio SeProfileSingleProcessPrivilege)." "WARN"
        }
    }
    catch {
        Write-Log "Falha ao limpar Standby List: $($_.Exception.Message)" "WARN"
    }

    # Verifica estado do Memory Compression (recurso nativo do Windows 10/11)
    try {
        $compStore = Get-Counter '\Memory\% Committed Bytes In Use' -ErrorAction SilentlyContinue
        if ($compStore) {
            $pct = [math]::Round($compStore.CounterSamples[0].CookedValue, 1)
            Write-Log "Memória comprometida em uso: $pct%"
        }
    }
    catch { }

    $freeAfter = Get-FreeMemoryMB
    $diff = $freeAfter - $freeBefore

    Write-Log "RAM livre DEPOIS da otimização: $freeAfter MB"
    if ($diff -ge 0) {
        Write-Log "RAM liberada nesta passada: +$diff MB"
        Write-Host ""
        Write-Host "RAM livre: $freeBefore MB -> $freeAfter MB  (+$diff MB liberados)" -ForegroundColor Green
    }
    else {
        Write-Log "RAM livre variou $diff MB (uso normal do sistema pode ter consumido nesse intervalo)."
        Write-Host ""
        Write-Host "RAM livre: $freeBefore MB -> $freeAfter MB" -ForegroundColor Yellow
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

    # ============================================================
    # LISTA DE PROTEÇÃO — NUNCA tocar nestes serviços.
    # Cobre: anticheats (Vanguard, EAC, BattlEye), segurança do
    # Windows, RPC/DCOM (essencial para anticheats se comunicarem
    # com o kernel), rede, Plug and Play e Steam.
    # ============================================================
    $neverTouch = @(
        # --- Anticheats ---
        "vgc", "vgk",                          # Riot Vanguard (Valorant)
        "EasyAntiCheat",                       # Fortnite e outros
        "BEService",                           # BattlEye
        "FACEIT",                              # FACEIT AC (CS2)
        # --- Núcleo do Windows / RPC / DCOM (anticheats dependem disso) ---
        "RpcSs", "RpcEptMapper", "DcomLaunch", "RpcLocator",
        "gpsvc",                               # Política de Grupo
        "EventLog",                            # Log de eventos (verificado por Vanguard/EAC)
        "PlugPlay", "DeviceInstall", "DeviceAssociationService",
        # --- Segurança ---
        "WinDefend", "SecurityHealthService", "wscsvc", "Sense",
        "MpsSvc", "BFE",                       # Firewall do Windows
        "CryptSvc", "ProfSvc",
        # --- Rede ---
        "Dhcp", "Dnscache", "NlaSvc", "netprofm", "nsi", "WlanSvc",
        "LanmanWorkstation", "LanmanServer",
        # --- Steam / Plataformas de jogo ---
        "Steam Client Service",
        # --- Drivers e hardware essenciais ---
        "nvlddmkm", "amdkmdag", "igfx",         # drivers de GPU (caso apareçam como serviço)
        # --- Software de fabricantes de hardware / periféricos ---
        # (RGB, perfis de teclado/mouse, modo de jogo de notebook, sensores)
        "Alienware*", "AWCC*",                  # Alienware Command Center
        "DellTechHub*", "Dell*",                # Dell (Power Manager, SupportAssist, etc.)
        "Razer*", "RzActionSvc", "RzSynapse*",  # Razer Synapse
        "LGHUBUpdaterService", "LGHUB*",        # Logitech G Hub
        "CorsairService*", "iCUE*",             # Corsair iCUE
        "MSI*", "MSIAfterburner*",              # MSI Center / Afterburner
        "ArmouryCrate*", "AsusAppService*",     # ASUS Armoury Crate
        "LenovoVantageService*", "ImControllerService*", # Lenovo Vantage
        "HPAppHelperCap*", "HP*",               # HP (Omen Gaming Hub, etc.)
        "AcerQuickAccess*",                     # Acer (PredatorSense / Quick Access
        "synTPEnh*", "SynTPService*"            # Synaptics (touchpad de notebook)
    )

    # ============================================================
    # CATEGORIA 1 — Seguros para DESABILITAR completamente.
    # Telemetria, recursos legados e funções raramente usadas.
    # ============================================================
    $servicesToDisable = @(
        "DiagTrack",                # Telemetria (Connected User Experiences)
        "dmwappushservice",         # Telemetria WAP Push
        "RetailDemo",               # Modo demonstração de loja
        "MapsBroker",               # Download de mapas offline
        "WMPNetworkSvc",            # Compartilhamento de rede do Windows Media Player
        "RemoteRegistry",           # Edição remota de registro
        "Fax",                      # Serviço de fax
        "WerSvc",                   # Relatório de Erros do Windows
        "PhoneSvc",                 # Telefone (sem uso em desktop)
        "WalletService"             # Carteira do Windows
    )

    # ============================================================
    # CATEGORIA 2 — Mudar para MANUAL (não desabilita, só para de
    # rodar sempre; inicia automaticamente quando algo precisar).
    # Mais seguro que desabilitar — zero risco de quebrar algo.
    # ============================================================
    $servicesToManual = @(
        "PrintNotify",              # Notificações de impressora (se não imprime sempre)
        "Spooler",                  # Spooler de impressão (vira manual, não desativa)
        "WSearch",                  # Windows Search/indexação (buscas ficam mais lentas, mas funcionam)
        "TabletInputService",       # Teclado virtual / entrada por toque
        "WbioSrvc",                 # Biometria (se não usa leitor digital/Windows Hello)
        "SysMain",                  # Superfetch/Prefetch — controverso, ajuda HD mas pode atrapalhar SSD
        "DPS",                      # Diagnostic Policy Service
        "WdiServiceHost",
        "WdiSystemHost"
    )

    # Verifica se um nome de serviço bate com algum item da lista de proteção,
    # suportando curingas (*) para nomes que variam por versão/fabricante.
    function Test-IsProtected {
        param($ServiceName)
        foreach ($pattern in $neverTouch) {
            if ($ServiceName -like $pattern) { return $true }
        }
        return $false
    }

    Write-Log "--- Desabilitando serviços de telemetria/legado ---"
    foreach ($svcName in $servicesToDisable) {
        if (Test-IsProtected $svcName) { continue }  # segurança extra
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

    Write-Log "--- Ajustando serviços para Manual (iniciam só quando necessário) ---"
    foreach ($svcName in $servicesToManual) {
        if (Test-IsProtected $svcName) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Set-Service -Name $svcName -StartupType Manual
                Write-Log "Serviço definido como Manual: $svcName"
            }
            catch {
                Write-Log "Falha ao ajustar $svcName : $($_.Exception.Message)" "WARN"
            }
        }
    }

    Write-Log "Anticheats, RPC/DCOM, rede, Defender, Steam, Xbox/Game Pass e softwares de hardware/periféricos foram preservados intactos."
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
#  8. POLÍTICAS DE GRUPO (equivalente ao GPEDIT, via registro)
# ============================================================

function Set-RegValue {
    param($Path, $Name, $Value, $Type = "DWord")
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Log "Registro: $Path [$Name = $Value]"
    }
    catch {
        Write-Log "Falha ao definir $Path [$Name]: $($_.Exception.Message)" "WARN"
    }
}

function Optimize-GroupPolicies {
    Show-Header "Políticas de grupo (equivalente ao GPEDIT)"

    # --- Coleta de Dados e Telemetria ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DoNotShowFeedbackNotifications" 1

    # --- Compatibilidade de Aplicativos ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "AITEnable" 0          # Telemetria de Aplicativos
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableEngine" 1       # Mecanismo de Compatibilidade
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisablePCA" 1          # Auxiliar de Compatibilidade
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableInventory" 1    # Coletor de Inventário
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableSwitchBack" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableUAR" 1          # Gravador de Passos

    # --- Conteúdo de Nuvem (sugestões/dicas/anúncios) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableConsumerAccountStateContent" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1

    # --- Controle por Voz ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Speech" "AllowSpeechModelUpdate" 0

    # --- Explorador de Arquivos ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" 1

    # --- IA do Windows (Recall / Click to Do / pesquisa agêntica) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "AllowRecallEnablement" 0

    # --- Instalação por Push / Localizador / Localizar Dispositivo ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Smartglass" "DisableInstallationPush" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Windows Location Provider" "DisableWindowsLocationProvider" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\FindMyDevice" "AllowFindMyDevice" 0

    # --- Loja / Atualizações automáticas de apps ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload" 2

    # --- Microsoft Edge ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupHomepage" "about:blank" "String"

    # --- Pesquisa (Bing / Cortana / indexação de nuvem) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchPrivacy" 3

    # --- Privacidade de Aplicativos (segundo plano, movimento do usuário) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 2       # Forçar Negação
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsAccessMotion" 2

    # --- Relatórios de Erros do Windows ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "DontShowUI" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "LoggingDisabled" 1

    # --- Sincronizar configurações (OneDrive/nuvem) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride" 1

    # --- Widgets ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0

    # --- Windows Update (notificações reduzidas) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "SetUpdateNotificationLevel" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "UpdateNotificationLevel" 1

    # --- Menu Iniciar e Barra de Tarefas (histórico de documentos) ---
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoRecentDocsHistory" 1

    # --- ActivityFeed (Linha do Tempo / histórico de atividades) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0

    # --- ID de anúncio ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1

    Write-Log "Políticas de grupo aplicadas. Algumas exigem reinício ou logoff para refletir na interface."
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
    Write-Host "[8] Políticas de grupo (GPEDIT via registro)"
    Write-Host "[9] EXECUTAR TUDO (otimização completa)"
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
        "8" { if (Confirm-Action "Isso vai aplicar várias políticas de grupo via registro. Continuar?") { Optimize-GroupPolicies } }
        "9" {
            if (Confirm-Action "Isso vai executar TODAS as otimizações. Continuar?") {
                Optimize-Disk
                Optimize-Memory
                Show-StartupItems
                Optimize-Services
                Optimize-Power
                Optimize-ScheduledTasks
                Optimize-Network
                Optimize-GroupPolicies
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