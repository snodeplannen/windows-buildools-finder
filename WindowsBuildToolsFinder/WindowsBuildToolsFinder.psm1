#Requires -Version 5.1
<#
.SYNOPSIS
    WindowsBuildToolsFinder – discover and activate Windows build environments.

.DESCRIPTION
    This module finds all installed build toolchains on a Windows machine and
    provides helpers to activate them in the current PowerShell session.

    Supported toolchains
    ─────────────────────
    • Visual Studio 2012–2022+ (Enterprise / Professional / Community / Build Tools)
    • Windows SDK (any version)
    • MinGW-w64 / MinGW-32
    • MSYS2
    • TDM-GCC-64 / TDM-GCC-32
    • Clang / LLVM
    • Strawberry Perl (built-in C toolchain)
    • CMake (standalone installs + bundled in VS/MSYS2)

.NOTES
    All public functions are decorated with full comment-based help.
    Run  Get-Help <function-name> -Full  for details.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Private helpers ────────────────────────────────────────────────────

function _TestPath([string]$p) { Test-Path -LiteralPath $p -ErrorAction SilentlyContinue }

function _RegGet {
    param([string]$KeyPath, [string]$Value)
    try {
        $k = Get-ItemProperty -LiteralPath $KeyPath -Name $Value -ErrorAction Stop
        return $k.$Value
    } catch { return $null }
}

function _RegSubkeys([string]$KeyPath) {
    try {
        Get-ChildItem -LiteralPath $KeyPath -ErrorAction Stop
    } catch { @() }
}

function _FindExe([string]$Name) {
    try { (Get-Command $Name -ErrorAction Stop).Source } catch { $null }
}

function _NormalizeArch([string]$arch) {
    switch ($arch.ToLower()) {
        'x64'    { return 'x64' }
        'amd64'  { return 'x64' }
        'x86'    { return 'x86' }
        'win32'  { return 'x86' }
        'arm'    { return 'arm' }
        'arm64'  { return 'arm64' }
        default  { return $arch }
    }
}

# Build a rich toolchain object for public consumption
function _NewToolchain {
    param(
        [string]   $Type,          # VS | WindowsSDK | MinGW | MSYS2 | TDM-GCC | LLVM | StrawberryPerl | CMake
        [string]   $Name,
        [string]   $Version,
        [string]   $Edition,       # optional (Enterprise/Community/BuildTools …)
        [string]   $InstallPath,
        [bool]     $HasCppTools    = $false,
        [hashtable]$Scripts        = @{},
        [hashtable]$Metadata       = @{}
    )
    [PSCustomObject]@{
        PSTypeName  = 'WindowsBuildToolsFinder.Toolchain'
        Type        = $Type
        Name        = $Name
        Version     = $Version
        Edition     = $Edition
        InstallPath = $InstallPath
        HasCppTools = $HasCppTools
        Scripts     = $Scripts
        Metadata    = $Metadata
    }
}

#endregion

#region ── Visual Studio ──────────────────────────────────────────────────────

function Get-VSBuildEnvironments {
<#
.SYNOPSIS
    Returns all installed Visual Studio instances that expose vcvarsall.bat.

.DESCRIPTION
    Uses vswhere.exe when available (VS 2017+). Falls back to registry probing
    for VS 2012–2015. Each returned object exposes:

        .Type          → "VS"
        .Name          → Display name, e.g. "Visual Studio Enterprise 2022"
        .Version       → Version string, e.g. "17.9.0"
        .Edition       → "Enterprise" | "Professional" | "Community" | "BuildTools"
        .InstallPath   → Root installation path
        .HasCppTools   → $true when vcvarsall.bat exists
        .Scripts       → Hashtable: vcvarsall, vcvars32, vcvars64, VsDevCmd, …
        .Metadata      → Additional info (ProductId, ChannelId …)

.PARAMETER MinVersion
    Minimum major version to include (e.g. 15 for VS 2017+).

.PARAMETER MaxVersion
    Maximum major version to include.

.PARAMETER Edition
    Filter by edition: Enterprise, Professional, Community, BuildTools, or * (default).

.PARAMETER RequireCppTools
    When specified, only installations that have vcvarsall.bat are returned.

.PARAMETER IncludePrereleases
    Include VS prerelease / preview installations.

.EXAMPLE
    Get-VSBuildEnvironments

.EXAMPLE
    Get-VSBuildEnvironments -RequireCppTools -MinVersion 16
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1,99)][int]$MinVersion        = 0,
        [ValidateRange(1,99)][int]$MaxVersion        = 99,
        [string]                  $Edition           = '*',
        [switch]                  $RequireCppTools,
        [switch]                  $IncludePrereleases
    )

    $results = [System.Collections.Generic.List[object]]::new()

    # ── vswhere (VS 2017+) ─────────────────────────────────────────────────
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (_TestPath $vsWhere)) {
        $vsWhere = _FindExe 'vswhere.exe'
    }

    if ($vsWhere) {
        Write-Verbose "Using vswhere: $vsWhere"
        $vsWhereArgs = @('-format', 'json', '-utf8', '-all')
        if ($IncludePrereleases) { $vsWhereArgs += '-prerelease' }

        try {
            $json = & $vsWhere @vsWhereArgs 2>$null | ConvertFrom-Json
        } catch {
            Write-Warning "vswhere returned invalid JSON: $_"
            $json = @()
        }

        foreach ($inst in $json) {
            $maj = [int]($inst.installationVersion -split '\.')[0]
            if ($maj -lt $MinVersion -or $maj -gt $MaxVersion) { continue }

            $ed = _ExtractVSEdition $inst.productId
            if ($Edition -ne '*' -and $ed -notlike $Edition) { continue }

            $tc = _BuildVSToolchain $inst.displayName $inst.installationVersion $ed $inst.installationPath $inst.productId $inst.channelId
            if ($RequireCppTools -and -not $tc.HasCppTools) { continue }
            $results.Add($tc)
        }
    }

    # ── Legacy registry probe (VS 2012 – 2015) ────────────────────────────
    $legacyKeys = @(
        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0'; Ver = '14'; Name = 'Visual Studio 2015' },
        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0'; Ver = '12'; Name = 'Visual Studio 2013' },
        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\11.0'; Ver = '11'; Name = 'Visual Studio 2012' }
    )
    foreach ($lk in $legacyKeys) {
        $maj = [int]$lk.Ver
        if ($maj -lt $MinVersion -or $maj -gt $MaxVersion) { continue }
        # Skip if vswhere already found an entry for this version
        if ($results | Where-Object { ([int]($_.Version -split '\.')[0]) -eq $maj }) { continue }

        $installDir = _RegGet $lk.Key 'InstallDir'
        if (-not $installDir) { continue }

        # InstallDir points to …\Common7\IDE – walk up to root
        $root = Split-Path (Split-Path $installDir -Parent) -Parent
        $ed   = _ExtractVSEditionFromPath $root
        if ($Edition -ne '*' -and $ed -notlike $Edition) { continue }

        $tc = _BuildVSToolchain "$($lk.Name) ($ed)" "$($lk.Ver).0.0" $ed $root $null $null
        if ($RequireCppTools -and -not $tc.HasCppTools) { continue }
        $results.Add($tc)
    }

    # Sort newest first
    $results | Sort-Object { [version]($_.Version -replace '[^0-9.]','') } -Descending
}

