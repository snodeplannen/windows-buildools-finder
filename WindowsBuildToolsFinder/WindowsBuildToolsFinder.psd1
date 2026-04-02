@{
    # Module identity
    RootModule        = 'WindowsBuildToolsFinder.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'windows-buildtools-finder contributors'
    CompanyName       = ''
    Copyright         = '(c) 2024. All rights reserved.'
    Description       = 'Discover and activate Windows build environments: Visual Studio (all editions/versions), Windows SDK, MinGW-w64, MSYS2, TDM-GCC-64, Clang/LLVM, Strawberry Perl, and CMake.'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Exported functions (populated by the module itself via Export-ModuleMember)
    FunctionsToExport = @(
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

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('VisualStudio','BuildTools','MinGW','MSYS2','LLVM','Clang','CMake','StrawberryPerl','WindowsSDK','DevEnv')
            ProjectUri   = 'https://github.com/snodeplannen/windows-buildools-finder'
            ReleaseNotes = @'
v2.0.0
- Full rewrite with support for all Visual Studio editions (Enterprise, Professional, Community, Build Tools)
- All VS versions from 2012 through 2022+ via vswhere.exe + registry fallback
- Windows SDK detection
- MinGW-w64, MinGW32, MSYS2, TDM-GCC-64/32 detection
- Clang/LLVM detection (standalone + Chocolatey + Scoop + MSYS2)
- Strawberry Perl build environment detection
- CMake detection (standalone + VS bundled + MSYS2 + Scoop + Chocolatey)
- Import-VSEnvironment: imports any .bat environment file into the current session
- Invoke-BuildEnvironment: universal activation for all toolchain types
- Select-BuildEnvironment: filtering + interactive selection menu
- Write-BuildEnvironmentTable: pretty console output
- Comprehensive -Verbose, -WhatIf, -PassThru and parameter filtering throughout
'@
        }
    }
}
