#Requires -RunAsAdministrator
<#
    WinOptimizer.ps1
    Script de otimização do Windows: limpeza de disco, RAM, startup,
    serviços, energia, tarefas agendadas e políticas de grupo.

    Como usar:
      1. Abra o PowerShell como Administrador
      2. Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
      3. .\WinOptimize.ps1
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
#  PERFIL DO USUÁRIO — perguntas feitas UMA VEZ no início
#  As respostas guiam o comportamento de cada módulo.
# ============================================================

function Get-UserProfile {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "     WinOptimizer - Configuração inicial" -ForegroundColor Magenta
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Algumas otimizações dependem do seu uso." -ForegroundColor Cyan
    Write-Host "Responda rapidinho e o script se adapta pra você." -ForegroundColor Cyan
    Write-Host ""

    $profile = @{}

    # Hibernação
    Write-Host "1) Você usa HIBERNAR no menu desligar?" -ForegroundColor Yellow
    Write-Host "   (Hibernar salva a sessão no disco e desliga completamente)"
    $r = Read-Host "   S = Sim, uso / N = Não, só Desligar/Suspender"
    $profile.UsaHibernacao = ($r -eq "S" -or $r -eq "s")

    Write-Host ""

    # Efeitos visuais
    Write-Host "2) Você quer manter os efeitos visuais do Windows?" -ForegroundColor Yellow
    Write-Host "   (Animações, transparência, sombras — desabilitar libera CPU/GPU)"
    $r2 = Read-Host "   S = Manter visuais / N = Desabilitar pra ganhar performance"
    $profile.ManterVisuais = ($r2 -eq "S" -or $r2 -eq "s")

    Write-Host ""

    # Logs de eventos
    Write-Host "3) Você quer MANTER os logs de eventos do Windows?" -ForegroundColor Yellow
    Write-Host "   (Úteis pra diagnosticar problemas — podem ocupar vários GB)"
    $r3 = Read-Host "   S = Manter logs / N = Limpar logs"
    $profile.ManterLogs = ($r3 -eq "S" -or $r3 -eq "s")

    Write-Host ""

    # TCP/IP reset
    Write-Host "4) Resetar TCP/IP e Winsock?" -ForegroundColor Yellow
    Write-Host "   (Resolve lentidão de rede acumulada — EXIGE REINÍCIO após)"
    $r4 = Read-Host "   S = Sim, resetar / N = Não"
    $profile.ResetarTCP = ($r4 -eq "S" -or $r4 -eq "s")

    Write-Host ""

    # Impressora
    Write-Host "5) Você usa impressora neste PC?" -ForegroundColor Yellow
    $r5 = Read-Host "   S = Sim / N = Não"
    $profile.UsaImpressora = ($r5 -eq "S" -or $r5 -eq "s")

    Write-Host ""
    Write-Host "Perfil configurado! Iniciando otimização personalizada..." -ForegroundColor Green
    Start-Sleep -Seconds 2

    Write-Log "Perfil do usuário: Hibernacao=$($profile.UsaHibernacao) | Visuais=$($profile.ManterVisuais) | Logs=$($profile.ManterLogs) | ResetTCP=$($profile.ResetarTCP) | Impressora=$($profile.UsaImpressora)"

    return $profile
}

# Carrega o perfil uma vez e disponibiliza globalmente
$script:Perfil = $null

function Ensure-Perfil {
    if ($null -eq $script:Perfil) {
        $script:Perfil = Get-UserProfile
    }
}

# ============================================================
#  PRIVILÉGIOS DE TOKEN
# ============================================================

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
        [Win32.TokenPriv]::OpenProcessToken(
            [System.Diagnostics.Process]::GetCurrentProcess().Handle,
            (0x20 -bor 0x8), [ref]$hToken) | Out-Null
        $luid = New-Object Win32.TokenPriv+LUID
        [Win32.TokenPriv]::LookupPrivilegeValue($null, $Privilege, [ref]$luid) | Out-Null
        $tp = New-Object Win32.TokenPriv+TOKEN_PRIVILEGES
        $tp.PrivilegeCount = 1
        $tp.Luid = $luid
        $tp.Attributes = 0x2
        $ok = [Win32.TokenPriv]::AdjustTokenPrivileges($hToken, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($ok) { Write-Log "Privilégio habilitado: $Privilege" }
        else { Write-Log "Falha ao habilitar privilégio: $Privilege" "WARN" }
    }
    catch { Write-Log "Erro ao habilitar $Privilege : $($_.Exception.Message)" "WARN" }
}

