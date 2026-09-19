@echo off
setlocal
title Start iPhone Radar and Overlay
if not defined RADAR_PYTHON (
    if exist "C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe" (
        set "RADAR_PYTHON=C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe"
    ) else (
        set "RADAR_PYTHON=python"
    )
)
"%RADAR_PYTHON%" "%~dp0tools\start_radar.py" %*
set "RADAR_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RADAR_RESULT%
