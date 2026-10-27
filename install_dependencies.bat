@echo off
setlocal EnableExtensions
rem Checks for Docker Desktop and cloudflared, and installs whichever are missing.
rem Uses winget when available, otherwise downloads the installers directly.
rem Right-click and choose "Run as administrator" for installs to succeed.

net session >nul 2>&1
if errorlevel 1 (
    echo This script needs to run as Administrator.
    echo Right-click install_dependencies.bat and choose "Run as administrator".
    pause
    exit /b 1
)

set "TMPDIR=%TEMP%\ubuntu-false-install"
if not exist "%TMPDIR%" mkdir "%TMPDIR%"

set "HAVE_WINGET=0"
where winget >nul 2>&1 && set "HAVE_WINGET=1"

echo == Checking dependencies ==

rem --- Docker Desktop ---------------------------------------------------------
where docker >nul 2>&1
if errorlevel 1 goto :install_docker
docker compose version >nul 2>&1
if errorlevel 1 goto :install_docker
echo [ok] docker and docker compose are installed
goto :check_cloudflared

:install_docker
echo [missing] Docker Desktop - installing
if "%HAVE_WINGET%"=="1" (
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
) else (
    echo winget not found, downloading the installer with curl.
    curl.exe -L -o "%TMPDIR%\DockerDesktopInstaller.exe" "https://desktop.docker.com/win/main/amd64/Docker%%20Desktop%%20Installer.exe"
    if errorlevel 1 goto :download_failed
    start /wait "" "%TMPDIR%\DockerDesktopInstaller.exe" install --quiet
)
set "NEED_RESTART=1"

:check_cloudflared
where cloudflared >nul 2>&1
if not errorlevel 1 (
    echo [ok] cloudflared is installed
    goto :done
)
echo [missing] cloudflared - installing
if "%HAVE_WINGET%"=="1" (
    winget install -e --id Cloudflare.cloudflared --accept-package-agreements --accept-source-agreements
) else (
    echo winget not found, downloading the installer with curl.
    curl.exe -L -o "%TMPDIR%\cloudflared.msi" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi"
    if errorlevel 1 goto :download_failed
    msiexec /i "%TMPDIR%\cloudflared.msi" /qn
)
goto :done

:download_failed
echo.
echo Download failed. Check your internet connection and try again.
pause
exit /b 1

:done
echo.
echo == Finished ==
if defined NEED_RESTART (
    echo Docker Desktop was just installed. Restart your PC, start Docker Desktop once,
    echo accept its terms, and wait until it says it is running. Docker Desktop needs
    echo WSL 2 or Hyper-V; the installer will prompt you if one is missing.
    echo.
)
echo Open a NEW terminal window before using docker or cloudflared, so the PATH updates.
echo.
echo == Next: set up the Cloudflare tunnel ==
echo You need a free Cloudflare account and a domain managed by Cloudflare.
echo.
echo 1. Set a strong password. Create a file named .env next to docker-compose.yml:
echo      DESKTOP_PASSWORD=your-long-random-password
echo    and make docker-compose.yml use PASSWORD: ${DESKTOP_PASSWORD}
echo    Do not commit .env.
echo.
echo 2. Start the desktop:
echo      reopen-os.bat
echo.
echo 3. Log in to Cloudflare, which opens a browser window:
echo      cloudflared tunnel login
echo.
echo 4. Create the tunnel:
echo      cloudflared tunnel create ubuntu-desktop
echo.
echo 5. Point a hostname at it:
echo      cloudflared tunnel route dns ubuntu-desktop desktop.yourdomain.com
echo.
echo 6. Create %%USERPROFILE%%\.cloudflared\config.yml containing:
echo      tunnel: ubuntu-desktop
echo      credentials-file: C:\Users\YOU\.cloudflared\TUNNEL-ID.json
echo      ingress:
echo        - hostname: desktop.yourdomain.com
echo          service: http://localhost:3000
echo        - service: http_status:404
echo.
echo 7. Test it, then install it as a service so it starts on boot:
echo      cloudflared tunnel run ubuntu-desktop
echo      cloudflared service install
echo.
echo 8. Strongly recommended: in the Cloudflare Zero Trust dashboard, add an Access
echo    application for desktop.yourdomain.com so people must sign in by email code
echo    or Google before reaching the desktop login page.
echo.
echo For a quick throwaway test with no domain, the URL changes every run:
echo      cloudflared tunnel --url http://localhost:3000
echo.
pause
endlocal
