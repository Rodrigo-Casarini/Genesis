<#
.SYNOPSIS
    Script de Otimizacao Windows 11 - Reducao de uso de RAM, CPU e Disco
.DESCRIPTION
    Realiza limpezas e ajustes exclusivamente em componentes NATIVOS do Windows.
    Nao desativa Windows Defender, Firewall ou Windows Update (seguranca).
    Nao afeta processos ou configuracoes de aplicativos de terceiros.
.NOTES
    Autor: Script gerado sob demanda
    Requisito: executar como Administrador
    Recomendacao: leia cada secao antes de rodar. Todas as secoes podem ser
    ligadas/desligadas nas variaveis de configuracao logo abaixo.
#>

#Requires -RunAsAdministrator

# ============================================================
#  CONFIGURACOES - mude para $true / $false conforme desejar
# ============================================================
$CriarPontoRestauracao   = $true    # Recomendado manter $true (seguranca)
$LimpezaDisco            = $true    # Temp, cache, lixeira, limpeza de disco nativa
$LimparWinSxS            = $true    # Remove versoes antigas de componentes do Windows (DISM)
$DesativarServicos       = $true    # Desabilita servicos nativos nao essenciais
$DesativarTarefas        = $true    # Desabilita tarefas agendadas de telemetria/diagnostico
$OtimizarVisual          = $true    # Reduz efeitos visuais (menos uso de CPU/GPU no DWM)
$DesativarHibernacao     = $true    # Libera espaco em disco (~tamanho da sua RAM)
                                     # ATENCAO: tambem desativa a "Inicializacao Rapida"
$PlanoAltoDesempenho     = $true    # Ativa plano de energia de Alto Desempenho
$DesativarIndexacao      = $false   # Desliga indexacao de busca (deixe $false se usa
                                     # muito a pesquisa do Windows/Explorer - fica mais lenta)
$DesativarWidgetsGameBar = $true    # Desliga Widgets, Chat/Teams integrado e Xbox Game Bar

$LogFile = "$env:USERPROFILE\Desktop\otimizacao_windows_log.txt"
Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Secao($texto) {
    Write-Host "`n=== $texto ===" -ForegroundColor Cyan
}

# ============================================================
# 1. PONTO DE RESTAURACAO (seguranca antes de qualquer mudanca)
# ============================================================
if ($CriarPontoRestauracao) {
    Write-Secao "Criando ponto de restauracao do sistema"
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\"
        Checkpoint-Computer -Description "Antes da otimizacao - $(Get-Date -Format yyyy-MM-dd_HHmm)" -RestorePointType "MODIFY_SETTINGS"
        Write-Host "Ponto de restauracao criado com sucesso."
    } catch {
        Write-Warning "Nao foi possivel criar o ponto de restauracao: $_"
    }
}

# ============================================================
# 2. LIMPEZA DE DISCO
# ============================================================
if ($LimpezaDisco) {
    Write-Secao "Limpando arquivos temporarios e caches do sistema"

    $pastas = @(
        "$env:TEMP\*",
        "$env:WINDIR\Temp\*",
        "$env:WINDIR\Prefetch\*",
        "$env:WINDIR\SoftwareDistribution\Download\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
        "$env:WINDIR\Logs\CBS\*",
        "$env:WINDIR\Panther\*"
    )

    foreach ($pasta in $pastas) {
        try {
            Remove-Item -Path $pasta -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Limpo: $pasta"
        } catch {}
    }

    Write-Host "Esvaziando a Lixeira..."
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    Write-Host "Configurando e executando Limpeza de Disco nativa (todas as categorias)..."
    $chaveBase = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    Get-ChildItem $chaveBase | ForEach-Object {
        Set-ItemProperty -Path $_.PsPath -Name "StateFlags0001" -Value 2 -ErrorAction SilentlyContinue
    }
    Start-Process cleanmgr.exe -ArgumentList "/sagerun:1" -Wait -ErrorAction SilentlyContinue
}

# ============================================================
# 3. LIMPEZA DO WINSXS (componentes antigos do Windows)
# ============================================================
if ($LimparWinSxS) {
    Write-Secao "Limpando componentes antigos do WinSxS (DISM)"
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
}

