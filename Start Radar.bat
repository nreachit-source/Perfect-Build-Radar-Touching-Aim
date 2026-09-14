@echo off
setlocal
title Start iPhone Radar and Overlay
if not defined RADAR_PYTHON set "RADAR_PYTHON=C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe"
if not exist "%RADAR_PYTHON%" (
 echo Python toolchain missing. Set RADAR_PYTHON to your device Python executable.
 pause
 exit /b 1
)
"%RADAR_PYTHON%" "%~dp0tools\start_radar.py" %*
set "RADAR_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RADAR_RESULT%