# ── Private helpers for VS ─────────────────────────────────────────────────

function _ExtractVSEdition([string]$productId) {
    if (-not $productId) { return 'Unknown' }
    switch -Wildcard ($productId) {
        '*Enterprise*'   { return 'Enterprise'   }
        '*Professional*' { return 'Professional' }
        '*Community*'    { return 'Community'    }
        '*BuildTools*'   { return 'BuildTools'   }
        default          { return 'Unknown'       }
    }
}

function _ExtractVSEditionFromPath([string]$path) {
    switch -Wildcard ($path) {
        '*Enterprise*'   { return 'Enterprise'   }
        '*Professional*' { return 'Professional' }
        '*Community*'    { return 'Community'    }
        '*BuildTools*'   { return 'BuildTools'   }
        default          { return 'Unknown'       }
    }
}

function _BuildVSToolchain {
    param([string]$DisplayName, [string]$Version, [string]$Ed, [string]$Root, $ProductId, $ChannelId)

    # Candidate .bat locations (VC varies across VS versions)
    $vcBase1 = Join-Path $Root 'VC\Auxiliary\Build'      # VS 2017+
    $vcBase2 = Join-Path $Root 'VC'                      # VS 2015 and older

    $scripts  = @{}
    $hasCpp   = $false

    foreach ($base in @($vcBase1, $vcBase2)) {
        foreach ($bat in @('vcvarsall.bat','vcvars32.bat','vcvars64.bat',
                           'vcvarsamd64_x86.bat','vcvarsx86_amd64.bat',
                           'vcvarsx86_arm.bat','vcvarsamd64_arm.bat',
                           'vcvarsarm.bat','vcvarsarm64.bat')) {
            $full = Join-Path $base $bat
            if (_TestPath $full) {
                $key = [System.IO.Path]::GetFileNameWithoutExtension($bat)
                if (-not $scripts.ContainsKey($key)) { $scripts[$key] = $full }
                if ($key -eq 'vcvarsall') { $hasCpp = $true }
            }
        }
    }

    # VsDevCmd.bat lives in Common7\Tools
    $vsDevCmd = Join-Path $Root 'Common7\Tools\VsDevCmd.bat'
    if (_TestPath $vsDevCmd) { $scripts['VsDevCmd'] = $vsDevCmd }

    # MSBuild
    $msbuild = $null
    foreach ($rel in @('MSBuild\Current\Bin\MSBuild.exe',
                        'MSBuild\15.0\Bin\MSBuild.exe',
                        'MSBuild\14.0\Bin\MSBuild.exe')) {
        $p = Join-Path $Root $rel
        if (_TestPath $p) { $msbuild = $p; break }
    }

    # CMake bundled in VS
    $cmake = $null
    $cmakePaths = Get-ChildItem -Path $Root -Recurse -Filter 'cmake.exe' -ErrorAction SilentlyContinue |
                  Select-Object -First 1
    if ($cmakePaths) { $cmake = $cmakePaths.FullName }

    _NewToolchain `
        -Type        'VS' `
        -Name        $DisplayName `
        -Version     $Version `
        -Edition     $Ed `
        -InstallPath $Root `
        -HasCppTools $hasCpp `
        -Scripts     $scripts `
        -Metadata    @{
            ProductId = $ProductId
            ChannelId = $ChannelId
            MSBuild   = $msbuild
            CMake     = $cmake
        }
}

#endregion

#region ── Windows SDK ────────────────────────────────────────────────────────

