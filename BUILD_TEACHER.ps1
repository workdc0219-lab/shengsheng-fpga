param(
    [string]$ProjectRoot,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
# Select the module manifest belonging to this PowerShell installation.
# A Python parent may inherit another edition's module search path.
$utilityManifest = Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1'
Import-Module -Name $utilityManifest -Force -ErrorAction Stop
$null = Get-Command Get-FileHash -ErrorAction Stop
if ($CheckOnly) {
    Write-Output 'POWERSHELL_BUILD_BOOTSTRAP_PASS'
    exit 0
}
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw 'ProjectRoot is required' }
$project = [IO.Path]::GetFullPath($ProjectRoot)
$canonical = Join-Path $project 'board_a/scripts/run_td.ps1'
if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) { throw 'Teacher build script missing' }
& $canonical -PlaceSeed 1