Write-Log "--- Habilitando privilégios necessários ---"
Enable-TokenPrivilege "SeProfileSingleProcessPrivilege"
Enable-TokenPrivilege "SeIncreaseQuotaPrivilege"
Enable-TokenPrivilege "SeDebugPrivilege"

# ============================================================
#  1. LIMPEZA DE DISCO (expandida)
# ============================================================

function Optimize-Disk {
    Show-Header "Limpeza de disco"
    Ensure-Perfil

    # --- Caminhos seguros para limpar sempre ---
    $paths = @(
        "$env:TEMP\*",
        "$env:WINDIR\Temp\*",
        "$env:WINDIR\Prefetch\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
        "$env:WINDIR\SoftwareDistribution\Download\*",
        "$env:WINDIR\SoftwareDistribution\DataStore\Logs\*",
        "$env:WINDIR\Minidump\*",
        "$env:LOCALAPPDATA\CrashDumps\*",
        "$env:WINDIR\LiveKernelReports\*.dmp",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\WebCache\*",
        "$env:APPDATA\Microsoft\Windows\Recent\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db"
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
        catch { Write-Log "Falha ao limpar $path : $($_.Exception.Message)" "WARN" }
    }

    # Limpa crash dump principal
    $dumpFile = "$env:WINDIR\memory.dmp"
    if (Test-Path $dumpFile) {
        try {
            $sz = [math]::Round((Get-Item $dumpFile).Length / 1MB, 1)
            Remove-Item $dumpFile -Force -ErrorAction SilentlyContinue
            $totalFreedMB += $sz
            Write-Log "Crash dump removido: $dumpFile ($sz MB)"
        }
        catch { Write-Log "Falha ao remover crash dump." "WARN" }
    }

    # Limpa cache de fontes
    try {
        Stop-Service -Name "FontCache" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache-System\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
        Write-Log "Cache de fontes limpo."
    }
    catch { Write-Log "Falha ao limpar cache de fontes." "WARN" }

    # Esvazia lixeira
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log "Lixeira esvaziada."
    }
    catch { Write-Log "Lixeira já estava vazia." "WARN" }

    # Remove arquivo de hibernação (usuário confirmou que não usa)
    try {
        powercfg /hibernate off 2>$null
        if (Test-Path "$env:WINDIR\hiberfil.sys") {
            $hibSz = [math]::Round((Get-Item "$env:WINDIR\hiberfil.sys" -Force -ErrorAction SilentlyContinue).Length / 1GB, 2)
            $totalFreedMB += $hibSz * 1024
            Write-Log "Hibernação desabilitada. hiberfil.sys removido (~$hibSz GB liberados)."
        }
    }
    catch { Write-Log "Falha ao desabilitar hibernação." "WARN" }

    # Logs de eventos (com confirmação)
    if (Confirm-Action "Limpar logs de eventos do Windows? (úteis para diagnóstico, mas podem ocupar vários GB)") {
        try {
            Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($_.LogName)
                } catch { }
            }
            Write-Log "Logs de eventos limpos."
        }
        catch { Write-Log "Falha ao limpar logs de eventos." "WARN" }
    }

    Write-Log "Limpeza de disco concluída. ~$totalFreedMB MB liberados (estimativa)."
    Write-Host ""
    Write-Host "Disco: ~$totalFreedMB MB liberados!" -ForegroundColor Green
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
    Write-Log "RAM livre ANTES: $freeBefore MB"

    $topMem = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5
    foreach ($p in $topMem) {
        Write-Log "Top RAM: $($p.ProcessName) - $([math]::Round($p.WorkingSet/1MB,1)) MB"
    }

    # Encerra processos travados
    Get-Process | Where-Object { $_.Responding -eq $false } | ForEach-Object {
        try {
            Write-Log "Processo travado encerrado: $($_.ProcessName) (PID $($_.Id))" "WARN"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    # Encerra processos de IA em segundo plano
    @("Copilot", "msai", "AIXHost") | ForEach-Object {
        if (Get-Process -Name $_ -ErrorAction SilentlyContinue) {
            Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
            Write-Log "Processo de IA encerrado: $_"
        }
    }

    if (-not ("Win32.Memory" -as [type])) {
        Add-Type -Namespace Win32 -Name Memory -MemberDefinition @"
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
[DllImport("ntdll.dll")]
public static extern int NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);
"@
    }

    $protected = @("System","Idle","Registry","smss","csrss","wininit","services","lsass","winlogon")
    $cleaned = 0
    Get-Process | Where-Object { $protected -notcontains $_.ProcessName } | ForEach-Object {
        try {
            $_.MinWorkingSet = -1
            $_.MaxWorkingSet = -1
            [Win32.Memory]::EmptyWorkingSet($_.Handle) | Out-Null
            $cleaned++
        } catch { }
    }
    Write-Log "Working sets limpos em $cleaned processos."

    # Limpa Standby List
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 4)
        $r = [Win32.Memory]::NtSetSystemInformation(80, $ptr, 4)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
        if ($r -eq 0) { Write-Log "Standby List limpa com sucesso." }
        else { Write-Log "NtSetSystemInformation (Standby) retornou código $r." "WARN" }
    } catch { Write-Log "Falha ao limpar Standby List: $($_.Exception.Message)" "WARN" }

    # Limpa System Working Set
    try {
        $ptr2 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr2, 2)
        $r2 = [Win32.Memory]::NtSetSystemInformation(80, $ptr2, 4)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr2)
        if ($r2 -eq 0) { Write-Log "System Working Set limpo com sucesso." }
        else { Write-Log "NtSetSystemInformation (SysWS) retornou código $r2." "WARN" }
    } catch { Write-Log "Falha ao limpar System Working Set: $($_.Exception.Message)" "WARN" }

    $freeAfter = Get-FreeMemoryMB
    $diff = $freeAfter - $freeBefore
    Write-Log "RAM livre DEPOIS: $freeAfter MB"
    if ($diff -ge 0) {
        Write-Log "RAM liberada: +$diff MB"
        Write-Host ""
        Write-Host "RAM: $freeBefore MB -> $freeAfter MB  (+$diff MB liberados)" -ForegroundColor Green
    } else {
        Write-Log "RAM variou $diff MB (uso normal do sistema)."
        Write-Host ""
        Write-Host "RAM: $freeBefore MB -> $freeAfter MB" -ForegroundColor Yellow
    }
}