function Get-WindowsSDKs {
<#
.SYNOPSIS
    Returns all installed Windows SDK versions.

.DESCRIPTION
    Reads HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots
    and supplements with file-system discovery under
    C:\Program Files (x86)\Windows Kits\.

.EXAMPLE
    Get-WindowsSDKs
#>
    [CmdletBinding()]
    param()

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()

    # Registry
    $regRoot = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    $regRoot2 = 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'

    foreach ($reg in @($regRoot, $regRoot2)) {
        try {
            $props = Get-ItemProperty -LiteralPath $reg -ErrorAction Stop
            foreach ($prop in ($props.PSObject.Properties | Where-Object { $_.Name -match '^KitsRoot' })) {
                $path = $prop.Value
                if ($path -and (_TestPath $path) -and $seen.Add($path)) {
                    $ver = if ($prop.Name -match '(\d+\.\d+)') { $Matches[1] } else { $prop.Name }
                    $tc  = _BuildSDKToolchain "Windows SDK $ver" $ver $path
                    $results.Add($tc)
                }
            }
        } catch { <# key may not exist #> }
    }

    # File-system fallback
    $kitBase = "${env:ProgramFiles(x86)}\Windows Kits"
    if (_TestPath $kitBase) {
        Get-ChildItem -LiteralPath $kitBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $kitVer = $_.Name
            Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $path = $_.FullName
                if ($seen.Add($path)) {
                    $tc = _BuildSDKToolchain "Windows SDK $kitVer.$($_.Name)" "$kitVer.$($_.Name)" $path
                    $results.Add($tc)
                }
            }
        }
    }

    $results | Sort-Object Version -Descending
}

function _BuildSDKToolchain([string]$Name, [string]$Version, [string]$Root) {
    $scripts = @{}

    # SetEnv.cmd (older SDKs)
    $setenv = Join-Path $Root 'bin\SetEnv.cmd'
    if (_TestPath $setenv) { $scripts['SetEnv'] = $setenv }

    # Include / Lib / Bin dirs
    $meta = @{ IncludeDir = $null; LibDir = $null; BinDir = $null }
    foreach ($rel in @('Include', 'Lib', 'bin')) {
        $d = Join-Path $Root $rel
        if (_TestPath $d) { $meta["${rel}Dir"] = $d }
    }

    _NewToolchain `
        -Type        'WindowsSDK' `
        -Name        $Name `
        -Version     $Version `
        -Edition     '' `
        -InstallPath $Root `
        -HasCppTools ($scripts.Count -gt 0 -or (_TestPath "$Root\Include")) `
        -Scripts     $scripts `
        -Metadata    $meta
}

#endregion

#region ── MinGW / MSYS2 / TDM-GCC ───────────────────────────────────────────

