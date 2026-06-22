@echo off
REM ============================================================
REM  RunRAMWatcher.bat
REM  Inicia o monitor de RAM em segundo plano (janela oculta).
REM  Coloque este .bat na mesma pasta que WinOptimizer-RAMWatcher.ps1
REM ============================================================

setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%WinOptimizer-RAMWatcher.ps1"

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%PS1_PATH%" (
    echo ERRO: WinOptimizer-RAMWatcher.ps1 nao encontrado em %SCRIPT_DIR%
    pause
    exit /b 1
)

echo Iniciando monitor de RAM em segundo plano...
echo Log salvo em: %SCRIPT_DIR%WinOptimizer-RAMWatcher.log
echo.
echo Para encerrar o monitor, abra o Gerenciador de Tarefas
echo e encerre o processo "powershell.exe" correspondente.
echo.

REM Inicia o script em segundo plano (janela oculta, sem travar este .bat)
powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%"

endlocal