# ============================================================
#  3. GERENCIAMENTO DE INICIALIZAÇÃO
# ============================================================

function Show-StartupItems {
    Show-Header "Programas de inicialização"

    $items = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location
    if (-not $items) { Write-Log "Nenhum item de inicialização encontrado."; return }

    $i = 1
    foreach ($item in $items) { Write-Host "[$i] $($item.Name)  ->  $($item.Command)"; $i++ }
    Write-Log "Itens de inicialização listados ($($items.Count) itens)."

    # Remove entradas órfãs de startup (executável não existe mais)
    Write-Log "--- Verificando entradas órfãs de startup ---"
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) { continue }
        $entries = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if (-not $entries) { continue }
        $entries.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
            $exePath = ($_.Value -replace '^"([^"]+)".*', '$1').Split(" ")[0].Trim('"')
            if ($exePath -and -not (Test-Path $exePath -ErrorAction SilentlyContinue)) {
                try {
                    Remove-ItemProperty -Path $regPath -Name $_.Name -Force -ErrorAction SilentlyContinue
                    Write-Log "Entrada órfã removida do startup: $($_.Name) -> $exePath"
                } catch { }
            }
        }
    }
}

# ============================================================
#  4. SERVIÇOS DESNECESSÁRIOS
# ============================================================