function Get-MinGWInstallations {
<#
.SYNOPSIS
    Returns all MinGW-w64, MinGW32, MSYS2, and TDM-GCC installations.

.DESCRIPTION
    Probes common install paths and the registry for MinGW variants.
    Each returned object has Type set to "MinGW", "MSYS2", or "TDM-GCC".

.PARAMETER Type
    Filter by type: MinGW | MSYS2 | TDM-GCC | * (default).

.EXAMPLE
    Get-MinGWInstallations

.EXAMPLE
    Get-MinGWInstallations -Type MSYS2
#>
    [CmdletBinding()]
    param(
        [ValidateSet('MinGW','MSYS2','TDM-GCC','*')]
        [string]$Type = '*'
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()

    # ── MSYS2 ─────────────────────────────────────────────────────────────
    if ($Type -in @('*','MSYS2')) {
        $msys2Roots = @(
            'C:\msys64', 'C:\msys32',
            "${env:USERPROFILE}\msys64", "${env:USERPROFILE}\msys32",
            "${env:SystemDrive}\msys2"
        )
        # Registry (MSYS2 installer)
        $msysReg = _RegGet 'HKLM:\SOFTWARE\MSYS2\msys64' 'InstallPath'
        if ($msysReg) { $msys2Roots += $msysReg }

        foreach ($root in $msys2Roots) {
            if ((_TestPath $root) -and $seen.Add($root)) {
                $tc = _BuildMSYS2Toolchain $root
                $results.Add($tc)
            }
        }
    }

    # ── TDM-GCC ───────────────────────────────────────────────────────────
    if ($Type -in @('*','TDM-GCC')) {
        $tdmRoots = @('C:\TDM-GCC-64', 'C:\TDM-GCC-32')
        # Registry
        foreach ($arch in @('64','32')) {
            $r = _RegGet "HKLM:\SOFTWARE\WOW6432Node\TDM-GCC-$arch" 'Install_Dir'
            if ($r) { $tdmRoots += $r }
        }
        foreach ($root in $tdmRoots) {
            if ((_TestPath $root) -and $seen.Add($root)) {
                $tc = _BuildMinGWToolchain $root 'TDM-GCC' "TDM-GCC ($(Split-Path $root -Leaf))"
                $results.Add($tc)
            }
        }
    }

    # ── MinGW-w64 / MinGW32 ───────────────────────────────────────────────
    if ($Type -in @('*','MinGW')) {
        $mingwRoots = @(
            'C:\mingw64', 'C:\mingw32', 'C:\MinGW',
            "${env:LOCALAPPDATA}\Programs\mingw-w64",
            'C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64',
            "${env:SystemDrive}\msys64\mingw64",
            "${env:SystemDrive}\msys64\mingw32",
            "${env:SystemDrive}\msys64\ucrt64",
            "${env:SystemDrive}\msys64\clang64"
        )
        foreach ($root in $mingwRoots) {
            if ((_TestPath $root) -and $seen.Add($root)) {
                $tc = _BuildMinGWToolchain $root 'MinGW' "MinGW ($(Split-Path $root -Leaf))"
                $results.Add($tc)
            }
        }

        # Chocolatey / winget additional locations
        $chocoBin = 'C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\bin'
        if ((_TestPath $chocoBin) -and $seen.Add($chocoBin)) {
            $tc = _BuildMinGWToolchain (Split-Path $chocoBin -Parent) 'MinGW' 'MinGW (Chocolatey)'
            $results.Add($tc)
        }
    }

    $results
}

function _BuildMSYS2Toolchain([string]$Root) {
    $mingw64bin = Join-Path $Root 'mingw64\bin'
    $hasCpp     = _TestPath (Join-Path $mingw64bin 'g++.exe')
    $bash       = Join-Path $Root 'usr\bin\bash.exe'

    _NewToolchain `
        -Type        'MSYS2' `
        -Name        "MSYS2 ($Root)" `
        -Version     (_GetGCCVersion (Join-Path $mingw64bin 'gcc.exe')) `
        -Edition     '' `
        -InstallPath $Root `
        -HasCppTools $hasCpp `
        -Scripts     (if (_TestPath $bash) { @{ bash = $bash } } else { @{} }) `
        -Metadata    @{
            Bash     = $bash
            MinGW64  = $mingw64bin
            MinGW32  = (Join-Path $Root 'mingw32\bin')
            UCRT64   = (Join-Path $Root 'ucrt64\bin')
            Clang64  = (Join-Path $Root 'clang64\bin')
        }
}

function _BuildMinGWToolchain([string]$Root, [string]$Type, [string]$DisplayName) {
    $bin    = Join-Path $Root 'bin'
    $gcc    = Join-Path $bin 'gcc.exe'
    $gpp    = Join-Path $bin 'g++.exe'
    $hasCpp = _TestPath $gpp

    _NewToolchain `
        -Type        $Type `
        -Name        $DisplayName `
        -Version     (_GetGCCVersion $gcc) `
        -Edition     '' `
        -InstallPath $Root `
        -HasCppTools $hasCpp `
        -Scripts     @{} `
        -Metadata    @{ BinDir = $bin; GCC = $gcc; GPP = $gpp }
}

function _GetGCCVersion([string]$gccExe) {
    if (-not (_TestPath $gccExe)) { return '' }
    try {
        $v = & $gccExe --version 2>$null | Select-Object -First 1
        if ($v -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return ''
}

#endregion

#region ── Clang / LLVM ───────────────────────────────────────────────────────

function Get-ClangLLVMInstallations {
<#
.SYNOPSIS
    Returns all LLVM/Clang installations found on this machine.

.DESCRIPTION
    Searches common install locations (Program Files, Chocolatey, Scoop, MSYS2)
    and uses 'where clang' as a last resort.

.EXAMPLE
    Get-ClangLLVMInstallations
#>
    [CmdletBinding()]
    param()

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()

    $candidates = @(
        "${env:ProgramFiles}\LLVM",
        "${env:ProgramFiles(x86)}\LLVM",
        'C:\ProgramData\chocolatey\lib\llvm\tools\llvm',
        "${env:USERPROFILE}\scoop\apps\llvm\current",
        'C:\msys64\clang64',
        'C:\msys64\clang32',
        'C:\msys64\mingw64'   # MSYS2 ships clang too
    )

    # Registry (LLVM Windows installer)
    foreach ($hive in @('HKLM:\SOFTWARE\LLVM\LLVM', 'HKLM:\SOFTWARE\WOW6432Node\LLVM\LLVM')) {
        $r = _RegGet $hive '(default)'
        if (-not $r) { $r = _RegGet $hive '' }
        if ($r) { $candidates += $r }
    }

    # PATH fallback
    $clangExe = _FindExe 'clang.exe'
    if ($clangExe) {
        $candidates += (Split-Path (Split-Path $clangExe -Parent) -Parent)
    }

    foreach ($root in $candidates) {
        if (-not (_TestPath $root)) { continue }
        $bin    = Join-Path $root 'bin'
        $clang  = Join-Path $bin 'clang.exe'
        if (-not (_TestPath $clang)) {
            $clang = Join-Path $root 'clang.exe'
            if (-not (_TestPath $clang)) { continue }
            $bin = $root
        }
        if (-not $seen.Add($bin)) { continue }

        $ver = _GetClangVersion $clang
        $tc  = _NewToolchain `
            -Type        'LLVM' `
            -Name        "Clang/LLVM $ver ($root)" `
            -Version     $ver `
            -Edition     '' `
            -InstallPath $root `
            -HasCppTools (_TestPath (Join-Path $bin 'clang++.exe')) `
            -Scripts     @{} `
            -Metadata    @{
                BinDir  = $bin
                Clang   = $clang
                ClangPP = (Join-Path $bin 'clang++.exe')
                LLD     = (Join-Path $bin 'lld.exe')
                ClangCL = (Join-Path $bin 'clang-cl.exe')
            }
        $results.Add($tc)
    }

    $results | Sort-Object Version -Descending
}

function _GetClangVersion([string]$clangExe) {
    try {
        $v = & $clangExe --version 2>$null | Select-Object -First 1
        if ($v -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return ''
}

#endregion

#region ── Strawberry Perl ────────────────────────────────────────────────────

function Get-StrawberryPerlEnvironment {
<#
.SYNOPSIS
    Returns the Strawberry Perl build environment (GCC toolchain bundled with Perl).

.DESCRIPTION
    Strawberry Perl ships a full MinGW-w64 GCC toolchain and a CPAN build
    environment. This function detects it and exposes the relevant paths.

.EXAMPLE
    Get-StrawberryPerlEnvironment
#>
    [CmdletBinding()]
    param()

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()

    $candidates = @(
        'C:\Strawberry',
        "${env:SystemDrive}\Strawberry",
        "${env:USERPROFILE}\Strawberry"
    )

    # Registry
    $regPaths = @(
        'HKLM:\SOFTWARE\Strawberry Perl',
        'HKLM:\SOFTWARE\WOW6432Node\Strawberry Perl'
    )
    foreach ($rp in $regPaths) {
        $r = _RegGet $rp 'InstallPath'
        if ($r) { $candidates += $r }
    }

    # PATH fallback
    $perlExe = _FindExe 'perl.exe'
    if ($perlExe) {
        # …\perl\bin\perl.exe  →  …\ (Strawberry root)
        $candidates += (Split-Path (Split-Path (Split-Path $perlExe -Parent) -Parent) -Parent)
    }

    foreach ($root in $candidates) {
        if (-not (_TestPath $root)) { continue }
        $perlBin   = Join-Path $root 'perl\bin'
        $cToolsBin = Join-Path $root 'c\bin'
        $perl      = Join-Path $perlBin 'perl.exe'

        if (-not (_TestPath $perl)) { continue }
        if (-not $seen.Add($root)) { continue }

        $gccExe  = Join-Path $cToolsBin 'gcc.exe'
        $hasCpp  = _TestPath (Join-Path $cToolsBin 'g++.exe')
        $perlVer = _GetPerlVersion $perl

        $tc = _NewToolchain `
            -Type        'StrawberryPerl' `
            -Name        "Strawberry Perl $perlVer" `
            -Version     $perlVer `
            -Edition     '' `
            -InstallPath $root `
            -HasCppTools $hasCpp `
            -Scripts     @{} `
            -Metadata    @{
                Perl        = $perl
                PerlBin     = $perlBin
                CToolsBin   = $cToolsBin
                GCC         = $gccExe
                GCCVersion  = (_GetGCCVersion $gccExe)
                MakefilePath = (Join-Path $root 'c\bin\gmake.exe')
            }
        $results.Add($tc)
    }

    $results
}

function _GetPerlVersion([string]$perlExe) {
    try {
        $v = & $perlExe --version 2>$null
        if ($v -match 'v(\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return ''
}

#endregion

#region ── CMake ──────────────────────────────────────────────────────────────

function Get-CMakeInstallations {
<#
.SYNOPSIS
    Returns all CMake installations detected on this machine.

.DESCRIPTION
    Searches Program Files, Chocolatey, Scoop, VS bundled CMake, MSYS2,
    and the PATH. Deduplicates by resolved binary path.

.EXAMPLE
    Get-CMakeInstallations
#>
    [CmdletBinding()]
    param()

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()

    $candidates = @(
        "${env:ProgramFiles}\CMake",
        "${env:ProgramFiles(x86)}\CMake",
        'C:\ProgramData\chocolatey\lib\cmake.install\tools\cmake',
        'C:\ProgramData\chocolatey\lib\cmake\tools\cmake',
        "${env:USERPROFILE}\scoop\apps\cmake\current",
        'C:\msys64\mingw64',
        'C:\msys64\ucrt64'
    )

    # VS bundled cmake(s)
    try {
        $vsInstances = Get-VSBuildEnvironments -ErrorAction SilentlyContinue
        foreach ($vs in $vsInstances) {
            if ($vs.Metadata.CMake) {
                $candidates += (Split-Path (Split-Path $vs.Metadata.CMake -Parent) -Parent)
            }
        }
    } catch {}

    # Registry
    $regPaths = @(
        'HKLM:\SOFTWARE\Kitware\CMake',
        'HKLM:\SOFTWARE\WOW6432Node\Kitware\CMake'
    )
    foreach ($rp in $regPaths) {
        $r = _RegGet $rp 'InstallDir'
        if ($r) { $candidates += $r }
    }

    # PATH fallback
    $cmakeInPath = _FindExe 'cmake.exe'
    if ($cmakeInPath) {
        $candidates += (Split-Path (Split-Path $cmakeInPath -Parent) -Parent)
    }

    foreach ($root in $candidates) {
        if (-not (_TestPath $root)) { continue }
        $cmake = Join-Path $root 'bin\cmake.exe'
        if (-not (_TestPath $cmake)) {
            $cmake = Join-Path $root 'cmake.exe'
            if (-not (_TestPath $cmake)) { continue }
        }
        $resolvedCmake = Resolve-Path $cmake -ErrorAction SilentlyContinue
        if (-not $resolvedCmake) { continue }
        if (-not $seen.Add($resolvedCmake.Path)) { continue }

        $ver = _GetCMakeVersion $cmake
        $tc  = _NewToolchain `
            -Type        'CMake' `
            -Name        "CMake $ver" `
            -Version     $ver `
            -Edition     '' `
            -InstallPath $root `
            -HasCppTools $false `
            -Scripts     @{} `
            -Metadata    @{
                CMake   = $cmake
                CTest   = (Join-Path (Split-Path $cmake -Parent) 'ctest.exe')
                CPack   = (Join-Path (Split-Path $cmake -Parent) 'cpack.exe')
            }
        $results.Add($tc)
    }

    $results | Sort-Object Version -Descending
}

function _GetCMakeVersion([string]$cmakeExe) {
    try {
        $v = & $cmakeExe --version 2>$null | Select-Object -First 1
        if ($v -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return ''
}

#endregion

#region ── Aggregate: Get-AllBuildEnvironments ───────────────────────────────

function Get-AllBuildEnvironments {
<#
.SYNOPSIS
    Returns every build toolchain detected on this machine.

.DESCRIPTION
    Aggregates results from:
        Get-VSBuildEnvironments
        Get-WindowsSDKs
        Get-MinGWInstallations
        Get-ClangLLVMInstallations
        Get-StrawberryPerlEnvironment
        Get-CMakeInstallations

    Optionally filter by toolchain Type.

.PARAMETER Type
    One or more toolchain types to include.
    Accepted values: VS, WindowsSDK, MinGW, MSYS2, TDM-GCC, LLVM,
                     StrawberryPerl, CMake
    Default: all types.

.PARAMETER RequireCppTools
    Only return toolchains where HasCppTools is $true.

.EXAMPLE
    Get-AllBuildEnvironments

.EXAMPLE
    Get-AllBuildEnvironments -Type VS,CMake -RequireCppTools
#>
    [CmdletBinding()]
    param(
        [ValidateSet('VS','WindowsSDK','MinGW','MSYS2','TDM-GCC','LLVM','StrawberryPerl','CMake')]
        [string[]]$Type,
        [switch]$RequireCppTools
    )

    $all = [System.Collections.Generic.List[object]]::new()

    $run = {
        param($fn, [string[]]$typeFilter)
        try {
            $items = & $fn
            foreach ($item in $items) {
                if ($typeFilter -and $item.Type -notin $typeFilter) { continue }
                if ($RequireCppTools -and -not $item.HasCppTools) { continue }
                $all.Add($item)
            }
        } catch {
            Write-Warning "$($fn.ToString()) failed: $_"
        }
    }

    $fns = @(
        { Get-VSBuildEnvironments          },
        { Get-WindowsSDKs                  },
        { Get-MinGWInstallations           },
        { Get-ClangLLVMInstallations       },
        { Get-StrawberryPerlEnvironment    },
        { Get-CMakeInstallations           }
    )

    foreach ($fn in $fns) { & $run $fn $Type }

    $all.ToArray()
}

#endregion

#region ── Select-BuildEnvironment ───────────────────────────────────────────

function Select-BuildEnvironment {
<#
.SYNOPSIS
    Selects a single build environment, optionally interactively.

.DESCRIPTION
    Filters the list of available toolchains using the supplied criteria and
    returns the best match. When -Interactive is specified, the user is
    presented with a numbered list and can choose.

.PARAMETER Type
    Toolchain type filter (VS, LLVM, MinGW, …).

.PARAMETER Name
    Wildcard name filter, e.g. "Enterprise*", "*2022*".

.PARAMETER Version
    Exact or minimum version string.

.PARAMETER RequireCppTools
    Only consider toolchains with C++ support.

.PARAMETER Interactive
    Show a menu and let the user pick.

.EXAMPLE
    $env = Select-BuildEnvironment -Type VS -RequireCppTools
    Import-VSEnvironment -BatFilePath $env.Scripts['vcvarsall'] -Arguments 'x64'

.EXAMPLE
    $env = Select-BuildEnvironment -Interactive
#>
    [CmdletBinding()]
    param(
        [ValidateSet('VS','WindowsSDK','MinGW','MSYS2','TDM-GCC','LLVM','StrawberryPerl','CMake')]
        [string[]]$Type,
        [string]  $Name,
        [string]  $Version,
        [switch]  $RequireCppTools,
        [switch]  $Interactive
    )

    $environments = Get-AllBuildEnvironments -Type $Type -RequireCppTools:$RequireCppTools

    if ($Name)    { $environments = $environments | Where-Object { $_.Name -like $Name } }
    if ($Version) { $environments = $environments | Where-Object { $_.Version -like "$Version*" } }

    if (-not $environments) {
        Write-Error 'No matching build environment found.'
        return $null
    }

    if ($Interactive) {
        Write-Host ''
        Write-Host 'Available build environments:' -ForegroundColor Cyan
        $i = 0
        foreach ($e in $environments) {
            $tag = if ($e.HasCppTools) { '[C++]' } else { '     ' }
            Write-Host ("  [{0,2}] {1} {2}  {3}  {4}" -f $i, $tag, $e.Type.PadRight(12), $e.Version.PadRight(12), $e.Name) -ForegroundColor White
            $i++
        }
        Write-Host ''
        do {
            $raw = Read-Host "Select environment (0-$($i-1))"
        } while (-not ($raw -match '^\d+$') -or [int]$raw -ge $i)
        return $environments[[int]$raw]
    }

    # Non-interactive: return the first (best) match
    $environments | Select-Object -First 1
}

#endregion

#region ── Import-VSEnvironment ───────────────────────────────────────────────

function Import-VSEnvironment {
<#
.SYNOPSIS
    Runs a build-environment .bat file and imports the resulting variables
    into the current PowerShell session.

.DESCRIPTION
    Executes the supplied .bat file in a temporary cmd.exe shell, captures the
    resulting environment, and applies changes (additions and modifications) to
    the current PowerShell session.

    Works with any .bat file that sets environment variables:
        vcvarsall.bat, VsDevCmd.bat, SetEnv.cmd, strawberry-environment.bat …

.PARAMETER BatFilePath
    Path to the .bat / .cmd file.

.PARAMETER Arguments
    Arguments forwarded to the .bat file, e.g. "x64" or "x86 uwp 10.0.22621.0".

.PARAMETER PassThru
    Return a hashtable of all variables that were changed / added.

.PARAMETER WhatIf
    Show what would be changed without actually modifying the session.

.EXAMPLE
    Import-VSEnvironment -BatFilePath 'C:\...\vcvarsall.bat' -Arguments 'x64'

.EXAMPLE
    $changes = Import-VSEnvironment -BatFilePath $path -Arguments 'x64' -PassThru
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$BatFilePath,

        [Parameter(Position = 1)]
        [string]$Arguments = '',

        [switch]$PassThru
    )

    $BatFilePath = (Resolve-Path -LiteralPath $BatFilePath).Path

    Write-Verbose "Executing: `"$BatFilePath`" $Arguments"

    # We use a separator line to isolate the environment dump from any bat output
    $separator = "---ENV-DUMP-$(New-Guid)---"
    $cmdLine   = "`"$BatFilePath`" $Arguments & echo $separator & set"

    $raw = cmd.exe /c $cmdLine 2>&1
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        # bat files may return non-zero even on success (vcvarsall returns 0, but others vary)
        Write-Verbose "bat file exited with code $LASTEXITCODE"
    }

    # Everything after the separator is the env dump
    $afterSep  = $false
    $envLines  = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $raw) {
        if ($line -match [regex]::Escape($separator)) { $afterSep = $true; continue }
        if ($afterSep) { $envLines.Add($line) }
    }

    if ($envLines.Count -eq 0) {
        Write-Error "Failed to capture environment from `"$BatFilePath`". Bat output:`n$($raw -join "`n")"
        return
    }

    $newEnv = @{}
    foreach ($line in $envLines) {
        $idx = $line.IndexOf('=')
        if ($idx -le 0) { continue }
        $k = $line.Substring(0, $idx)
        $v = $line.Substring($idx + 1)
        $newEnv[$k] = $v
    }

    $changed = @{}
    foreach ($kv in $newEnv.GetEnumerator()) {
        $cur = [System.Environment]::GetEnvironmentVariable($kv.Key)
        if ($cur -ne $kv.Value) {
            $changed[$kv.Key] = $kv.Value
        }
    }

    if ($WhatIfPreference) {
        Write-Host "WhatIf: Would update $($changed.Count) environment variable(s):" -ForegroundColor Yellow
        foreach ($kv in $changed.GetEnumerator()) {
            Write-Host "  $($kv.Key) = $($kv.Value)" -ForegroundColor Gray
        }
        return
    }

    foreach ($kv in $changed.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
        Set-Item -Path "Env:\$($kv.Key)" -Value $kv.Value -ErrorAction SilentlyContinue
    }

    Write-Verbose "Imported $($changed.Count) environment variable(s) from `"$BatFilePath`"."

    if ($PassThru) { return $changed }
}

#endregion

#region ── Invoke-BuildEnvironment ───────────────────────────────────────────

function Invoke-BuildEnvironment {
<#
.SYNOPSIS
    Activates a build toolchain in the current PowerShell session.

.DESCRIPTION
    Given a toolchain object (from Get-AllBuildEnvironments or
    Select-BuildEnvironment), this function activates it:

      • VS             → calls Import-VSEnvironment with vcvarsall / VsDevCmd
      • MinGW/TDM-GCC  → prepends BinDir to PATH
      • MSYS2          → prepends MinGW64 bin to PATH
      • LLVM           → prepends BinDir to PATH
      • StrawberryPerl → prepends PerlBin + CToolsBin to PATH
      • CMake          → prepends CMake bin to PATH

.PARAMETER Toolchain
    A toolchain object returned by Get-AllBuildEnvironments or Select-BuildEnvironment.

.PARAMETER Architecture
    Target architecture for VS environments: x86, x64, arm, arm64.
    Default: x64.

.PARAMETER PassThru
    Return a summary hashtable.

.EXAMPLE
    $tc = Select-BuildEnvironment -Type VS -RequireCppTools
    Invoke-BuildEnvironment -Toolchain $tc -Architecture x64

.EXAMPLE
    Get-AllBuildEnvironments -Type MinGW | Select-Object -First 1 | Invoke-BuildEnvironment
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSObject]$Toolchain,

        [ValidateSet('x86','x64','arm','arm64')]
        [string]$Architecture = 'x64',

        [switch]$PassThru
    )

    process {
        $arch = _NormalizeArch $Architecture

        switch ($Toolchain.Type) {
            'VS' {
                $bat = $Toolchain.Scripts['vcvarsall']
                if (-not $bat) { $bat = $Toolchain.Scripts['VsDevCmd'] }
                if (-not $bat) {
                    Write-Error "No activation script found for $($Toolchain.Name)"
                    return
                }
                $arg = if ($bat -like '*vcvarsall*') { $arch } else { "-arch=$arch" }
                if ($PSCmdlet.ShouldProcess($Toolchain.Name, "Import-VSEnvironment $arg")) {
                    $changes = Import-VSEnvironment -BatFilePath $bat -Arguments $arg -PassThru:$PassThru -Verbose:($VerbosePreference -ne 'SilentlyContinue')
                    Write-Host "Activated: $($Toolchain.Name) [$arch]" -ForegroundColor Green
                    if ($PassThru) { return $changes }
                }
            }

            { $_ -in @('MinGW','TDM-GCC') } {
                $bin = $Toolchain.Metadata.BinDir
                if (-not $bin) { Write-Error "BinDir not set for $($Toolchain.Name)"; return }
                if ($PSCmdlet.ShouldProcess($Toolchain.Name, "Prepend PATH with $bin")) {
                    _PrependPath $bin
                    Write-Host "Activated: $($Toolchain.Name) — added to PATH: $bin" -ForegroundColor Green
                    if ($PassThru) { return @{ PATH_PREPEND = $bin } }
                }
            }

            'MSYS2' {
                $bin = $Toolchain.Metadata.MinGW64
                if ($arch -eq 'x86') { $bin = $Toolchain.Metadata.MinGW32 }
                if (-not $bin) { Write-Error "Bin dir not found for $($Toolchain.Name)"; return }
                if ($PSCmdlet.ShouldProcess($Toolchain.Name, "Prepend PATH with $bin")) {
                    _PrependPath $bin
                    _PrependPath (Join-Path $Toolchain.InstallPath 'usr\bin')
                    Write-Host "Activated: $($Toolchain.Name) — added to PATH: $bin" -ForegroundColor Green
                    if ($PassThru) { return @{ PATH_PREPEND = $bin } }
                }
            }

            'LLVM' {
                $bin = $Toolchain.Metadata.BinDir
                if ($PSCmdlet.ShouldProcess($Toolchain.Name, "Prepend PATH with $bin")) {
                    _PrependPath $bin
                    Write-Host "Activated: $($Toolchain.Name) — added to PATH: $bin" -ForegroundColor Green
                    if ($PassThru) { return @{ PATH_PREPEND = $bin } }
                }
            }

            'StrawberryPerl' {
                $perlBin = $Toolchain.Metadata.PerlBin
                $cBin    = $Toolchain.Metadata.CToolsBin
                if ($PSCmdlet.ShouldProcess($Toolchain.Name, "Prepend PATH with $perlBin and $cBin")) {
                    _PrependPath $cBin
                    _PrependPath $perlBin
                    Write-Host "Activated: $($Toolchain.Name) — added Perl and C tools to PATH" -ForegroundColor Green
                    if ($PassThru) { return @{ PATH_PREPEND = "$perlBin;$cBin" } }
                }
            }

            'CMake' {
                $cmakeBin = Split-Path $Toolchain.Metadata.CMake -Parent
                if ($PSCmdlet.ShouldProcess($Toolchain.Name, "Prepend PATH with $cmakeBin")) {
                    _PrependPath $cmakeBin
                    Write-Host "Activated: $($Toolchain.Name) — added CMake to PATH" -ForegroundColor Green
                    if ($PassThru) { return @{ PATH_PREPEND = $cmakeBin } }
                }
            }

            default {
                Write-Warning "Invoke-BuildEnvironment: activation not implemented for type '$($Toolchain.Type)'."
            }
        }
    }
}

function _PrependPath([string]$dir) {
    if (-not $dir -or -not (_TestPath $dir)) { return }
    $cur = $env:PATH
    if ($cur -split ';' -contains $dir) { return }   # already there
    $env:PATH = "$dir;$cur"
    [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, 'Process')
}

#endregion

#region ── Format helpers (Write-BuildEnvironmentTable) ──────────────────────

function Write-BuildEnvironmentTable {
<#
.SYNOPSIS
    Prints a formatted summary table of toolchains to the console.

.PARAMETER Environments
    Array of toolchain objects to display.

.PARAMETER Detailed
    Include install path and script keys in the output.

.EXAMPLE
    Get-AllBuildEnvironments | Write-BuildEnvironmentTable

.EXAMPLE
    Get-VSBuildEnvironments | Write-BuildEnvironmentTable -Detailed
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSObject[]]$Environments,
        [switch]$Detailed
    )

    begin { $all = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($e in $Environments) { $all.Add($e) } }
    end {
        if ($all.Count -eq 0) { Write-Warning 'No build environments to display.'; return }

        Write-Host ''
        Write-Host ('─' * 90) -ForegroundColor DarkGray
        Write-Host (' {0,-14} {1,-12} {2,-12} {3,-6} {4}' -f 'Type','Version','Edition','C++','Name') -ForegroundColor Cyan
        Write-Host ('─' * 90) -ForegroundColor DarkGray

        foreach ($e in $all) {
            $cppMark = if ($e.HasCppTools) { '  ✔' } else { '   ' }
            $line = ' {0,-14} {1,-12} {2,-12} {3}  {4}' -f `
                $e.Type, $e.Version, $e.Edition, $cppMark, $e.Name
            $color = switch ($e.Type) {
                'VS'           { 'Yellow'   }
                'WindowsSDK'   { 'Magenta'  }
                'MinGW'        { 'Green'    }
                'MSYS2'        { 'Green'    }
                'TDM-GCC'      { 'Green'    }
                'LLVM'         { 'Cyan'     }
                'StrawberryPerl' { 'DarkYellow' }
                'CMake'        { 'Blue'     }
                default        { 'White'    }
            }
            Write-Host $line -ForegroundColor $color

            if ($Detailed) {
                if ($e.InstallPath) {
                    Write-Host ('    InstallPath : {0}' -f $e.InstallPath) -ForegroundColor DarkGray
                }
                if ($e.Scripts.Count -gt 0) {
                    Write-Host ('    Scripts     : {0}' -f ($e.Scripts.Keys -join ', ')) -ForegroundColor DarkGray
                }
            }
        }
        Write-Host ('─' * 90) -ForegroundColor DarkGray
        Write-Host " Total: $($all.Count) environment(s)" -ForegroundColor Gray
        Write-Host ''
    }
}

#endregion

#region ── Module exports ─────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Get-VSBuildEnvironments',
    'Get-WindowsSDKs',
    'Get-MinGWInstallations',
    'Get-ClangLLVMInstallations',
    'Get-StrawberryPerlEnvironment',
    'Get-CMakeInstallations',
    'Get-AllBuildEnvironments',
    'Select-BuildEnvironment',
    'Import-VSEnvironment',
    'Invoke-BuildEnvironment',
    'Write-BuildEnvironmentTable'
)

#endregion
