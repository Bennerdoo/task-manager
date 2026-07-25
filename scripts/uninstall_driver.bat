@echo off
REM ==========================================================================
REM  uninstall_driver.bat  —  AsmTaskMgr
REM  Stops and removes the AsmTaskMgr.sys kernel driver service.
REM  Run as Administrator.
REM ==========================================================================

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run this script as Administrator.
    pause
    exit /b 1
)

set DRV_NAME=AsmTaskMgrDrv

echo =========================================================
echo  AsmTaskMgr Driver Uninstall
echo =========================================================

echo [1/2] Stopping service...
sc stop "%DRV_NAME%" > nul 2>&1
timeout /t 2 /nobreak > nul

echo [2/2] Deleting service...
sc delete "%DRV_NAME%"
if errorlevel 1 (
    echo [WARN] Service may not have existed or was already removed.
)

echo.
echo =========================================================
echo  Driver service removed.
echo  (The .sys file in build\ is not deleted.)
echo =========================================================
pause