function Optimize-Services {
    Show-Header "Serviços não essenciais"

    $neverTouch = @(
        "vgc","vgk","EasyAntiCheat","BEService","FACEIT",
        "RpcSs","RpcEptMapper","DcomLaunch","RpcLocator",
        "gpsvc","EventLog","PlugPlay","DeviceInstall","DeviceAssociationService",
        "WinDefend","SecurityHealthService","wscsvc","Sense",
        "MpsSvc","BFE","CryptSvc","ProfSvc",
        "Dhcp","Dnscache","NlaSvc","netprofm","nsi","WlanSvc",
        "LanmanWorkstation","LanmanServer",
        "Steam Client Service","nvlddmkm","amdkmdag","igfx",
        "Alienware*","AWCC*","DellTechHub*","Dell*",
        "Razer*","RzActionSvc*","LGHUBUpdaterService","LGHUB*",
        "CorsairService*","iCUE*","MSI*","ArmouryCrate*","AsusAppService*",
        "LenovoVantageService*","ImControllerService*","HPAppHelperCap*","HP*",
        "AcerQuickAccess*","synTPEnh*","SynTPService*"
    )

    $servicesToDisable = @(
        "DiagTrack",           # Telemetria (Connected User Experiences)
        "dmwappushservice",    # Telemetria WAP Push
        "RetailDemo",          # Modo demonstração de loja
        "MapsBroker",          # Download de mapas offline
        "WMPNetworkSvc",       # Compartilhamento de rede do Windows Media Player
        "RemoteRegistry",      # Edição remota de registro
        "Fax",                 # Serviço de fax
        "WerSvc",              # Relatório de Erros do Windows
        "PhoneSvc",            # Telefone (sem uso em desktop)
        "WalletService",       # Carteira do Windows
        "SysMain",             # Superfetch — causa frequente de disco em 100%
        "WbioSrvc",            # Biometria (Windows Hello por impressão digital)
        "wisvc",               # Windows Insider Service
        "wlidsvc",             # Microsoft Account Sign-in Assistant
        "PushToInstall",       # Instalação por push da Store
        "MessagingService",    # Serviço de mensagens (SMS/MMS — sem uso em desktop)
        "OneSyncSvc",          # Sincronização de conta Microsoft
        "SharedAccess",        # Compartilhamento de conexão (ICS)
        "lfsvc",               # Serviço de localização geográfica
        "SEMgrSvc",            # Pagamentos e NFC
        "ScDeviceEnum",        # Smart Card Device Enumeration
        "SCPolicySvc",         # Smart Card Removal Policy
        "SCardSvr",            # Smart Card
        "CscService",          # Offline Files (arquivos offline)
        "WpcMonSvc",           # Controle parental
        "XboxGipSvc",          # Xbox Accessory Management (controles Xbox)
        "XblAuthManager",      # Xbox Live Auth
        "XblGameSave",         # Xbox Live Game Save
        "XboxNetApiSvc"        # Xbox Live Networking
    )

    $servicesToManual = @(
        "WSearch","TabletInputService",
        "WbioSrvc","DPS","WdiServiceHost","WdiSystemHost"
    )

    # Spooler e PrintNotify só vão pra Manual se o usuário não usa impressora
    if (-not $script:Perfil.UsaImpressora) {
        $servicesToManual += @("PrintNotify","Spooler")
        Write-Log "Spooler e PrintNotify serão definidos como Manual (sem impressora)."
    } else {
        Write-Log "Spooler e PrintNotify preservados (usuário usa impressora)."
    }

    function Test-IsProtected {
        param($n)
        foreach ($p in $neverTouch) { if ($n -like $p) { return $true } }
        return $false
    }

    $script:MsServiceCache = @{}
    $script:AllWmiServices = $null

    function Test-IsMicrosoftService {
        param($ServiceName)
        if ($script:MsServiceCache.ContainsKey($ServiceName)) { return $script:MsServiceCache[$ServiceName] }
        if ($null -eq $script:AllWmiServices) {
            Write-Log "Carregando lista de serviços (consulta única)..."
            $script:AllWmiServices = @{}
            Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
                $script:AllWmiServices[$_.Name] = $_.PathName
            }
        }
        $result = $false
        try {
            $pn = $script:AllWmiServices[$ServiceName]
            if (-not $pn) { $script:MsServiceCache[$ServiceName] = $false; return $false }
            $raw = $pn.Trim()
            $exe = if ($raw.StartsWith('"')) { $raw.Substring(1, $raw.IndexOf('"',1)-1) } else { $raw.Split(" ")[0] }
            if (-not (Test-Path -LiteralPath $exe)) { $script:MsServiceCache[$ServiceName] = $false; return $false }
            $inSys = $exe -like "$env:WINDIR\System32\*" -or $exe -like "$env:WINDIR\SysWOW64\*"
            if ($inSys) { $result = $true }
            else {
                $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue
                if ($sig -and $sig.SignerCertificate) { $result = $sig.SignerCertificate.Subject -like "*Microsoft*" }
            }
        } catch { $result = $false }
        $script:MsServiceCache[$ServiceName] = $result
        return $result
    }

    Write-Log "--- Desabilitando serviços de telemetria/legado ---"
    foreach ($svcName in $servicesToDisable) {
        if (Test-IsProtected $svcName) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if (-not (Test-IsMicrosoftService $svcName)) { Write-Log "Pulado (terceiro): $svcName" "WARN"; continue }
            try {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svcName -StartupType Disabled
                Write-Log "Desabilitado: $svcName"
            } catch { Write-Log "Falha: $svcName : $($_.Exception.Message)" "WARN" }
        }
    }

    Write-Log "--- Ajustando serviços para Manual ---"
    foreach ($svcName in $servicesToManual) {
        if (Test-IsProtected $svcName) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if (-not (Test-IsMicrosoftService $svcName)) { Write-Log "Pulado (terceiro): $svcName" "WARN"; continue }
            try {
                Set-Service -Name $svcName -StartupType Manual
                Write-Log "Manual: $svcName"
            } catch { Write-Log "Falha: $svcName : $($_.Exception.Message)" "WARN" }
        }
    }
    Write-Log "Serviços otimizados. Anticheats, hardware e plataformas de jogo preservados."
}

