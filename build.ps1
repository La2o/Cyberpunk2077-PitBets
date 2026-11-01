# Builds dist/PitBets-<version>.zip laid out for Nexus / Vortex / MO2:
#   bin/x64/plugins/cyber_engine_tweaks/mods/PitBets/*.lua
# Entries are written with forward slashes (Compress-Archive on PS 5.1 uses
# backslashes, which some mod managers reject).
param([string]$Version = "1.0.0")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = $PSScriptRoot
$dist = Join-Path $root "dist"
$zip = Join-Path $dist "PitBets-$Version.zip"
$prefix = "bin/x64/plugins/cyber_engine_tweaks/mods/PitBets/"

New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path $zip) { Remove-Item -Force $zip }
$archive = [System.IO.Compression.ZipFile]::Open($zip, "Create")
try {
  foreach ($f in Get-ChildItem (Join-Path $root "PitBets") -Filter *.lua) {
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $prefix + $f.Name)
  }
} finally { $archive.Dispose() }
Write-Output "Built $zip"
