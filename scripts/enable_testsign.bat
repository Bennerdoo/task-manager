@echo off
REM ==========================================================================
REM  enable_testsign.bat  —  AsmTaskMgr
REM  Enables Windows Test Signing Mode so the unsigned AsmTaskMgr.sys driver
REM  can be loaded without a production EV code-signing certificate.
REM
REM  Run this script ONCE as Administrator, then REBOOT.
REM  After reboot, a "Test Mode" watermark appears in the desktop corner.
REM
REM  To re-enable normal signing enforcement, run:
REM    bcdedit /set testsigning off
REM    bcdedit /set nointegritychecks off
REM  Then reboot again.
REM ==========================================================================

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] This script must be run as Administrator.
    echo         Right-click the script and choose "Run as administrator".
    pause
    exit /b 1
)

echo =========================================================
echo  AsmTaskMgr — Enable Driver Test Signing Mode
echo =========================================================
echo.
echo  This will modify your boot configuration to allow
echo  unsigned kernel drivers to load.
echo.
echo  A "Test Mode" watermark will appear on your desktop.
echo  You will need to REBOOT for changes to take effect.
echo.
set /p CONFIRM=  Continue? (Y/N): 
if /i not "%CONFIRM%"=="Y" (
    echo Cancelled.
    exit /b 0
)

echo.
echo [1/2] Enabling test signing...
bcdedit /set testsigning on
if errorlevel 1 goto :fail

echo [2/2] Disabling integrity checks (belt and suspenders)...
bcdedit /set nointegritychecks on
if errorlevel 1 (
    echo [WARN] nointegritychecks command failed ^(normal on some systems^).
)

echo.
echo =========================================================
echo  DONE.  Please REBOOT your system now.
echo  After reboot, run AsmTaskMgr.exe to start.
echo =========================================================
pause
exit /b 0

:fail
echo [ERROR] bcdedit failed. Make sure you are running as Administrator.
pause
exit /b 1
