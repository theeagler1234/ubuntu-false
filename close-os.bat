@echo off
rem Windows version of close-os.sh
cd /d "%~dp0"
docker compose down
if errorlevel 1 (
    echo.
    echo Failed to stop the desktop. Is Docker Desktop running?
    pause
    exit /b 1
)
