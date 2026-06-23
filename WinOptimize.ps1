#Requires -RunAsAdministrator
<#
    WinOptimizer.ps1
    Script de otimização do Windows: limpeza de disco, RAM, startup,
    serviços, energia, tarefas agendadas e políticas de grupo.

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
#  PRIVILÉGIOS DE TOKEN (necessários para limpeza de RAM)
# ============================================================
# Mesmo rodando como Administrador, o Windows exige que privilégios
# específicos sejam EXPLICITAMENTE habilitados no token do processo
# antes de certas operações de baixo nível funcionarem — entre elas,
# limpar a Standby List e o Working Set de outros processos. Sem
# isso, NtSetSystemInformation falha com STATUS_PRIVILEGE_NOT_HELD.

if (-not ("Win32.TokenPriv" -as [type])) {
    Add-Type -Namespace Win32 -Name TokenPriv -MemberDefinition @"
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
    ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

[StructLayout(LayoutKind.Sequential)]
public struct LUID { public uint LowPart; public int HighPart; }

[StructLayout(LayoutKind.Sequential)]
public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }
"@
}

function Enable-TokenPrivilege {
    param([string]$Privilege)
    try {
        $hToken = [IntPtr]::Zero
        $TOKEN_ADJUST_PRIVILEGES = 0x20
        $TOKEN_QUERY = 0x8
        [Win32.TokenPriv]::OpenProcessToken([System.Diagnostics.Process]::GetCurrentProcess().Handle,
            ($TOKEN_ADJUST_PRIVILEGES -bor $TOKEN_QUERY), [ref]$hToken) | Out-Null

        $luid = New-Object Win32.TokenPriv+LUID
        [Win32.TokenPriv]::LookupPrivilegeValue($null, $Privilege, [ref]$luid) | Out-Null

        $tp = New-Object Win32.TokenPriv+TOKEN_PRIVILEGES
        $tp.PrivilegeCount = 1
        $tp.Luid = $luid
        $tp.Attributes = 0x2  # SE_PRIVILEGE_ENABLED

        $ok = [Win32.TokenPriv]::AdjustTokenPrivileges($hToken, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($ok) {
            Write-Log "Privilégio habilitado: $Privilege"
        }
        else {
            Write-Log "Falha ao habilitar privilégio: $Privilege" "WARN"
        }
    }
    catch {
        Write-Log "Erro ao habilitar privilégio $Privilege : $($_.Exception.Message)" "WARN"
    }
}

Write-Log "--- Habilitando privilégios necessários para limpeza de RAM ---"
Enable-TokenPrivilege "SeProfileSingleProcessPrivilege"  # Necessário para limpar a Standby List
Enable-TokenPrivilege "SeIncreaseQuotaPrivilege"          # Necessário para EmptyWorkingSet em outros processos
Enable-TokenPrivilege "SeDebugPrivilege"                  # Necessário para acessar processos de outros usuários/sistema

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

    $topMem = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5
    foreach ($p in $topMem) {
        $mb = [math]::Round($p.WorkingSet / 1MB, 1)
        Write-Log "Top RAM: $($p.ProcessName) - $mb MB"
    }

    $notResponding = Get-Process | Where-Object { $_.Responding -eq $false }
    foreach ($p in $notResponding) {
        try {
            Write-Log "Processo não responde, encerrando: $($p.ProcessName) (PID $($p.Id))" "WARN"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # Encerra processos de IA do Windows que costumam ficar pré-carregados
    # em segundo plano desde o boot, mesmo sem uso ativo (Copilot, etc.)
    $aiProcesses = @("Copilot", "msai", "AIXHost")
    foreach ($procName in $aiProcesses) {
        $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($proc) {
            try {
                Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
                Write-Log "Processo de IA encerrado: $procName"
            }
            catch { }
        }
    }

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
            Write-Log "NtSetSystemInformation (Standby List) retornou código $result." "WARN"
        }
    }
    catch {
        Write-Log "Falha ao limpar Standby List: $($_.Exception.Message)" "WARN"
    }

    # Limpa o System Working Set (cache do próprio kernel/sistema)
    # SystemMemoryListInformation = 80 ; MemoryEmptyWorkingSets = 2
    try {
        $infoClass = 80
        $emptyWorkingSets = 2
        $ptr2 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr2, $emptyWorkingSets)

        $result2 = [Win32.Memory]::NtSetSystemInformation($infoClass, $ptr2, 4)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr2)

        if ($result2 -eq 0) {
            Write-Log "System Working Set limpo com sucesso (cache do kernel liberado)."
        }
        else {
            Write-Log "NtSetSystemInformation (System Working Set) retornou código $result2." "WARN"
        }
    }
    catch {
        Write-Log "Falha ao limpar System Working Set: $($_.Exception.Message)" "WARN"
    }

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
#  4. SERVIÇOS DESNECESSÁRIOS (com proteção a anticheats,
#     hardware de terceiros e jogos via filtro de fabricante)
# ============================================================

