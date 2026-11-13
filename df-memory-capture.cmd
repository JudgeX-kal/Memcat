@echo off
setlocal

set "TIMESTAMP=%DATE%_%TIME%"
set "TIMESTAMP=%TIMESTAMP::=-%"
set "TIMESTAMP=%TIMESTAMP:/=-%"
set "TIMESTAMP=%TIMESTAMP: =_%"
set "LOG=%~dp0wrapper_debug_%TIMESTAMP%.txt"

echo Wrapper started: %DATE% %TIME% >> "%LOG%"
echo Script path: %~dp0df-memory-capture.ps1 >> "%LOG%"

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0df-memory-capture.ps1" >> "%LOG%" 2>&1

echo PowerShell exit code: %ERRORLEVEL% >> "%LOG%"
echo Wrapper finished: %DATE% %TIME% >> "%LOG%"

exit /b %ERRORLEVEL%