# windows-buildtools-finder

A PowerShell module and CLI script that discovers **every** Windows build environment on a machine and can activate any of them in the current PowerShell session.

---

## Supported toolchains

| Type | Details |
|------|---------|
| **Visual Studio** | Enterprise, Professional, Community, Build Tools — versions 2012 through 2022+ |
| **Windows SDK** | All installed versions |
| **MinGW-w64 / MinGW32** | Standalone installs, Chocolatey, Scoop |
| **MSYS2** | mingw64, mingw32, ucrt64, clang64 environments |
| **TDM-GCC-64 / 32** | Standalone + registry detection |
| **Clang / LLVM** | Standalone, Chocolatey, Scoop, MSYS2-bundled |
| **Strawberry Perl** | Built-in GCC toolchain + Perl |
| **CMake** | Standalone, VS-bundled, MSYS2, Chocolatey, Scoop |

---

## Installation

### Option A — Use directly from this repository

```powershell
git clone https://github.com/snodeplannen/windows-buildools-finder.git
cd windows-buildools-finder
```

### Option B — Install the module to your PowerShell module path

```powershell
Copy-Item -Recurse .\WindowsBuildToolsFinder `
    "$($env:PSModulePath -split ';' | Select-Object -First 1)\WindowsBuildToolsFinder"
Import-Module WindowsBuildToolsFinder
```

---

## Quick start

### List everything

```powershell
.\Find-BuildEnvironment.ps1 -List
```

### List only Visual Studio installations with C++ tools

```powershell
.\Find-BuildEnvironment.ps1 -List -Type VS -RequireCppTools
```

### Activate the newest VS 2022 x64 environment

> **Important:** use dot-sourcing (`. .\...`) so the environment changes apply to your current shell.

```powershell
. .\Find-BuildEnvironment.ps1 -Activate -Type VS -MinVSVersion 17 -Architecture x64
```

### Interactive picker

```powershell
. .\Find-BuildEnvironment.ps1 -Interactive
```

### Output as JSON (for scripting)

```powershell
.\Find-BuildEnvironment.ps1 -List -Json | ConvertFrom-Json
```

---

## Module API

### Discovery functions

```powershell
# Visual Studio (all editions, all versions)
Get-VSBuildEnvironments
Get-VSBuildEnvironments -RequireCppTools -MinVersion 17 -Edition Community

# Windows SDK
Get-WindowsSDKs

# MinGW / MSYS2 / TDM-GCC
Get-MinGWInstallations
Get-MinGWInstallations -Type MSYS2

# Clang / LLVM
Get-ClangLLVMInstallations

# Strawberry Perl
Get-StrawberryPerlEnvironment

# CMake
Get-CMakeInstallations

# Everything at once
Get-AllBuildEnvironments
Get-AllBuildEnvironments -Type VS,CMake -RequireCppTools
```

### Activation

```powershell
# Activate a .bat file (vcvarsall, VsDevCmd, SetEnv.cmd, …) and import env vars
Import-VSEnvironment -BatFilePath 'C:\...\vcvarsall.bat' -Arguments 'x64'
Import-VSEnvironment -BatFilePath $path -Arguments 'x64' -PassThru    # returns changed vars
Import-VSEnvironment -BatFilePath $path -Arguments 'x64' -WhatIf      # preview only

# Activate any toolchain object
$tc = Get-AllBuildEnvironments -Type VS | Select-Object -First 1
Invoke-BuildEnvironment -Toolchain $tc -Architecture x64

# Pipeline
Get-MinGWInstallations | Select-Object -First 1 | Invoke-BuildEnvironment
```

### Selection

```powershell
# Automatic (returns best match)
$tc = Select-BuildEnvironment -Type VS -RequireCppTools

# Interactive menu
$tc = Select-BuildEnvironment -Interactive
```

### Display

```powershell
Get-AllBuildEnvironments | Write-BuildEnvironmentTable
Get-VSBuildEnvironments  | Write-BuildEnvironmentTable -Detailed
```

---

## Example: full CMake build with the latest VS

```powershell
Import-Module .\WindowsBuildToolsFinder\WindowsBuildToolsFinder.psd1

# Find and activate the newest VS with C++ tools
$vs = Get-VSBuildEnvironments -RequireCppTools | Select-Object -First 1

if (-not $vs) {
    Write-Error "No Visual Studio with C++ tools found!"
    exit 1
}

Write-Host "Using: $($vs.Name)" -ForegroundColor Yellow
Import-VSEnvironment -BatFilePath $vs.Scripts['vcvarsall'] -Arguments 'x64'

# Find CMake
$cmake = Get-CMakeInstallations | Select-Object -First 1
if (-not $cmake) { Write-Error "CMake not found!"; exit 1 }

$cmakeExe = $cmake.Metadata.CMake

# Build
& $cmakeExe -B build -S . -G "Ninja" -DCMAKE_BUILD_TYPE=Release
& $cmakeExe --build build --config Release
```

---

## `Find-BuildEnvironment.ps1` parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-List` | switch | List all environments (default action) |
| `-Activate` | switch | Activate the first match (dot-source!) |
| `-Interactive` | switch | Show a picker menu (dot-source!) |
| `-Type` | string[] | Filter: VS, WindowsSDK, MinGW, MSYS2, TDM-GCC, LLVM, StrawberryPerl, CMake |
| `-Edition` | string | VS edition: Enterprise, Professional, Community, BuildTools |
| `-MinVSVersion` | int | Minimum VS major version (e.g. 17 for 2022) |
| `-Architecture` | string | x86, x64 (default), arm, arm64 |
| `-RequireCppTools` | switch | Only show/activate environments with C++ tools |
| `-Name` | string | Wildcard filter on environment name |
| `-Detailed` | switch | Show install paths and script keys |
| `-Json` | switch | Output as JSON |
| `-Verbose` | switch | Show verbose discovery output |

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Running on Windows (the tools being discovered are Windows-only)
