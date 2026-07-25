@echo off
title AsmTaskMgr Build System

echo ============================================================
echo   AsmTaskMgr ^| x86-64 NASM Assembly Build System
echo ============================================================
echo.

set NASM=nasm-2.16.03\nasm.exe
set GOLINK=golink\GoLink.exe
set SRC=src
set DRV=driver
set RES=res
set OUT=build

if not exist "%NASM%" (
    echo [ERROR] NASM not found at: %NASM%
    goto :build_fail
)
if not exist "%GOLINK%" (
    echo [ERROR] GoLink not found at: %GOLINK%
    goto :build_fail
)

if not exist "%OUT%" mkdir "%OUT%"

echo [0/3] Generating UAC manifest resource...
powershell -NoProfile -ExecutionPolicy Bypass -File "%RES%\make_manifest_res.ps1" -ManifestPath "%RES%\manifest.xml" -OutPath "%OUT%\manifest.res"
if errorlevel 1 (
    echo [WARN] Manifest generation failed.
    set MANIFEST_RES=
) else (
    set MANIFEST_RES=%OUT%\manifest.res
    echo [OK] manifest.res generated.
)
echo.

echo [1/3] Assembling user-mode source files...

"%NASM%" -f win64 -Werror "%SRC%\strings.asm" -o "%OUT%\strings.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\privilege.asm" -o "%OUT%\privilege.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\memory.asm" -o "%OUT%\memory.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\cpu.asm" -o "%OUT%\cpu.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\process.asm" -o "%OUT%\process.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\killer.asm" -o "%OUT%\killer.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\listview.asm" -o "%OUT%\listview.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\window.asm" -o "%OUT%\window.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%SRC%\main.asm" -o "%OUT%\main.obj"
if errorlevel 1 goto :build_fail

echo [OK] All user-mode modules assembled.
echo.

echo [2/3] Linking AsmTaskMgr.exe...

if exist "%OUT%\manifest.res" (
    "%GOLINK%" /entry WinMainCRTStartup "%OUT%\main.obj" "%OUT%\window.obj" "%OUT%\listview.obj" "%OUT%\process.obj" "%OUT%\killer.obj" "%OUT%\privilege.obj" "%OUT%\memory.obj" "%OUT%\cpu.obj" "%OUT%\strings.obj" "%OUT%\manifest.res" kernel32.dll user32.dll gdi32.dll comctl32.dll psapi.dll ntdll.dll advapi32.dll shell32.dll /fo "%OUT%\AsmTaskMgr.exe"
) else (
    "%GOLINK%" /entry WinMainCRTStartup "%OUT%\main.obj" "%OUT%\window.obj" "%OUT%\listview.obj" "%OUT%\process.obj" "%OUT%\killer.obj" "%OUT%\privilege.obj" "%OUT%\memory.obj" "%OUT%\cpu.obj" "%OUT%\strings.obj" kernel32.dll user32.dll gdi32.dll comctl32.dll psapi.dll ntdll.dll advapi32.dll shell32.dll /fo "%OUT%\AsmTaskMgr.exe"
)

if errorlevel 1 (
    echo [ERROR] Linking AsmTaskMgr.exe FAILED.
    goto :build_fail
)
echo [OK] build\AsmTaskMgr.exe linked.
echo.

echo [3/3] Building AsmTaskMgr.sys kernel driver...

"%NASM%" -f win64 -Werror "%DRV%\drv_strings.asm" -o "%OUT%\drv_strings.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%DRV%\drv_kill.asm" -o "%OUT%\drv_kill.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%DRV%\drv_ioctl.asm" -o "%OUT%\drv_ioctl.obj"
if errorlevel 1 goto :build_fail

"%NASM%" -f win64 -Werror "%DRV%\drv_main.asm" -o "%OUT%\drv_main.obj"
if errorlevel 1 goto :build_fail

echo Linking driver...
"%GOLINK%" /driver /entry DriverEntry "%OUT%\drv_main.obj" "%OUT%\drv_ioctl.obj" "%OUT%\drv_kill.obj" "%OUT%\drv_strings.obj" ntoskrnl.exe /fo "%OUT%\AsmTaskMgr.sys"

if errorlevel 1 (
    echo [ERROR] Linking AsmTaskMgr.sys FAILED.
    goto :build_fail
)
echo [OK] build\AsmTaskMgr.sys linked.
echo.

echo ============================================================
echo   BUILD SUCCESSFUL
echo ============================================================
echo   User-mode app:   %OUT%\AsmTaskMgr.exe
echo   Kernel driver:   %OUT%\AsmTaskMgr.sys
echo ============================================================
exit /b 0

:build_fail
echo.
echo ============================================================
echo   BUILD FAILED — check errors above
echo ============================================================
exit /b 1
