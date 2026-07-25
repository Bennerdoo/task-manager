# AsmTaskMgr

**Lightweight Windows Task Manager — written entirely in x86-64 NASM Assembly**

No C runtime. No DLL bloat. Two files: a GUI app and a kernel driver.

---

## What it does

| Feature | Detail |
|---|---|
| **List all processes** | PID, Name, CPU%, Memory, Username |
| **Kill any process** | 3-tier cascade (see below) |
| **Kill protected processes** | Windows Defender, LSASS, anti-cheat via ring-0 driver |
| **Set process priority** | High / Normal / Idle |
| **Filter processes** | Live search/filter box |
| **Sort columns** | Click any column header |
| **Auto-refresh** | Every 2 seconds |
| **Dark theme** | `#0D1117` background, `#C9D1D9` text |

### Three-Tier Kill Cascade
```
Tier 1  Win32   TerminateProcess       — standard processes
Tier 2  ntdll   NtTerminateProcess     — system/service processes
Tier 3  ring-0  ZwTerminateProcess     — PPL-protected (Defender, LSASS)
```

---

## Toolchain

| Tool | Location |
|---|---|
| **NASM 2.16.03** | `nasm-2.16.03\nasm.exe` |
| **GoLink** | `golink\GoLink.exe` |

Both are already in the workspace. No installation needed.

---

## Project Structure

```
task-manager/
├── nasm-2.16.03/       ← Assembler
├── golink/             ← Linker
├── src/                ← User-mode assembly (9 files)
│   ├── main.asm        ← WinMainCRTStartup, message loop
│   ├── window.asm      ← WndProc, dark theme
│   ├── listview.asm    ← ListView management
│   ├── process.asm     ← Process enumeration
│   ├── killer.asm      ← 3-tier kill engine + driver loader
│   ├── privilege.asm   ← SeDebugPrivilege + UAC re-launch
│   ├── memory.asm      ← RAM stats
│   ├── cpu.asm         ← CPU % calculation
│   └── strings.asm     ← All data, globals, constants
├── driver/             ← Kernel-mode assembly (4 files)
│   ├── drv_main.asm    ← DriverEntry, dispatch table
│   ├── drv_ioctl.asm   ← IRP_MJ_DEVICE_CONTROL handler
│   ├── drv_kill.asm    ← PsLookup + ObOpen + ZwTerminate
│   └── drv_strings.asm ← Device/symlink name strings
├── res/
│   ├── manifest.xml        ← UAC requireAdministrator
│   └── make_manifest_res.ps1  ← Generates manifest.res (no SDK needed)
├── scripts/
│   ├── enable_testsign.bat     ← One-time: enable test signing
│   ├── install_driver.bat      ← Manual driver install
│   └── uninstall_driver.bat    ← Remove driver service
├── build/              ← Output: AsmTaskMgr.exe + AsmTaskMgr.sys
└── build.bat           ← Master build script
```

---

## Build Instructions

### Prerequisites
- Windows 10 or 11 (x64)
- PowerShell 5+ (included in all modern Windows)
- No Visual Studio, no Windows SDK, no .NET — nothing extra

### Step 1 — Enable Test Signing (first time only, requires reboot)

> This allows the unsigned kernel driver to load.

```batch
scripts\enable_testsign.bat
```
Then **reboot**.

### Step 2 — Build

Open a **Command Prompt** in the `task-manager\` directory and run:

```batch
build.bat
```

Expected output:
```
[1/3] Assembling user-mode source files...
  Assembling src\strings.asm...
  ...
[OK] All user-mode modules assembled.

[2/3] Linking AsmTaskMgr.exe...
[OK] build\AsmTaskMgr.exe linked.

[3/3] Building AsmTaskMgr.sys kernel driver...
  ...
[OK] build\AsmTaskMgr.sys linked.

BUILD SUCCESSFUL
  User-mode app:  build\AsmTaskMgr.exe
  Kernel driver:  build\AsmTaskMgr.sys
```

### Step 3 — Run

Double-click `build\AsmTaskMgr.exe`  
→ UAC prompt appears → click **Yes**  
→ The app loads, installs the kernel driver automatically, and shows all processes.

> **Both files must be in the same folder**: the app locates the driver by replacing `.exe` with `.sys` in its own path.

---

## Driver Details

The kernel driver (`AsmTaskMgr.sys`) is automatically:
- **Installed** (via SCManager) when the app starts
- **Started** (`sc start`) on launch
- **Stopped + Deleted** when the app exits cleanly

### IOCTL Interface

```
Device:   \\.\AsmTaskMgrDrv
IOCTL:    0x00222000  (IOCTL_KILL_PROCESS)
Input:    DWORD  pid
Output:   DWORD  NTSTATUS from ZwTerminateProcess
```

### Why ring-0 kills PPL processes

PPL (Protected Process Light) is enforced only at the user-mode/kernel boundary.  
In kernel mode, `ObOpenObjectByPointer(..., KernelMode, ...)` bypasses all PPL  
access checks → the driver can open and terminate any process including:
- `MsMpEng.exe` (Windows Defender)
- `lsass.exe` (Local Security Authority)
- Anti-cheat engines running as PPL

### Processes that CANNOT be killed (even from ring-0)

| Process | Reason |
|---|---|
| `securekernel.exe` | Runs in VTL 1 (Secure World / VBS) |
| `hvix64.exe` | Hypervisor (ring -1) |
| Signed kernel-mode AC drivers | Would need their own ring-0 countermeasure |

---

## Technical Notes

### Calling Convention (Microsoft x64 ABI)
- Args 1–4: `RCX`, `RDX`, `R8`, `R9`  
- Args 5+: stack at `[rsp+32]`, `[rsp+40]`, …
- **32-byte shadow space** before every `call`
- Stack 16-byte aligned before `call`
- Callee-saved: `RBX`, `RBP`, `RSI`, `RDI`, `R12–R15`

### No CRT
The binary has zero dependency on `msvcrt.dll`.  
Estimated binary sizes:
- `AsmTaskMgr.exe` ≈ 60–90 KB
- `AsmTaskMgr.sys` ≈ 10–20 KB

### GoLink driver flags
```batch
GoLink /subsystem:native /entry DriverEntry ... ntoskrnl.exe
```
GoLink matches `extern` symbols to exports in `ntoskrnl.exe` at link time.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `build.bat` reports NASM error | Check `bits 64` and `default rel` at top of each .asm |
| GoLink: unresolved symbol | Check the DLL name on GoLink command line |
| Driver fails to start | Re-run `scripts\enable_testsign.bat` and reboot |
| UAC prompt doesn't appear | App falls back to programmatic runas re-launch |
| Process kill fails all 3 tiers | Process is in VTL1/hypervisor space — unkillable |
| `Test Mode` watermark on desktop | Normal side-effect of test signing; disable with `bcdedit /set testsigning off` + reboot |
