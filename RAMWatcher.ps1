#Requires -RunAsAdministrator
<#
    WinOptimizer-RAMWatcher.ps1
    Monitor de RAM em segundo plano.

    Fica rodando silenciosamente e só executa a limpeza de RAM
    quando o uso ultrapassar o limiar configurado. Leve, não
    interfere com jogos ou uso normal do PC.

    Como usar:
      Rode via RunRAMWatcher.bat (duplo-clique)
      ou manualmente:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        .\WinOptimizer-RAMWatcher.ps1
#>

# ============================================================
#  CONFIGURAÇÕES — ajuste conforme preferir
# ============================================================

# Limiar de uso de RAM (%) para disparar a limpeza
$RamThresholdPercent = 70

# Intervalo de verificação em segundos (verifica o uso de RAM a cada X segundos)
$CheckIntervalSeconds = 30

# Intervalo mínimo entre duas limpezas consecutivas (em segundos)
# Evita limpezas em cascata caso a RAM suba e desça rapidamente
$MinCleanupIntervalSeconds = 120

# Arquivo de log do watcher (separado do log principal)
$LogFile = "$PSScriptRoot\WinOptimizer-RAMWatcher.log"

# ============================================================
#  UTILITÁRIOS
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    # Não exibe no console (roda em segundo plano silencioso)
}

function Get-RamUsagePercent {
    $os = Get-CimInstance Win32_OperatingSystem
    $used = $os.TotalVisibleMemorySize - $os.FreePhysicalMemory
    return [math]::Round(($used / $os.TotalVisibleMemorySize) * 100, 1)
}

function Get-FreeMemoryMB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1KB, 0)
}

# ============================================================
#  PRIVILÉGIOS (necessários para limpeza de RAM funcionar)
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
        $tp.Attributes = 0x2  # SE_PRIVILEGE_ENABLED

        [Win32.TokenPriv]::AdjustTokenPrivileges($hToken, $false, [ref]$tp, 0,
            [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    catch { }
}

Enable-TokenPrivilege "SeProfileSingleProcessPrivilege"
Enable-TokenPrivilege "SeIncreaseQuotaPrivilege"
Enable-TokenPrivilege "SeDebugPrivilege"

# ============================================================
#  API DE LIMPEZA DE RAM (mesma do WinOptimizer.ps1)
# ============================================================

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

function Invoke-RamCleanup {
    $freeBefore = Get-FreeMemoryMB
    $protected = @("System","Idle","Registry","smss","csrss","wininit","services","lsass","winlogon")

    # Limpa Working Sets de processos não críticos
    Get-Process | Where-Object { $protected -notcontains $_.ProcessName } | ForEach-Object {
        try {
            $_.MinWorkingSet = -1
            $_.MaxWorkingSet = -1
            [Win32.Memory]::EmptyWorkingSet($_.Handle) | Out-Null
        }
        catch { }
    }

    # Limpa Standby List
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 4)  # MemoryPurgeStandbyList
        [Win32.Memory]::NtSetSystemInformation(80, $ptr, 4) | Out-Null
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
    }
    catch { }

    # Limpa System Working Set
    try {
        $ptr2 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr2, 2)  # MemoryEmptyWorkingSets
        [Win32.Memory]::NtSetSystemInformation(80, $ptr2, 4) | Out-Null
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr2)
    }
    catch { }

    $freeAfter = Get-FreeMemoryMB
    $diff = $freeAfter - $freeBefore
    return $diff
}

# ============================================================
#  LOOP PRINCIPAL — roda para sempre em segundo plano
# ============================================================

Write-Log "=== RAMWatcher iniciado ==="
Write-Log "Limiar: $RamThresholdPercent% | Verificação: ${CheckIntervalSeconds}s | Intervalo mínimo entre limpezas: ${MinCleanupIntervalSeconds}s"

$lastCleanup = [datetime]::MinValue

while ($true) {
    try {
        $usagePercent = Get-RamUsagePercent
        $freeMB = Get-FreeMemoryMB
        $now = [datetime]::Now
        $secondsSinceLastCleanup = ($now - $lastCleanup).TotalSeconds

        if ($usagePercent -ge $RamThresholdPercent -and $secondsSinceLastCleanup -ge $MinCleanupIntervalSeconds) {
            Write-Log "RAM em $usagePercent% ($freeMB MB livres) — limpeza iniciada."
            $freed = Invoke-RamCleanup
            $lastCleanup = [datetime]::Now
            Write-Log "Limpeza concluída. +$freed MB liberados. RAM agora: $(Get-FreeMemoryMB) MB livres."
        }
    }
    catch {
        Write-Log "Erro no loop de monitoramento: $($_.Exception.Message)" "WARN"
    }

    Start-Sleep -Seconds $CheckIntervalSeconds
}