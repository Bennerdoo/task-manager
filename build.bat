@echo off
setlocal enabledelayedexpansion
title AsmTaskMgr Build System

echo ============================================================
echo   AsmTaskMgr ^| x86-64 NASM Assembly Build System
echo ============================================================
echo.

REM ============================================================
REM  Paths
REM ============================================================
set NASM=nasm-2.16.03\nasm.exe
set GOLINK=golink\GoLink.exe
set SRC=src
set DRV=driver
set RES=res
set OUT=build

REM ============================================================
REM  Sanity checks
REM ============================================================
if not exist "%NASM%" (
    echo [ERROR] NASM not found at: %NASM%
    echo         Make sure nasm-2.16.03\nasm.exe exists.
    goto :build_fail
)
if not exist "%GOLINK%" (
    echo [ERROR] GoLink not found at: %GOLINK%
    echo         Make sure golink\GoLink.exe exists.
    goto :build_fail
)

REM ============================================================
REM  Create output directory
REM ============================================================
if not exist "%OUT%" mkdir "%OUT%"

REM ============================================================
REM  Step 0: Generate manifest.res (no Windows SDK needed)
REM ============================================================
echo [0/3] Generating UAC manifest resource...
powershell -NoProfile -ExecutionPolicy Bypass -File "%RES%\make_manifest_res.ps1" ^
    -ManifestPath "%RES%\manifest.xml" -OutPath "%OUT%\manifest.res"
if errorlevel 1 (
    echo [WARN] Manifest generation failed. App will still work, but UAC prompt
    echo        may not appear automatically ^(elevation logic handled in code^).
    set MANIFEST_RES=
) else (
    set MANIFEST_RES=%OUT%\manifest.res
    echo [OK] manifest.res generated.
)
echo.

REM ============================================================
REM  Step 1: Assemble user-mode modules
REM ============================================================
echo [1/3] Assembling user-mode source files...

call :asm_obj %SRC%\strings.asm   %OUT%\strings.obj   || goto :build_fail
call :asm_obj %SRC%\privilege.asm %OUT%\privilege.obj || goto :build_fail
call :asm_obj %SRC%\memory.asm    %OUT%\memory.obj    || goto :build_fail
call :asm_obj %SRC%\cpu.asm       %OUT%\cpu.obj       || goto :build_fail
call :asm_obj %SRC%\process.asm   %OUT%\process.obj   || goto :build_fail
call :asm_obj %SRC%\killer.asm    %OUT%\killer.obj    || goto :build_fail
call :asm_obj %SRC%\listview.asm  %OUT%\listview.obj  || goto :build_fail
call :asm_obj %SRC%\window.asm    %OUT%\window.obj    || goto :build_fail
call :asm_obj %SRC%\main.asm      %OUT%\main.obj      || goto :build_fail

echo [OK] All user-mode modules assembled.
echo.

REM ============================================================
REM  Step 2: Link user-mode EXE
REM ============================================================
echo [2/3] Linking AsmTaskMgr.exe...

REM  Build the GoLink command (with or without manifest.res)
set GOLINK_USER_OBJS=^
    %OUT%\main.obj %OUT%\window.obj %OUT%\listview.obj ^
    %OUT%\process.obj %OUT%\killer.obj %OUT%\privilege.obj ^
    %OUT%\memory.obj %OUT%\cpu.obj %OUT%\strings.obj

set GOLINK_USER_DLLS=^
    kernel32.dll user32.dll gdi32.dll comctl32.dll ^
    psapi.dll ntdll.dll advapi32.dll shell32.dll

if defined MANIFEST_RES (
    %GOLINK% /gui /entry WinMainCRTStartup ^
        %GOLINK_USER_OBJS% ^
        %GOLINK_USER_DLLS% ^
        /res %MANIFEST_RES% ^
        /fo %OUT%\AsmTaskMgr.exe
) else (
    %GOLINK% /gui /entry WinMainCRTStartup ^
        %GOLINK_USER_OBJS% ^
        %GOLINK_USER_DLLS% ^
        /fo %OUT%\AsmTaskMgr.exe
)

if errorlevel 1 (
    echo [ERROR] Linking AsmTaskMgr.exe FAILED.
    goto :build_fail
)
echo [OK] build\AsmTaskMgr.exe linked.
echo.

REM ============================================================
REM  Step 3: Assemble + link kernel driver
REM ============================================================
echo [3/3] Building AsmTaskMgr.sys kernel driver...

call :asm_obj %DRV%\drv_strings.asm %OUT%\drv_strings.obj || goto :build_fail
call :asm_obj %DRV%\drv_kill.asm    %OUT%\drv_kill.obj    || goto :build_fail
call :asm_obj %DRV%\drv_ioctl.asm   %OUT%\drv_ioctl.obj   || goto :build_fail
call :asm_obj %DRV%\drv_main.asm    %OUT%\drv_main.obj    || goto :build_fail

echo Linking driver...
%GOLINK% /subsystem:native /entry DriverEntry ^
    %OUT%\drv_main.obj %OUT%\drv_ioctl.obj ^
    %OUT%\drv_kill.obj %OUT%\drv_strings.obj ^
    ntoskrnl.exe ^
    /fo %OUT%\AsmTaskMgr.sys

if errorlevel 1 (
    echo [ERROR] Linking AsmTaskMgr.sys FAILED.
    goto :build_fail
)
echo [OK] build\AsmTaskMgr.sys linked.
echo.

REM ============================================================
REM  Success!
REM ============================================================
echo ============================================================
echo   BUILD SUCCESSFUL
echo ============================================================
echo   User-mode app:   %OUT%\AsmTaskMgr.exe
echo   Kernel driver:   %OUT%\AsmTaskMgr.sys
echo.
echo   BEFORE RUNNING:
echo   1. Enable test signing (once, requires reboot):
echo        scripts\enable_testsign.bat
echo   2. Copy both files to the same folder (if moving them)
echo   3. Run AsmTaskMgr.exe  (UAC will prompt for admin)
echo ============================================================
goto :eof

REM ============================================================
:build_fail
echo.
echo ============================================================
echo   BUILD FAILED  — check errors above
echo ============================================================
exit /b 1

REM ============================================================
REM  Subroutine: assemble one .asm → .obj
REM  Usage: call :asm_obj <source> <output>
REM ============================================================
:asm_obj
echo   Assembling %~1...
"%NASM%" -f win64 -Werror "%~1" -o "%~2"
if errorlevel 1 (
    echo [ERROR] Assembly failed: %~1
    exit /b 1
)
exit /b 0
