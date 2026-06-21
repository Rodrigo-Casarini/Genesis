$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
$LogFile = "$env:TEMP\WinOptimize_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile -Force | Out-Null
function Write-Log(string$msg) { Write-Host $msg; Write-Verbose $msg }
function New-RestorePoint {
    Write-Log "Criando ponto de restauracao..."
    Checkpoint-Computer -Description "WinOptimize – pre-otimizacao" -RestorePointType "MODIFY_SETTINGS"
}
New-RestorePoint
function Disable-ServiceSafe {
    param(
        string$Name,
        [ValidateSet('Manual','Disabled')][string]$Startup = 'Disabled'
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "AVISO: Servico '$Name' nao encontrado"
        return
    }
    if ($svc.StartType -ne $Startup) {
        Write-Log "Desativando servico '$Name' ($($svc.StartType) para $Startup)"
        Set-Service -Name $Name -StartupType $Startup -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        }
    } else {
        Write-Log "Servico '$Name' ja esta $Startup"
    }
}
function Remove-ItemSafe {
    param(
        string$Path,
        [switch]$Recurse,
        switch$Force
    )
    if (Test-Path $Path) {
        Write-Log "Limpando $Path"
        Remove-Item -Path $Path -Recurse:$Recurse -Force:$Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "INFO: $Path nao existe"
    }
}
function Set-RegValueSafe {
    param(
        string$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    if (Test-Path $Path) {
        $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($cur -ne $Value) {
            Write-Log "Reg $Path\$Name = $Value"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        } else {
            Write-Log "Reg $Path\$Name ja e $Value"
        }
    } else {
        Write-Log "AVISO: Caminho de registro $Path nao existe"
    }
}
$svcList = @(
    'DiagTrack',
    'dmwappushservice',
    'WSearch',
    'SysMain',
    'PrintWorkflowUserSvc',
    'RetailDemo',
    'XblGameSave',
    'XblAuthManager',
    'XboxNetApiSvc'
)
$svcList | ForEach-Object { Disable-ServiceSafe -Name $_ -Startup 'Disabled' }
$foldersToClean = @(
    "$env:TEMP\*",
    "$env:WINDIR\Temp\*",
    "$env:LOCALAPPDATA\Temp\*",
    "$env:WINDIR\Prefetch\*",
    "$env:WINDIR\Logs\*",
    "$env:WINDIR\SoftwareDistribution\Download\*"
)
$foldersToClean | ForEach-Object { Remove-ItemSafe -Path $_ -Recurse -Force }
powercfg /hibernate off 2>$null
Write-Log "Hibernacao desativada"
$plan = powercfg /list | Select-String 'High performance' | ForEach-Object { $_.ToString().split()3 }
if ($plan) {
    powercfg /setactive $plan
    Write-Log "Plano de energia: Alto desempenho ($plan)"
}
Set-RegValueSafe -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value 0
Set-RegValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2
Set-RegValueSafe -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0
$critical = @('explorer','csrss','wininit','services','lsass')
Get-Process | Where-Object { $critical -contains $_.ProcessName.ToLower() } |
    ForEach-Object {
        Write-Log "Ajustando prioridade de $($_.ProcessName) (PID $($_.Id)) -> High"
        $_.PriorityClass = 'High'
    }
Write-Log "Otimaizacao concluida. Verifique o log em $LogFile"
Write-Log "Reinicie o computador para aplicar todas as mudancas."
Stop-Transcript