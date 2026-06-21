@echo off
REM ============================================================
REM  RunWinOptimizer.bat
REM  Duplo-clique aqui para rodar o WinOptimizer.ps1 automaticamente,
REM  ja com privilegios de administrador e execucao liberada.
REM
REM  IMPORTANTE: este arquivo .bat precisa estar na MESMA PASTA
REM  que o WinOptimizer.ps1
REM ============================================================

setlocal

REM Verifica se ja esta rodando como administrador
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :run
) else (
    echo Solicitando permissao de administrador...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:run
echo.
echo ===========================================
echo   Iniciando WinOptimizer...
echo ===========================================
echo.

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinOptimizer.ps1"

echo.
pause
endlocal