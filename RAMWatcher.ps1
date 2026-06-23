#Requires -RunAsAdministrator
<#
    RAMWatcher.ps1
    Monitor de RAM em segundo plano com ícone na bandeja do sistema.
    - Ícone verde: rodando, RAM ok
    - Ícone amarelo: limpeza em andamento
    - Tooltip: uso atual de RAM
    - Menu direito: Status / Limpar agora / Encerrar
#>

# ============================================================
#  CONFIGURAÇÕES
# ============================================================

$RamThresholdPercent       = 70   # % de uso para disparar limpeza automática
$CheckIntervalMs           = 30000 # intervalo de verificação (30 segundos em ms)
$MinCleanupIntervalSeconds = 120   # mínimo entre limpezas consecutivas
$LogFile = "$PSScriptRoot\WinOptimizer-RAMWatcher.log"

# ============================================================
#  UTILITÁRIOS
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line
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
        $tp.PrivilegeCount = 1; $tp.Luid = $luid; $tp.Attributes = 0x2
        [Win32.TokenPriv]::AdjustTokenPrivileges($hToken, $false, [ref]$tp, 0,
            [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    } catch { }
}

Enable-TokenPrivilege "SeProfileSingleProcessPrivilege"
Enable-TokenPrivilege "SeIncreaseQuotaPrivilege"
Enable-TokenPrivilege "SeDebugPrivilege"

# ============================================================
#  API DE LIMPEZA DE RAM
# ============================================================

if (-not ("Win32.Memory" -as [type])) {
    Add-Type -Namespace Win32 -Name Memory -MemberDefinition @"
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
[DllImport("ntdll.dll")]
public static extern int NtSetSystemInformation(
    int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);
"@
}

function Invoke-RamCleanup {
    $freeBefore = Get-FreeMemoryMB
    $protected = @("System","Idle","Registry","smss","csrss","wininit","services","lsass","winlogon")

    Get-Process | Where-Object { $protected -notcontains $_.ProcessName } | ForEach-Object {
        try {
            $_.MinWorkingSet = -1
            $_.MaxWorkingSet = -1
            [Win32.Memory]::EmptyWorkingSet($_.Handle) | Out-Null
        } catch { }
    }

    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 4)
        [Win32.Memory]::NtSetSystemInformation(80, $ptr, 4) | Out-Null
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
    } catch { }

    try {
        $ptr2 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr2, 2)
        [Win32.Memory]::NtSetSystemInformation(80, $ptr2, 4) | Out-Null
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr2)
    } catch { }

    return (Get-FreeMemoryMB) - $freeBefore
}

# ============================================================
#  ÍCONE NA BANDEJA DO SISTEMA (Windows Forms)
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Cria ícones coloridos dinamicamente (sem precisar de arquivo .ico externo)
function New-ColorIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, 13, 13)
    $brush.Dispose()
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$iconGreen  = New-ColorIcon([System.Drawing.Color]::LimeGreen)
$iconYellow = New-ColorIcon([System.Drawing.Color]::Gold)

# Cria o NotifyIcon (ícone na bandeja)
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon    = $iconGreen
$trayIcon.Visible = $true
$trayIcon.Text    = "WinOptimizer RAMWatcher — iniciando..."

# --- Menu de contexto (botão direito) ---
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Item: Status
$menuStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$menuStatus.Text = "Status"
$menuStatus.add_Click({
    $usage = Get-RamUsagePercent
    $free  = Get-FreeMemoryMB
    $last  = if ($script:LastCleanup -eq [datetime]::MinValue) { "Nenhuma ainda" }
             else { $script:LastCleanup.ToString("HH:mm:ss") }
    [System.Windows.Forms.MessageBox]::Show(
        "RAM em uso: $usage%`nRAM livre: $free MB`nÚltima limpeza: $last`nLimiar: $RamThresholdPercent%",
        "WinOptimizer RAMWatcher",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})

# Item: Limpar agora
$menuClean = New-Object System.Windows.Forms.ToolStripMenuItem
$menuClean.Text = "Limpar RAM agora"
$menuClean.add_Click({
    $trayIcon.Icon = $iconYellow
    $trayIcon.Text = "WinOptimizer RAMWatcher — limpando..."
    Write-Log "Limpeza manual solicitada pelo usuário."
    $freed = Invoke-RamCleanup
    $script:LastCleanup = [datetime]::Now
    Write-Log "Limpeza manual concluída. +$freed MB liberados."
    $trayIcon.Icon = $iconGreen
    $trayIcon.Text = "WinOptimizer RAMWatcher — RAM: $(Get-RamUsagePercent)% em uso"
})

# Item: Separador
$separator = New-Object System.Windows.Forms.ToolStripSeparator

# Item: Encerrar
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Encerrar RAMWatcher"
$menuExit.add_Click({
    Write-Log "=== RAMWatcher encerrado pelo usuário ==="
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $script:Running = $false
    [System.Windows.Forms.Application]::Exit()
})

$contextMenu.Items.Add($menuStatus)  | Out-Null
$contextMenu.Items.Add($menuClean)   | Out-Null
$contextMenu.Items.Add($separator)   | Out-Null
$contextMenu.Items.Add($menuExit)    | Out-Null
$trayIcon.ContextMenuStrip = $contextMenu

# ============================================================
#  TIMER — verifica RAM a cada 30 segundos sem bloquear a UI
# ============================================================

$script:LastCleanup = [datetime]::MinValue
$script:Running     = $true

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $CheckIntervalMs

$timer.add_Tick({
    try {
        $usage   = Get-RamUsagePercent
        $freeMB  = Get-FreeMemoryMB
        $elapsed = ([datetime]::Now - $script:LastCleanup).TotalSeconds

        # Atualiza tooltip com status atual
        $trayIcon.Text = "RAMWatcher — $usage% em uso | $freeMB MB livres"

        if ($usage -ge $RamThresholdPercent -and $elapsed -ge $MinCleanupIntervalSeconds) {
            Write-Log "RAM em $usage% ($freeMB MB livres) — limpeza automática iniciada."
            $trayIcon.Icon = $iconYellow
            $trayIcon.Text = "RAMWatcher — limpando RAM..."

            $freed = Invoke-RamCleanup
            $script:LastCleanup = [datetime]::Now

            Write-Log "Limpeza automática concluída. +$freed MB liberados. RAM agora: $(Get-FreeMemoryMB) MB livres."
            $trayIcon.Icon = $iconGreen
            $trayIcon.Text = "RAMWatcher — $(Get-RamUsagePercent)% em uso | $(Get-FreeMemoryMB) MB livres"
        }
    } catch {
        Write-Log "Erro no timer: $($_.Exception.Message)" "WARN"
    }
})

$timer.Start()

Write-Log "=== RAMWatcher iniciado (ícone na bandeja) ==="
Write-Log "Limiar: $RamThresholdPercent% | Verificação: $($CheckIntervalMs/1000)s | Intervalo mínimo: ${MinCleanupIntervalSeconds}s"

# Inicia o loop de mensagens do Windows Forms (mantém o ícone vivo)
[System.Windows.Forms.Application]::Run()