# ============================================================
#  4B. REDUZIR PROCESSOS ATIVOS
# ============================================================

function Optimize-Processes {
    Show-Header "Reduzir processos ativos"

    $before = (Get-Process).Count
    Write-Log "Processos ANTES: $before"

    # Processos de IA/Copilot em segundo plano
    $aiProcs = @("Copilot", "msai", "AIXHost")
    foreach ($p in $aiProcs) {
        if (Get-Process -Name $p -ErrorAction SilentlyContinue) {
            Stop-Process -Name $p -Force -ErrorAction SilentlyContinue
            Write-Log "Processo de IA encerrado: $p"
        }
    }

    # RuntimeBroker — o Windows cria um por app UWP ativo
    # Encerrar os ociosos é seguro; o Windows recria quando precisar
    $rtBrokers = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue
    if ($rtBrokers.Count -gt 2) {
        $rtBrokers | Select-Object -Skip 2 | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                Write-Log "RuntimeBroker ocioso encerrado (PID $($_.Id))"
            } catch { }
        }
    }

    # WmiPrvSE — instâncias extras de WMI provider host
    $wmiProcs = Get-Process -Name "WmiPrvSE" -ErrorAction SilentlyContinue
    if ($wmiProcs.Count -gt 1) {
        $wmiProcs | Select-Object -Skip 1 | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                Write-Log "WmiPrvSE extra encerrado (PID $($_.Id))"
            } catch { }
        }
    }

    # Processos travados (não respondem)
    Get-Process | Where-Object { $_.Responding -eq $false } | ForEach-Object {
        try {
            Write-Log "Processo travado encerrado: $($_.ProcessName) (PID $($_.Id))" "WARN"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    $after = (Get-Process).Count
    $diff = $before - $after
    Write-Log "Processos DEPOIS: $after (-$diff processos)"
    Write-Host ""
    Write-Host "Processos: $before -> $after  (-$diff encerrados)" -ForegroundColor Green
}

# ============================================================
#  5. PLANO DE ENERGIA
# ============================================================

function Optimize-Power {
    Show-Header "Plano de energia"
    try {
        powercfg /setactive "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        Write-Log "Plano definido: Alto Desempenho."
    } catch { Write-Log "Falha ao definir plano de energia." "WARN" }
}

# ============================================================
#  6. TAREFAS AGENDADAS
# ============================================================

function Optimize-ScheduledTasks {
    Show-Header "Tarefas agendadas"
    $tasks = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Maintenance\WinSAT"
    )
    foreach ($task in $tasks) {
        try {
            Disable-ScheduledTask -TaskPath (Split-Path $task -Parent) `
                                   -TaskName (Split-Path $task -Leaf) `
                                   -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Tarefa desabilitada: $task"
        } catch { Write-Log "Falha: $task" "WARN" }
    }
}

# ============================================================
#  7. REDE — TELEMETRIA + FLUSH + RESET TCP
# ============================================================

