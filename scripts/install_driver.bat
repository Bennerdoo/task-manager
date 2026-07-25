@echo off
REM ==========================================================================
REM  install_driver.bat  —  AsmTaskMgr
REM  Manually installs and starts the AsmTaskMgr.sys kernel driver.
REM  The app does this automatically on startup, but this script lets you
REM  install/start the driver independently (e.g., for testing).
REM
REM  Requires: Test Signing Mode enabled (scripts\enable_testsign.bat)
REM            Must be run as Administrator.
REM ==========================================================================

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run this script as Administrator.
    pause
    exit /b 1
)

set DRV_NAME=AsmTaskMgrDrv
set DRV_DISPLAY=AsmTaskMgr Kernel Driver

REM Resolve absolute path to build\AsmTaskMgr.sys
set SCRIPT_DIR=%~dp0
set SYS_PATH=%SCRIPT_DIR%..\build\AsmTaskMgr.sys

if not exist "%SYS_PATH%" (
    echo [ERROR] Driver not found: %SYS_PATH%
    echo         Run build.bat first.
    pause
    exit /b 1
)

REM Convert to absolute path
pushd "%SCRIPT_DIR%..\build"
set SYS_PATH=%CD%\AsmTaskMgr.sys
popd

echo =========================================================
echo  AsmTaskMgr Driver Install
echo  Driver: %SYS_PATH%
echo =========================================================

REM --- Create the service ---
echo [1/2] Creating service...
sc create "%DRV_NAME%" ^
    type= kernel ^
    start= demand ^
    error= ignore ^
    binPath= "%SYS_PATH%" ^
    DisplayName= "%DRV_DISPLAY%" > nul 2>&1

REM Ignore error (service may already exist)
echo         (OK or already exists)

REM --- Start the service ---
echo [2/2] Starting service...
sc start "%DRV_NAME%"
if errorlevel 1 (
    echo [ERROR] Failed to start driver. Possible causes:
    echo   - Test signing mode not enabled ^(run enable_testsign.bat and reboot^)
    echo   - Driver file is corrupt or invalid
    echo   - Another instance is already running
    sc query "%DRV_NAME%"
    pause
    exit /b 1
)

echo.
echo =========================================================
echo  Driver started successfully.
sc query "%DRV_NAME%"
echo =========================================================
pause
