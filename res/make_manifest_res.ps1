# =============================================================================
#  make_manifest_res.ps1  —  AsmTaskMgr
#  Builds a binary .res file embedding manifest.xml as RT_MANIFEST (type 24).
#  Uses [System.BitConverter] to avoid PowerShell operator type issues.
#  Usage:
#    powershell -File make_manifest_res.ps1 -ManifestPath res\manifest.xml -OutPath build\manifest.res
# =============================================================================
param(
    [string]$ManifestPath = "res\manifest.xml",
    [string]$OutPath      = "build\manifest.res"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Read the manifest XML bytes ----
if (-not (Test-Path $ManifestPath)) {
    Write-Error "Manifest not found: $ManifestPath"
    exit 1
}
$xmlBytes  = [System.IO.File]::ReadAllBytes((Resolve-Path $ManifestPath))
$dataSize  = [uint32]$xmlBytes.Length

# ---- Helper: append little-endian integers via BitConverter ----
function Add-U32 {
    param($list, [uint32]$v)
    $list.AddRange([System.BitConverter]::GetBytes($v))
}
function Add-U16 {
    param($list, [uint16]$v)
    $list.AddRange([System.BitConverter]::GetBytes($v))
}

$res = [System.Collections.Generic.List[byte]]::new()

# ---- Empty/padding resource header (required first entry in .res files) ----
# DataSize = 0, HeaderSize = 32
Add-U32 $res ([uint32]0)          # DataSize
Add-U32 $res ([uint32]32)         # HeaderSize
Add-U16 $res ([uint16]0xFFFF)     # TYPE: ordinal marker
Add-U16 $res ([uint16]0x0000)     # TYPE: 0
Add-U16 $res ([uint16]0xFFFF)     # NAME: ordinal marker
Add-U16 $res ([uint16]0x0000)     # NAME: 0
Add-U32 $res ([uint32]0)          # DataVersion
Add-U16 $res ([uint16]0x0000)     # MemoryFlags
Add-U16 $res ([uint16]0x0000)     # LanguageId
Add-U32 $res ([uint32]0)          # Version
Add-U32 $res ([uint32]0)          # Characteristics

# ---- RT_MANIFEST resource (type=24/0x18, name=1, lang=0x0409 en-US) ----
Add-U32 $res $dataSize            # DataSize = xml byte length
Add-U32 $res ([uint32]32)         # HeaderSize = 32
Add-U16 $res ([uint16]0xFFFF)     # TYPE: ordinal marker
Add-U16 $res ([uint16]0x0018)     # TYPE: 24 = RT_MANIFEST
Add-U16 $res ([uint16]0xFFFF)     # NAME: ordinal marker
Add-U16 $res ([uint16]0x0001)     # NAME: 1 (CREATEPROCESS_MANIFEST_RESOURCE_ID)
Add-U32 $res ([uint32]0)          # DataVersion
Add-U16 $res ([uint16]0x1030)     # MemoryFlags (MOVEABLE|PURE|PRELOAD)
Add-U16 $res ([uint16]0x0409)     # LanguageId: en-US
Add-U32 $res ([uint32]0)          # Version
Add-U32 $res ([uint32]0)          # Characteristics

# ---- Raw manifest XML data ----
$res.AddRange($xmlBytes)

# ---- Pad data section to DWORD boundary ----
$pad = [int]((4 - ($dataSize % 4)) % 4)
for ($i = 0; $i -lt $pad; $i++) { $res.Add([byte]0) }

# ---- Write output ----
$outDir = Split-Path $OutPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
[System.IO.File]::WriteAllBytes($OutPath, $res.ToArray())
Write-Host "[manifest] Written: $OutPath ($($res.Count) bytes, manifest=$dataSize bytes)"