function Optimize-Network {
    Show-Header "Rede e telemetria"
    Ensure-Perfil

    # Telemetria
    try {
        $rp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        if (-not (Test-Path $rp)) { New-Item -Path $rp -Force | Out-Null }
        Set-ItemProperty -Path $rp -Name "AllowTelemetry" -Value 0 -Type DWord
        Write-Log "Telemetria desabilitada."
    } catch { Write-Log "Falha ao desabilitar telemetria." "WARN" }

    # Flush DNS
    try {
        ipconfig /flushdns | Out-Null
        Write-Log "Cache DNS limpo (flush)."
    } catch { Write-Log "Falha ao limpar DNS." "WARN" }

    # Limpa tabela ARP e cache de rotas
    try {
        arp -d * 2>$null
        route /f 2>$null
        Write-Log "Tabela ARP e cache de rotas limpos."
    } catch { Write-Log "Falha ao limpar ARP/rotas." "WARN" }

    # Reset TCP/IP e Winsock (baseado na preferência do usuário)
    if ($script:Perfil.ResetarTCP) {
        try {
            netsh winsock reset | Out-Null
            netsh int ip reset | Out-Null
            Write-Log "TCP/IP e Winsock resetados. Reinício necessário."
            Write-Host "TCP/IP e Winsock resetados — reinicie para aplicar." -ForegroundColor Yellow
        } catch { Write-Log "Falha ao resetar TCP/IP." "WARN" }
    } else {
        Write-Log "Reset TCP/IP ignorado (usuário optou por não resetar)."
    }
}

# ============================================================
#  8. POLÍTICAS DE GRUPO (GPEDIT via registro)
# ============================================================

function Set-RegValue {
    param($Path, $Name, $Value, $Type = "DWord")
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Log "Registro: $Path [$Name = $Value]"
    } catch { Write-Log "Falha: $Path [$Name]: $($_.Exception.Message)" "WARN" }
}

function Optimize-GroupPolicies {
    Show-Header "Políticas de grupo (equivalente ao GPEDIT)"

    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DoNotShowFeedbackNotifications" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "AITEnable" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableEngine" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisablePCA" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableInventory" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableSwitchBack" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableUAR" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableConsumerAccountStateContent" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Speech" "AllowSpeechModelUpdate" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "AllowRecallEnablement" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegValue "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Smartglass" "DisableInstallationPush" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Windows Location Provider" "DisableWindowsLocationProvider" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\FindMyDevice" "AllowFindMyDevice" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" "AutoDownload" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupHomepage" "about:blank" "String"
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchPrivacy" 3
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsAccessMotion" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "DontShowUI" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "LoggingDisabled" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync" 2
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "SetUpdateNotificationLevel" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "UpdateNotificationLevel" 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoRecentDocsHistory" 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1

    Write-Log "Políticas de grupo aplicadas."
}

# ============================================================
#  9. VISUAL / PERFORMANCE (efeitos, animações, transparência)
# ============================================================

function Optimize-Visual {
    Show-Header "Efeitos visuais (performance máxima)"
    Ensure-Perfil

    if ($script:Perfil.ManterVisuais) {
        Write-Host "Efeitos visuais preservados (usuário optou por manter)." -ForegroundColor Yellow
        Write-Log "Efeitos visuais preservados por preferência do usuário."
        return
    }

    # Desabilita animações e efeitos visuais pesados
    try {
        $vPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
        if (-not (Test-Path $vPath)) { New-Item -Path $vPath -Force | Out-Null }
        Set-ItemProperty -Path $vPath -Name "VisualFXSetting" -Value 2  # 2 = Ajustar para melhor desempenho

        # Parâmetros individuais de performance
        $advPath = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $advPath -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary
        Set-ItemProperty -Path $advPath -Name "MenuShowDelay" -Value "0" -Type String
        Set-ItemProperty -Path $advPath -Name "DragFullWindows" -Value "0" -Type String

        # Desabilita transparência
        Set-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 0

        # Desabilita animações de janelas
        Set-RegValue "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "0" "String"

        Write-Log "Efeitos visuais configurados para máxima performance."
        Write-Host "Efeitos visuais otimizados — faça logoff/logon para ver o efeito completo." -ForegroundColor Yellow
    }
    catch { Write-Log "Falha ao ajustar efeitos visuais: $($_.Exception.Message)" "WARN" }
}

# ============================================================
#  10. REGISTRO — histórico e entradas órfãs
# ============================================================