# ============================================================
# 4. SERVICOS NATIVOS - desabilitar nao essenciais
# ============================================================
if ($DesativarServicos) {
    Write-Secao "Desabilitando servicos nativos nao essenciais"

    # Cada servico abaixo e do proprio Windows. Nada de terceiros e tocado.
    $servicos = @(
        "DiagTrack",         # Telemetria / Experiencias do usuario
        "dmwappushservice",  # WAP Push (telemetria)
        "RetailDemo",        # Modo demonstracao de loja
        "Fax",               # Servico de Fax
        "WMPNetworkSvc",     # Compartilhamento de rede do Windows Media Player
        "MapsBroker",        # Downloads de mapas offline
        "PhoneSvc",          # Servico de telefone (irrelevante em desktop)
        "WalletService",     # Carteira do Windows
        "XblAuthManager",    # Xbox Live Auth (desative so se nao usa Xbox/Game Pass)
        "XblGameSave",       # Xbox Game Save
        "XboxNetApiSvc",     # Xbox Networking
        "SysMain"            # Superfetch/Prefetch - geralmente melhor desligado em SSD
    )

    foreach ($srv in $servicos) {
        try {
            $s = Get-Service -Name $srv -ErrorAction SilentlyContinue
            if ($s) {
                Stop-Service -Name $srv -Force -ErrorAction SilentlyContinue
                Set-Service -Name $srv -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Host "Desabilitado: $srv"
            }
        } catch {
            Write-Warning "Falha ao desabilitar $srv"
        }
    }

    Write-Host "`nNOTA: Windows Update, Windows Defender e Firewall NAO foram alterados."
}

# ============================================================
# 5. TAREFAS AGENDADAS DE TELEMETRIA/DIAGNOSTICO
# ============================================================
if ($DesativarTarefas) {
    Write-Secao "Desabilitando tarefas agendadas de telemetria e diagnostico"

    $tarefas = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Autochk\Proxy",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Feedback\Siuf\DmClient",
        "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
        "\Microsoft\Windows\Windows Error Reporting\QueueReporting",
        "\Microsoft\Windows\Maps\MapsToastTask",
        "\Microsoft\Windows\Maps\MapsUpdateTask"
    )

    foreach ($t in $tarefas) {
        try {
            $taskName = Split-Path $t -Leaf
            $taskPath = (Split-Path $t) + "\"
            Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Desabilitada: $t"
        } catch {}
    }
}

# ============================================================
# 6. EFEITOS VISUAIS - priorizar desempenho
# ============================================================
if ($OtimizarVisual) {
    Write-Secao "Ajustando efeitos visuais para melhor desempenho"
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "DragFullWindows" -Value "0" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "EnableAeroPeek" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -ErrorAction SilentlyContinue
    Write-Host "Efeitos visuais ajustados para performance."
}

# ============================================================
# 7. HIBERNACAO - libera espaco em disco (~tamanho da RAM)
# ============================================================
if ($DesativarHibernacao) {
    Write-Secao "Desativando hibernacao (libera espaco em disco)"
    powercfg /hibernate off
    Write-Host "Hibernacao desativada. NOTA: isso tambem desativa a 'Inicializacao Rapida'."
}

# ============================================================
# 8. PLANO DE ENERGIA - Alto Desempenho
# ============================================================
if ($PlanoAltoDesempenho) {
    Write-Secao "Ativando plano de energia de Alto Desempenho"
    powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
}

# ============================================================
# 9. INDEXACAO DE PESQUISA (opcional - desligado por padrao)
# ============================================================
if ($DesativarIndexacao) {
    Write-Secao "Desativando indexacao de pesquisa do Windows"
    Stop-Service "WSearch" -Force -ErrorAction SilentlyContinue
    Set-Service "WSearch" -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "NOTA: a busca do Windows/Explorer ficara mais lenta (sem indice)."
}

# ============================================================
# 10. WIDGETS / GAME BAR / CHAT (consumo de RAM em segundo plano)
# ============================================================
if ($DesativarWidgetsGameBar) {
    Write-Secao "Desativando Widgets, Chat (Teams) e Game Bar"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarMn" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -ErrorAction SilentlyContinue
    Write-Host "Widgets, Chat e Game Bar desativados."
}

# ============================================================
# FINALIZACAO
# ============================================================
Write-Secao "Otimizacao concluida"
Write-Host "Log salvo em: $LogFile"
Write-Host "Reinicie o computador para aplicar todas as mudancas."
Stop-Transcript | Out-Null