function Optimize-Services {
    Show-Header "Serviços não essenciais"

    # ------------------------------------------------------------
    # LISTA DE PROTEÇÃO NOMINAL — proteção explícita e imediata
    # para os itens mais críticos, mesmo antes do filtro de
    # fabricante entrar em ação.
    # ------------------------------------------------------------
    $neverTouch = @(
        # --- Anticheats ---
        "vgc", "vgk",                          # Riot Vanguard (Valorant)
        "EasyAntiCheat",                       # Fortnite e outros
        "BEService",                           # BattlEye
        "FACEIT",                              # FACEIT AC (CS2)
        # --- Núcleo do Windows / RPC / DCOM ---
        "RpcSs", "RpcEptMapper", "DcomLaunch", "RpcLocator",
        "gpsvc", "EventLog",
        "PlugPlay", "DeviceInstall", "DeviceAssociationService",
        # --- Segurança ---
        "WinDefend", "SecurityHealthService", "wscsvc", "Sense",
        "MpsSvc", "BFE", "CryptSvc", "ProfSvc",
        # --- Rede ---
        "Dhcp", "Dnscache", "NlaSvc", "netprofm", "nsi", "WlanSvc",
        "LanmanWorkstation", "LanmanServer",
        # --- Steam ---
        "Steam Client Service",
        # --- Drivers de GPU ---
        "nvlddmkm", "amdkmdag", "igfx",
        # --- Software de fabricantes de hardware / periféricos (curinga) ---
        "Alienware*", "AWCC*", "DellTechHub*", "Dell*",
        "Razer*", "RzActionSvc", "RzSynapse*",
        "LGHUBUpdaterService", "LGHUB*",
        "CorsairService*", "iCUE*",
        "MSI*", "MSIAfterburner*",
        "ArmouryCrate*", "AsusAppService*",
        "LenovoVantageService*", "ImControllerService*",
        "HPAppHelperCap*", "HP*",
        "AcerQuickAccess*",
        "synTPEnh*", "SynTPService*"
    )

    # ------------------------------------------------------------
    # CATEGORIA 1 — Seguros para DESABILITAR completamente.
    # ------------------------------------------------------------
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
        "WalletService",            # Carteira do Windows
        "SysMain"                   # Superfetch — causa frequente de disco em 100%
    )

    # ------------------------------------------------------------
    # CATEGORIA 2 — Mudar para MANUAL (zero risco de quebrar nada).
    # ------------------------------------------------------------
    $servicesToManual = @(
        "PrintNotify",
        "Spooler",
        "WSearch",
        "TabletInputService",
        "WbioSrvc",
        "DPS",
        "WdiServiceHost",
        "WdiSystemHost"
    )

    function Test-IsProtected {
        param($ServiceName)
        foreach ($pattern in $neverTouch) {
            if ($ServiceName -like $pattern) { return $true }
        }
        return $false
    }

    # ------------------------------------------------------------
    # FILTRO DE FABRICANTE (otimizado) — a verdadeira rede de
    # segurança. Em vez de listar manualmente cada app de terceiros,
    # verificamos o fabricante real do executável por trás do
    # serviço. Só mexemos em serviços que pertencem à Microsoft/
    # Windows. Qualquer coisa de terceiros é automaticamente
    # preservada. Usa cache + uma única consulta WMI para ser rápido.
    # ------------------------------------------------------------
    $script:MsServiceCache = @{}
    $script:AllWmiServices = $null

    function Test-IsMicrosoftService {
        param($ServiceName)

        if ($script:MsServiceCache.ContainsKey($ServiceName)) {
            return $script:MsServiceCache[$ServiceName]
        }

        if ($null -eq $script:AllWmiServices) {
            Write-Log "Carregando lista de serviços (uma única consulta)..."
            $script:AllWmiServices = @{}
            Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
                $script:AllWmiServices[$_.Name] = $_.PathName
            }
        }

        $result = $false
        try {
            $pathName = $script:AllWmiServices[$ServiceName]
            if (-not $pathName) {
                $script:MsServiceCache[$ServiceName] = $false
                return $false
            }

            $rawPath = $pathName.Trim()
            if ($rawPath.StartsWith('"')) {
                $exePath = $rawPath.Substring(1, $rawPath.IndexOf('"', 1) - 1)
            }
            else {
                $exePath = $rawPath.Split(" ")[0]
            }

            if (-not (Test-Path -LiteralPath $exePath)) {
                $script:MsServiceCache[$ServiceName] = $false
                return $false
            }

            $isInSystem32 = $exePath -like "$env:WINDIR\System32\*" -or $exePath -like "$env:WINDIR\SysWOW64\*"

            if ($isInSystem32) {
                $result = $true
            }
            else {
                $sig = Get-AuthenticodeSignature -LiteralPath $exePath -ErrorAction SilentlyContinue
                if ($sig -and $sig.SignerCertificate) {
                    $result = $sig.SignerCertificate.Subject -like "*Microsoft*"
                }
            }
        }
        catch {
            $result = $false
        }

        $script:MsServiceCache[$ServiceName] = $result
        return $result
    }

    Write-Log "--- Verificação de fabricante pronta (cache ativado) ---"

    Write-Log "--- Desabilitando serviços de telemetria/legado ---"
    foreach ($svcName in $servicesToDisable) {
        if (Test-IsProtected $svcName) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if (-not (Test-IsMicrosoftService $svcName)) {
                Write-Log "Pulado (não é serviço Microsoft): $svcName" "WARN"
                continue
            }
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

    Write-Log "--- Ajustando serviços para Manual ---"
    foreach ($svcName in $servicesToManual) {
        if (Test-IsProtected $svcName) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if (-not (Test-IsMicrosoftService $svcName)) {
                Write-Log "Pulado (não é serviço Microsoft): $svcName" "WARN"
                continue
            }
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
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Maintenance\WinSAT"
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
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "AITEnable" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableEngine" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisablePCA" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableInventory" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableSwitchBack" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableUAR" 1

    # --- Conteúdo de Nuvem ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableConsumerAccountStateContent" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1

    # --- Controle por Voz ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Speech" "AllowSpeechModelUpdate" 0

    # --- Explorador de Arquivos ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" 1

    # --- IA do Windows ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "AllowRecallEnablement" 0

    # --- Copilot (desativa completamente, inclusive carregamento em segundo plano) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegValue "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0

    # --- Instalação por Push / Localizador / Localizar Dispositivo ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Smartglass" "DisableInstallationPush" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Windows Location Provider" "DisableWindowsLocationProvider" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\FindMyDevice" "AllowFindMyDevice" 0

    # --- Loja ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload" 2

    # --- Microsoft Edge ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupHomepage" "about:blank" "String"

    # --- Pesquisa ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchPrivacy" 3

    # --- Privacidade de Aplicativos ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsAccessMotion" 2

    # --- Relatórios de Erros do Windows ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "DontShowUI" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "LoggingDisabled" 1

    # --- Sincronizar configurações ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride" 1

    # --- Widgets ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0

    # --- Windows Update (notificações) ---
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "SetUpdateNotificationLevel" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "UpdateNotificationLevel" 1

    # --- Menu Iniciar e Barra de Tarefas ---
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoRecentDocsHistory" 1

    # --- ActivityFeed ---
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