function Optimize-Registry {
    Show-Header "Limpeza de registro"

    # Limpa histórico de execução (MUICache)
    try {
        $muiPath = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
        if (Test-Path $muiPath) {
            Remove-Item -Path $muiPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "MUICache limpo."
        }
    } catch { Write-Log "Falha ao limpar MUICache." "WARN" }

    # Limpa UserAssist (histórico de programas usados)
    try {
        $uaPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist"
        if (Test-Path $uaPath) {
            Get-ChildItem $uaPath | ForEach-Object {
                Remove-ItemProperty -Path "$($_.PSPath)\Count" -Name * -Force -ErrorAction SilentlyContinue
            }
            Write-Log "UserAssist limpo."
        }
    } catch { Write-Log "Falha ao limpar UserAssist." "WARN" }

    # Limpa RecentDocs do registro
    try {
        $rdPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs"
        if (Test-Path $rdPath) {
            Remove-Item -Path $rdPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "RecentDocs do registro limpo."
        }
    } catch { Write-Log "Falha ao limpar RecentDocs." "WARN" }

    # Limpa RunMRU (histórico de comandos no Executar/Win+R)
    try {
        $runMru = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU"
        if (Test-Path $runMru) {
            Remove-Item -Path $runMru -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "RunMRU (histórico Win+R) limpo."
        }
    } catch { Write-Log "Falha ao limpar RunMRU." "WARN" }

    Write-Log "Limpeza de registro concluída."
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================

function Show-Menu {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "          WinOptimizer - PowerShell" -ForegroundColor Magenta
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "[1]  Limpeza de disco (expandida)"
    Write-Host "[2]  Otimizar memória RAM"
    Write-Host "[3]  Inicialização (listar + remover órfãs)"
    Write-Host "[4]  Desabilitar serviços desnecessários"
    Write-Host "[4B] Reduzir processos ativos agora"
    Write-Host "[5]  Plano de energia (Alto desempenho)"
    Write-Host "[6]  Tarefas agendadas"
    Write-Host "[7]  Rede (telemetria + flush DNS + TCP reset)"
    Write-Host "[8]  Políticas de grupo (GPEDIT via registro)"
    Write-Host "[9]  Efeitos visuais (performance máxima)"
    Write-Host "[10] Registro (histórico + entradas órfãs)"
    Write-Host "[11] EXECUTAR TUDO (otimização completa)"
    Write-Host "[0]  Sair"
    Write-Host ""
}

do {
    Show-Menu
    $choice = Read-Host "Escolha uma opção"

    switch ($choice) {
        "1"  { Optimize-Disk }
        "2"  { Optimize-Memory }
        "3"  { Show-StartupItems }
        "4"  { if (Confirm-Action "Desabilitar serviços desnecessários?") { Optimize-Services } }
        "4b" { Optimize-Processes }
        "4B" { Optimize-Processes }
        "5"  { Optimize-Power }
        "6"  { Optimize-ScheduledTasks }
        "7"  { Optimize-Network }
        "8"  { if (Confirm-Action "Aplicar políticas de grupo via registro?") { Optimize-GroupPolicies } }
        "9"  { Optimize-Visual }
        "10" { Optimize-Registry }
        "11" {
            Ensure-Perfil
            if (Confirm-Action "Executar TODAS as otimizações?") {
                Optimize-Disk
                Optimize-Memory
                Show-StartupItems
                Optimize-Services
                Optimize-Processes
                Optimize-Power
                Optimize-ScheduledTasks
                Optimize-Network
                Optimize-GroupPolicies
                Optimize-Visual
                Optimize-Registry
                Write-Log "=== Otimização completa finalizada ==="
                Write-Host ""
                Write-Host "Otimização completa! Log: $LogFile" -ForegroundColor Green
                Write-Host "Algumas mudanças exigem reinício para fazer efeito completo." -ForegroundColor Yellow
                if (Confirm-Action "Reiniciar agora?") {
                    Write-Log "Reinício solicitado."
                    Write-Host "Reiniciando em 10 segundos... (Ctrl+C para cancelar)" -ForegroundColor Red
                    Start-Sleep -Seconds 10
                    Restart-Computer -Force
                }
            }
        }
        "0"  { Write-Log "=== WinOptimizer encerrado ===" }
        default { Write-Host "Opção inválida." -ForegroundColor Red }
    }

    if ($choice -ne "0") {
        Write-Host ""
        Read-Host "Pressione Enter para voltar ao menu"
    }

} while ($choice -ne "0")