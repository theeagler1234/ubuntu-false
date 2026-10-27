@echo off
rem Windows version of reopen-os.sh
cd /d "%~dp0"
docker compose up -d --wait
if errorlevel 1 (
    echo.
    echo Failed to start the desktop. Is Docker Desktop running?
    pause
    exit /b 1
)
echo.
echo Desktop is up. Open http://localhost:3000
