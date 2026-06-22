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

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%WinOptimize.ps1"

REM Verifica se ja esta rodando como administrador
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :checkfile
) else (
    echo Solicitando permissao de administrador...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:checkfile
echo.
echo Pasta do script:  %SCRIPT_DIR%
echo Procurando:       %PS1_PATH%
echo.

if not exist "%PS1_PATH%" (
    echo ===========================================
    echo   ERRO: WinOptimizer.ps1 NAO ENCONTRADO
    echo ===========================================
    echo.
    echo Verifique se:
    echo  1^) O arquivo se chama EXATAMENTE "WinOptimize.ps1"
    echo  2^) Ele esta na MESMA PASTA que este .bat
    echo  3^) A extensao nao virou ".ps1.txt" ^(ative "Extensoes de
    echo     nome de arquivo" no Explorador de Arquivos para checar^)
    echo.
    echo Arquivos encontrados nesta pasta:
    dir /b "%SCRIPT_DIR%*.ps1*" 2>nul
    echo.
    pause
    exit /b 1
)

echo ===========================================
echo   Iniciando WinOptimizer...
echo ===========================================
echo.

cd /d "%SCRIPT_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%"

echo.
pause
endlocal