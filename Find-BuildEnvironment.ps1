<#
.SYNOPSIS
    Find-BuildEnvironment.ps1 — CLI wrapper for the WindowsBuildToolsFinder module.

.DESCRIPTION
    Discovers, lists, and optionally activates Windows build environments from the
    command line. Supports Visual Studio (all editions/versions), Windows SDK,
    MinGW-w64, MSYS2, TDM-GCC-64, Clang/LLVM, Strawberry Perl, and CMake.

.PARAMETER List
    List all detected build environments without activating any.

.PARAMETER Type
    Filter by toolchain type: VS, WindowsSDK, MinGW, MSYS2, TDM-GCC, LLVM,
    StrawberryPerl, CMake. Can be specified multiple times.

.PARAMETER Edition
    Filter Visual Studio by edition: Enterprise, Professional, Community, BuildTools.

.PARAMETER MinVSVersion
    Minimum Visual Studio major version (e.g. 17 for VS 2022).

.PARAMETER Architecture
    Target architecture for activation: x86, x64 (default), arm, arm64.

.PARAMETER Activate
    Activate the first matching environment in the current session.
    NOTE: Because child processes cannot modify the parent's environment,
    use dot-sourcing to apply changes to your current shell:
        . .\Find-BuildEnvironment.ps1 -Activate

.PARAMETER Interactive
    Show a numbered menu and let the user pick an environment to activate.
    Implies -Activate.

.PARAMETER RequireCppTools
    Only consider environments that have C++ build tools (vcvarsall / g++ / clang++).

.PARAMETER Detailed
    Show install paths and available scripts in the listing.

.PARAMETER Json
    Output results as JSON instead of the formatted table.

.PARAMETER Name
    Wildcard filter on the environment name.

.EXAMPLE
    # List everything
    .\Find-BuildEnvironment.ps1 -List

.EXAMPLE
    # List only VS installations with C++ tools
    .\Find-BuildEnvironment.ps1 -List -Type VS -RequireCppTools

.EXAMPLE
    # Activate the newest VS 2022 x64 environment (dot-source!)
    . .\Find-BuildEnvironment.ps1 -Activate -Type VS -MinVSVersion 17 -Architecture x64

.EXAMPLE
    # Interactive picker (dot-source!)
    . .\Find-BuildEnvironment.ps1 -Interactive

.EXAMPLE
    # Output as JSON for scripting
    .\Find-BuildEnvironment.ps1 -List -Json | ConvertFrom-Json

.NOTES
    This script must be dot-sourced (. .\Find-BuildEnvironment.ps1 ...) when
    -Activate or -Interactive is used, so that environment changes persist in
    the calling shell.
#>

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Activate')]
    [switch]$Activate,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [ValidateSet('VS','WindowsSDK','MinGW','MSYS2','TDM-GCC','LLVM','StrawberryPerl','CMake')]
    [string[]]$Type,

    [ValidateSet('Enterprise','Professional','Community','BuildTools','*')]
    [string]$Edition = '*',

    [ValidateRange(1,99)]
    [int]$MinVSVersion = 0,

    [ValidateSet('x86','x64','arm','arm64')]
    [string]$Architecture = 'x64',

    [switch]$RequireCppTools,
    [switch]$Detailed,
    [switch]$Json,

    [string]$Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Locate and import the module ───────────────────────────────────────────

$moduleDir = Join-Path $PSScriptRoot 'WindowsBuildToolsFinder'
$modulePsd = Join-Path $moduleDir 'WindowsBuildToolsFinder.psd1'

if (Test-Path -LiteralPath $modulePsd) {
    Import-Module $modulePsd -Force -Verbose:$false
} elseif (Get-Module -ListAvailable -Name WindowsBuildToolsFinder) {
    Import-Module WindowsBuildToolsFinder -Force -Verbose:$false
} else {
    Write-Error @"
WindowsBuildToolsFinder module not found.
Expected location: $modulePsd
Install it with:  Install-Module WindowsBuildToolsFinder
or clone the repo alongside this script.
"@
    exit 1
}

# ── Collect environments ───────────────────────────────────────────────────

Write-Host 'Scanning for build environments…' -ForegroundColor DarkGray

$getParams = @{ RequireCppTools = $RequireCppTools }
if ($Type) { $getParams['Type'] = $Type }

# VS-specific filters applied after collection
$allEnvs = Get-AllBuildEnvironments @getParams

if ($MinVSVersion -gt 0) {
    $allEnvs = $allEnvs | Where-Object {
        $_.Type -ne 'VS' -or ([int]($_.Version -split '\.')[0]) -ge $MinVSVersion
    }
}
if ($Edition -ne '*') {
    $allEnvs = $allEnvs | Where-Object {
        $_.Type -ne 'VS' -or $_.Edition -like $Edition
    }
}
if ($Name) {
    $allEnvs = $allEnvs | Where-Object { $_.Name -like $Name }
}

if (-not $allEnvs) {
    Write-Warning 'No build environments matched the specified filters.'
    exit 0
}

# ── Output ─────────────────────────────────────────────────────────────────

if ($Json) {
    $allEnvs | ConvertTo-Json -Depth 5
    exit 0
}

$allEnvs | Write-BuildEnvironmentTable -Detailed:$Detailed

# ── Activate ───────────────────────────────────────────────────────────────

if ($Interactive -or $PSCmdlet.ParameterSetName -eq 'Interactive') {
    $selected = $allEnvs | Select-BuildEnvironment -Interactive
    if ($selected) {
        Invoke-BuildEnvironment -Toolchain $selected -Architecture $Architecture
    }
} elseif ($Activate -or $PSCmdlet.ParameterSetName -eq 'Activate') {
    $selected = $allEnvs | Select-Object -First 1
    if ($selected) {
        Write-Host "Activating: $($selected.Name)" -ForegroundColor Yellow
        Invoke-BuildEnvironment -Toolchain $selected -Architecture $Architecture
    }
}
