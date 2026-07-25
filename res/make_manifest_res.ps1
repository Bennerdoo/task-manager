# =============================================================
#  make_manifest_res.ps1
#  Generates build\manifest.res from res\manifest.xml
#  No Windows SDK required.  Run from workspace root.
# =============================================================
param(
    [string]$ManifestPath = "res\manifest.xml",
    [string]$OutPath      = "build\manifest.res"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Read manifest XML as raw bytes (no BOM) ----------------
$xmlBytes = [System.IO.File]::ReadAllBytes($ManifestPath)
$dataSize = $xmlBytes.Length

# ---- Helper: little-endian DWORD ----------------------------
function DWORD([uint32]$v) {
    return [byte[]]@($v -band 0xFF, ($v -shr 8) -band 0xFF,
                      ($v -shr 16) -band 0xFF, ($v -shr 24) -band 0xFF)
}
# ---- Helper: little-endian WORD -----------------------------
function WORD([uint16]$v) {
    return [byte[]]@($v -band 0xFF, ($v -shr 8) -band 0xFF)
}

# =============================================================
#  .res binary format (per Microsoft docs):
#
#  RESOURCE_HEADER:
#    DataSize     DWORD
#    HeaderSize   DWORD  (= 32 for ordinal type+name)
#    Type         WORD 0xFFFF + WORD typeId   (ordinal)
#    Name         WORD 0xFFFF + WORD nameId   (ordinal)
#    DataVersion  DWORD
#    MemoryFlags  WORD
#    LanguageId   WORD
#    Version      DWORD
#    Characteristics DWORD
#  [Data bytes]
#  [Padding to DWORD boundary]
# =============================================================

$res = [System.Collections.Generic.List[byte]]::new()

# ---- Entry 1: Empty resource (null type/name) ---------------
$res.AddRange((DWORD 0))          # DataSize = 0
$res.AddRange((DWORD 32))         # HeaderSize = 32
$res.AddRange((WORD  0xFFFF))     # Type ordinal marker
$res.AddRange((WORD  0x0000))     # Type = 0
$res.AddRange((WORD  0xFFFF))     # Name ordinal marker
$res.AddRange((WORD  0x0000))     # Name = 0
$res.AddRange((DWORD 0))          # DataVersion
$res.AddRange((WORD  0x0000))     # MemoryFlags
$res.AddRange((WORD  0x0000))     # LanguageId
$res.AddRange((DWORD 0))          # Version
$res.AddRange((DWORD 0))          # Characteristics

# ---- Entry 2: RT_MANIFEST (type 24, name 1, lang 0x0409) ----
$res.AddRange((DWORD ([uint32]$dataSize)))  # DataSize
$res.AddRange((DWORD 32))                  # HeaderSize = 32
$res.AddRange((WORD  0xFFFF))              # Type ordinal marker
$res.AddRange((WORD  0x0018))              # Type = 24 (RT_MANIFEST)
$res.AddRange((WORD  0xFFFF))              # Name ordinal marker
$res.AddRange((WORD  0x0001))              # Name = 1 (CREATEPROCESS_MANIFEST_RESOURCE_ID)
$res.AddRange((DWORD 0))                   # DataVersion
$res.AddRange((WORD  0x1030))              # MemoryFlags
$res.AddRange((WORD  0x0409))              # LanguageId = English (US)
$res.AddRange((DWORD 0))                   # Version
$res.AddRange((DWORD 0))                   # Characteristics

# ---- Manifest data ------------------------------------------
$res.AddRange($xmlBytes)

# ---- Pad to DWORD boundary ----------------------------------
$pad = (4 - ($dataSize % 4)) % 4
for ($i = 0; $i -lt $pad; $i++) { $res.Add(0) }

# ---- Write output -------------------------------------------
$outDir = [System.IO.Path]::GetDirectoryName($OutPath)
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
[System.IO.File]::WriteAllBytes($OutPath, $res.ToArray())

Write-Host "[manifest] $OutPath written ($($res.Count) bytes, manifest=$dataSize bytes)"
