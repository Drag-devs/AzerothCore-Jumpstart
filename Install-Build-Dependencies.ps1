param(
    [string]$OfflineInstallerPath,
    [switch]$NoAutoElevate,
    [switch]$SkipVCRedist,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir = Join-Path $ScriptRoot 'logs'
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}
$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPrefix = if ($CheckOnly) { 'Check' } else { 'Install' }
$LogPath = Join-Path $LogDir "$logPrefix-Dependencies-$TimeStamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-Admin) {
        Write-Log 'Running elevated.' 'OK'
        return
    }

    if ($NoAutoElevate) {
        Write-Log 'Not running as admin and -NoAutoElevate set. Exiting.' 'ERROR'
        exit 2
    }

    Write-Log 'Not running as admin. Relaunching elevated...' 'WARN'

    $selfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $selfPath + '"'))
    if ($OfflineInstallerPath) {
        $argList += @('-OfflineInstallerPath', ('"' + $OfflineInstallerPath + '"'))
    }
    if ($NoAutoElevate) {
        $argList += '-NoAutoElevate'
    }
    if ($SkipVCRedist) {
        $argList += '-SkipVCRedist'
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    exit 0
}

function Check-Command {
    param([Parameter(Mandatory = $true)][string]$Command)
    if (Get-Command $Command -ErrorAction SilentlyContinue) { return $true }
    # Refresh PATH from registry in case it was updated by a recent install
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-CommandVersion {
    param([Parameter(Mandatory = $true)][string]$Command)

    try {
        $output = & $Command --version 2>$null | Select-Object -First 1
        return $output
    }
    catch {
        return $null
    }
}

function Test-Winget {
    try {
        $null = Get-Command winget -ErrorAction Stop
        $null = & winget --version
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-ExeInstall {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path $InstallerPath)) {
        throw "Installer for $Name not found: $InstallerPath"
    }

    Write-Log "Installing $Name via offline installer: $InstallerPath"
    $p = Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "Offline install for $Name failed with exit code $($p.ExitCode)"
    }
    Write-Log "$Name install completed." 'OK'
}

function Invoke-MsiInstall {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path $MsiPath)) {
        throw "MSI for $Name not found: $MsiPath"
    }

    Write-Log "Installing $Name via MSI: $MsiPath"
    $args = @('/i', ('"' + $MsiPath + '"'), '/qn', '/norestart')
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "MSI install for $Name failed with exit code $($p.ExitCode)"
    }
    Write-Log "$Name install completed." 'OK'
}

function Find-FirstFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    return Get-ChildItem -Path $Path -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Override
    )

    $baseArgs = @(
        'install',
        '--id', $Id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent'
    )

    if ($Override) {
        $baseArgs += @('--override', $Override)
    }

    Write-Log "Installing $Name via winget ($Id)..."
    $output = & winget @baseArgs 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Add-Content -Path $LogPath -Value ("[winget] " + $_) }

    # 0 = success, -1978335189 (0x8A150013) = no upgrade available (already current), both are fine
    $successCodes = @(0, -1978335189)
    if ($exitCode -notin $successCodes) {
        throw "winget install failed for $Name ($Id) with exit code $exitCode"
    }

    Write-Log "$Name installed via winget." 'OK'
}

function Test-VSBuildTools {
    # Match any VS 2022+ edition (Community/Pro/Enterprise/BuildTools) via uninstall registry
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $vs = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
          Where-Object { $_.PSObject.Properties['DisplayName'] -and
                         $_.DisplayName -match 'Visual Studio.*(Build Tools|Community|Professional|Enterprise)\s+202[2-9]' }
    if (-not $vs) { return $false }

    $sdkRoot = 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    try {
        $kitsRoot10 = (Get-ItemProperty -Path $sdkRoot -Name KitsRoot10 -ErrorAction Stop).KitsRoot10
        if (-not $kitsRoot10) { return $false }
        if (-not (Test-Path (Join-Path $kitsRoot10 'Include'))) { return $false }
    }
    catch { return $false }

    return $true
}

function Test-VCRedist {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )

    foreach ($path in $regPaths) {
        try {
            $item = Get-ItemProperty -Path $path -ErrorAction Stop
            if ($item.Installed -eq 1) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    return $false
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $ver = Get-CommandVersion -Command 'git'
        Write-Log "Git already installed: $ver" 'OK'
        return
    }

    if (Test-Winget) {
        Invoke-WingetInstall -Id 'Git.Git' -Name 'Git'
        return
    }

    if (-not $OfflineInstallerPath) {
        throw 'Git is missing, winget is unavailable, and no -OfflineInstallerPath was provided.'
    }

    $installer = Find-FirstFile -Path $OfflineInstallerPath -Pattern 'Git-*-64-bit.exe'
    if (-not $installer) {
        $installer = Find-FirstFile -Path $OfflineInstallerPath -Pattern 'Git-64-bit.exe'
    }
    if (-not $installer) {
        throw 'Offline Git installer not found. Expected Git-*-64-bit.exe.'
    }

    Invoke-ExeInstall -InstallerPath $installer.FullName -Arguments @('/VERYSILENT', '/NORESTART') -Name 'Git'
}

function Add-CMakeToPath {
    # Find cmake.exe via registry install location, not a hardcoded path
    $cmakeExe = Get-ItemProperty 'HKLM:\SOFTWARE\Kitware\CMake' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.InstallDir } |
                Where-Object { $_ -and (Test-Path (Join-Path $_ 'cmake.exe')) } |
                Select-Object -First 1
    if (-not $cmakeExe) {
        # Fallback: search common install parent via uninstall registry
        $cmakeExe = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'CMake*' } |
                    ForEach-Object {
                        if ($_.PSObject.Properties['InstallLocation']) { $_.InstallLocation }
                    } |
                    Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\cmake.exe')) } |
                    ForEach-Object { Join-Path $_ 'bin' } |
                    Select-Object -First 1
    }
    if (-not $cmakeExe) { Write-Log 'Could not locate CMake install dir to add to PATH.' 'WARN'; return }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$cmakeExe*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$cmakeExe", 'Machine')
        Write-Log "Added CMake to machine PATH: $cmakeExe" 'OK'
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-CMake {
    if (Get-Command cmake -ErrorAction SilentlyContinue) {
        $ver = Get-CommandVersion -Command 'cmake'
        Write-Log "CMake already installed: $ver" 'OK'
        Add-CMakeToPath
        return
    }

    if (Test-Winget) {
        Invoke-WingetInstall -Id 'Kitware.CMake' -Name 'CMake'
        Add-CMakeToPath
        return
    }

    if (-not $OfflineInstallerPath) {
        throw 'CMake is missing, winget is unavailable, and no -OfflineInstallerPath was provided.'
    }

    $msi = Find-FirstFile -Path $OfflineInstallerPath -Pattern 'cmake-*-windows-x86_64.msi'
    if (-not $msi) {
        throw 'Offline CMake installer not found. Expected cmake-*-windows-x86_64.msi.'
    }

    Invoke-MsiInstall -MsiPath $msi.FullName -Name 'CMake'
    Add-CMakeToPath
}

function Wait-VSSetup {
    # VS files appear on disk before vswhere registers the install.
    # Poll disk paths directly until Test-VSBuildTools passes.
    Write-Log 'Waiting for Visual Studio setup to complete (up to 10 minutes)...'
    $deadline = (Get-Date).AddMinutes(10)
    $attempt  = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        if (Test-VSBuildTools) {
            Write-Log "Visual Studio verified on attempt $attempt." 'OK'
            return
        }
        Write-Log "Attempt $attempt - VS not in registry yet, still installing..."
        Start-Sleep -Seconds 15
    }
    throw 'Timed out (10 min) waiting for Visual Studio setup. Re-run option 9 or install VS manually.'
}

function Install-VSBuildTools {
    if (Test-VSBuildTools) {
        Write-Log 'VS 2022+ with C++ tools and Windows SDK already detected. Skipping install.' 'OK'
        return
    }

    $override = '--wait --quiet --norestart --nocache --installPath "C:\BuildTools2022" --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.19041'

    if (Test-Winget) {
        Invoke-WingetInstall -Id 'Microsoft.VisualStudio.2022.BuildTools' -Name 'Visual Studio 2022 Build Tools' -Override $override
        Wait-VSSetup
        return
    }

    if (-not $OfflineInstallerPath) {
        throw 'VS Build Tools are missing, winget is unavailable, and no -OfflineInstallerPath was provided.'
    }

    $installer = Join-Path $OfflineInstallerPath 'vs_BuildTools.exe'
    if (-not (Test-Path $installer)) {
        throw 'Offline VS Build Tools installer not found. Expected vs_BuildTools.exe.'
    }

    Invoke-ExeInstall -InstallerPath $installer -Arguments @('--wait', '--quiet', '--norestart', '--nocache', '--installPath', 'C:\BuildTools2022', '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '--add', 'Microsoft.VisualStudio.Component.Windows10SDK.19041') -Name 'Visual Studio 2022 Build Tools'
    Wait-VSSetup
}

function Install-VCRedist {
    if ($SkipVCRedist) {
        Write-Log 'Skipping VC++ Redistributable installation due to -SkipVCRedist.' 'WARN'
        return
    }

    if (Test-VCRedist) {
        Write-Log 'VC++ Redistributable x64 already installed.' 'OK'
        return
    }

    if (Test-Winget) {
        Invoke-WingetInstall -Id 'Microsoft.VCRedist.2015+.x64' -Name 'Microsoft VC++ Redistributable x64'
        return
    }

    if (-not $OfflineInstallerPath) {
        throw 'VC++ Redistributable is missing, winget is unavailable, and no -OfflineInstallerPath was provided.'
    }

    $installer = Join-Path $OfflineInstallerPath 'VC_redist.x64.exe'
    if (-not (Test-Path $installer)) {
        throw 'Offline VC++ Redistributable installer not found. Expected VC_redist.x64.exe.'
    }

    Invoke-ExeInstall -InstallerPath $installer -Arguments @('/quiet', '/norestart') -Name 'Microsoft VC++ Redistributable x64'
}

function Test-Boost {
    $root = [Environment]::GetEnvironmentVariable('BOOST_ROOT', 'Machine')
    if (-not $root) { $root = [Environment]::GetEnvironmentVariable('BOOST_ROOT', 'User') }
    if (-not $root) { $root = $env:BOOST_ROOT }
    if (-not $root) { return $false }
    return (Test-Path (Join-Path $root 'boost\version.hpp'))
}

function Install-Boost {
    if (Test-Boost) {
        Write-Log "Boost already installed (BOOST_ROOT=$([Environment]::GetEnvironmentVariable('BOOST_ROOT','Machine')))." 'OK'
        return
    }

    # Boost is not on winget - download the prebuilt MSVC-14.3 (VS2022) 64-bit binary
    $boostVersion  = '1.87.0'
    $boostTag      = $boostVersion -replace '\.','_'
    $boostExe      = "boost_$($boostTag)-msvc-14.3-64.exe"
    $boostUrl      = "https://sourceforge.net/projects/boost/files/boost-binaries/$boostVersion/$boostExe/download"
    $boostInstaller = Join-Path $env:TEMP $boostExe

    if ($OfflineInstallerPath) {
        $offline = Join-Path $OfflineInstallerPath $boostExe
        if (Test-Path $offline) {
            $boostInstaller = $offline
            Write-Log "Using offline Boost installer: $boostInstaller"
        }
    }

    # Validate any cached copy - a previous failed download may have left a corrupt file
    if ((Test-Path $boostInstaller) -and (Get-Item $boostInstaller).Length -lt 100MB) {
        Write-Log "Cached Boost installer is too small, removing and re-downloading..."
        Remove-Item $boostInstaller -Force
    }

    if (-not (Test-Path $boostInstaller)) {
        Write-Log "Downloading Boost $boostVersion prebuilt binaries (this may take a few minutes)..."
        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (Test-Path $curlExe) {
            & $curlExe -L --silent --show-error -o $boostInstaller $boostUrl
        } else {
            Start-BitsTransfer -Source $boostUrl -Destination $boostInstaller
        }
        if (-not (Test-Path $boostInstaller) -or (Get-Item $boostInstaller).Length -lt 100MB) {
            Remove-Item $boostInstaller -ErrorAction SilentlyContinue
            throw "Failed to download Boost installer. Check internet connectivity and try again."
        }
    }

    Write-Log "Installing Boost $boostVersion..."
    $p = Start-Process -FilePath $boostInstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Boost installer exited with code $($p.ExitCode)" }

    # Find the install directory - installer puts it in C:\local\boost_X_Y_Z by default
    $boostDir = Get-ChildItem 'C:\local' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer -and $_.Name -like "boost_$boostTag*" } |
                Select-Object -First 1 -ExpandProperty FullName
    if (-not $boostDir) {
        # Search uninstall registry for InstallLocation as fallback
        $boostDir = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "Boost*$boostVersion*" } |
                    ForEach-Object { if ($_.PSObject.Properties['InstallLocation']) { $_.InstallLocation } } |
                    Select-Object -First 1
    }
    if (-not $boostDir) { throw "Could not locate Boost install directory after installation." }

    # BOOST_ROOT must use forward slashes, no trailing slash - required by AzerothCore CMake
    $boostRoot = $boostDir.TrimEnd('\').TrimEnd('/') -replace '\\','/'
    [Environment]::SetEnvironmentVariable('BOOST_ROOT', $boostRoot, 'Machine')
    $env:BOOST_ROOT = $boostRoot
    Write-Log "BOOST_ROOT set to: $boostRoot" 'OK'
    Remove-Item $boostInstaller -ErrorAction SilentlyContinue
}

function Test-OpenSSL {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.PSObject.Properties['DisplayName'] -and
                 ($_.DisplayName -match 'OpenSSL' -or $_.DisplayName -match 'FireDaemon OpenSSL') -and
                 $_.DisplayName -notmatch 'Light' -and
                 $_.PSObject.Properties['DisplayVersion'] -and
                 [version]$_.DisplayVersion -ge [version]'3.0'
             }
    return [bool]$entry
}

function Find-OpenSSLRoot {
    # ShiningLight MSI and FireDaemon EXE both leave InstallLocation blank.
    # Probe the standard default paths each installer uses before giving up.
    $candidates = @(
        'C:\Program Files\OpenSSL-Win64',
        'C:\Program Files\OpenSSL',
        'C:\OpenSSL-Win64',
        'C:\OpenSSL'
    )

    # FireDaemon uses a versioned subfolder under Program Files
    Get-ChildItem 'C:\Program Files' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer -and $_.Name -like 'FireDaemon OpenSSL*' } |
        ForEach-Object { $candidates = @($_.FullName) + $candidates }

    foreach ($path in $candidates) {
        if (Test-Path (Join-Path $path 'include\openssl\ssl.h')) {
            return $path
        }
    }
    return $null
}

function Set-OpenSSLEnvVars {
    $existing = [Environment]::GetEnvironmentVariable('OPENSSL_ROOT_DIR', 'Machine')
    if ($existing -and (Test-Path (Join-Path $existing 'include\openssl\ssl.h'))) {
        $env:OPENSSL_ROOT_DIR = $existing
        Write-Log "OPENSSL_ROOT_DIR already set: $existing" 'OK'
        return
    }

    $opensslRoot = Find-OpenSSLRoot
    if (-not $opensslRoot) {
        Write-Log 'Could not locate OpenSSL install directory - OPENSSL_ROOT_DIR not set.' 'WARN'
        Write-Log 'Expected one of: C:\Program Files\OpenSSL-Win64, C:\OpenSSL-Win64, or a FireDaemon OpenSSL* folder.' 'WARN'
        return
    }

    $opensslRoot = $opensslRoot.TrimEnd('\').TrimEnd('/')
    [Environment]::SetEnvironmentVariable('OPENSSL_ROOT_DIR', $opensslRoot, 'Machine')
    $env:OPENSSL_ROOT_DIR = $opensslRoot
    Write-Log "OPENSSL_ROOT_DIR set to: $opensslRoot" 'OK'

    $opensslBin = if (Test-Path (Join-Path $opensslRoot 'bin')) { Join-Path $opensslRoot 'bin' } else { $opensslRoot }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$opensslBin*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$opensslBin", 'Machine')
        Write-Log "Added OpenSSL bin to machine PATH: $opensslBin" 'OK'
    }
}

function Install-OpenSSL {
    if (Test-OpenSSL) {
        Write-Log 'OpenSSL 3.x (full) already installed.' 'OK'
        Set-OpenSSLEnvVars
        return
    }

    if (Test-Winget) {
        # ShiningLight.OpenSSL.Dev includes headers/libs needed by CMake (Light builds do not)
        # /VERYSILENT suppresses all Inno Setup dialogs including the DLL copy location prompt
        $override = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS=""'
        try {
            Invoke-WingetInstall -Id 'ShiningLight.OpenSSL.Dev' -Name 'OpenSSL (64-bit Dev)' -Override $override
        } catch {
            Write-Log "ShiningLight.OpenSSL.Dev failed, trying FireDaemon.OpenSSL..." 'WARN'
            Invoke-WingetInstall -Id 'FireDaemon.OpenSSL' -Name 'OpenSSL (FireDaemon)'
        }
    } elseif ($OfflineInstallerPath) {
        $installer = Find-FirstFile -Path $OfflineInstallerPath -Pattern 'Win64OpenSSL-*.exe'
        if (-not $installer) { throw 'Offline OpenSSL installer not found. Expected Win64OpenSSL-*.exe.' }
        Invoke-ExeInstall -InstallerPath $installer.FullName -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=C:\OpenSSL-Win64') -Name 'OpenSSL'
    } else {
        throw 'OpenSSL is missing, winget is unavailable, and no -OfflineInstallerPath was provided.'
    }

    Set-OpenSSLEnvVars
    Write-Log 'OpenSSL installed.' 'OK'
}

function Find-MySQLInstall {
    # Returns a hashtable with Include, Lib, and Dll paths, or $null if not found.
    # Searches registry keys written by MySQL Installer (all versions/editions).
    $regPaths = @(
        'HKLM:\SOFTWARE\MySQL AB',
        'HKLM:\SOFTWARE\WOW6432Node\MySQL AB'
    )

    $candidates = @()

    foreach ($base in $regPaths) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
            $loc = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).Location
            if ($loc -and (Test-Path $loc)) { $candidates += $loc }
        }
    }

    # Fallback: scan uninstall registry for "MySQL Server" entries with an InstallLocation
    if ($candidates.Count -eq 0) {
        $uninstallPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSObject.Properties['DisplayName'] -and
                $_.DisplayName -match 'MySQL Server' -and
                $_.PSObject.Properties['InstallLocation'] -and
                $_.InstallLocation
            } |
            ForEach-Object { $candidates += $_.InstallLocation }
    }

    foreach ($root in $candidates) {
        $inc = Join-Path $root 'include'
        $lib = Join-Path $root 'lib\libmysql.lib'
        $dll = Join-Path $root 'lib\libmysql.dll'
        if ((Test-Path $inc) -and (Test-Path $lib) -and (Test-Path $dll)) {
            return @{ Include = $inc; Lib = $lib; Dll = $dll; Root = $root }
        }
    }

    return $null
}

function Test-MySQLStaged {
    param([string]$ScriptRoot)
    $inc = Join-Path $ScriptRoot 'Database\include'
    $lib = Join-Path $ScriptRoot 'Database\lib\libmysql.lib'
    $dll = Join-Path $ScriptRoot 'Database\lib\libmysql.dll'
    return (Test-Path $inc) -and (Test-Path $lib) -and (Test-Path $dll)
}

function Stage-MySQLFiles {
    if (Test-MySQLStaged -ScriptRoot $ScriptRoot) {
        Write-Log 'MySQL headers and libraries already staged in Database\.' 'OK'
        return
    }

    $mysql = Find-MySQLInstall
    if (-not $mysql) {
        Write-Log 'MySQL Server installation not found via registry. Install MySQL Server and re-run, or stage Database\include\ and Database\lib\ manually.' 'WARN'
        return
    }

    Write-Log "Found MySQL installation at: $($mysql.Root)"

    $destInc = Join-Path $ScriptRoot 'Database\include'
    $destLib = Join-Path $ScriptRoot 'Database\lib'

    if (-not (Test-Path $destInc)) { New-Item -ItemType Directory -Path $destInc | Out-Null }
    if (-not (Test-Path $destLib)) { New-Item -ItemType Directory -Path $destLib | Out-Null }

    Copy-Item -Path "$($mysql.Include)\*" -Destination $destInc -Recurse -Force
    Copy-Item -Path $mysql.Lib -Destination $destLib -Force
    Copy-Item -Path $mysql.Dll -Destination $destLib -Force

    Write-Log 'MySQL headers and libraries staged in Database\.' 'OK'
}

function Get-StagedMySQLDllPath {
    param([string]$ScriptRoot)
    $dll = Join-Path $ScriptRoot 'Database\lib\libmysql.dll'
    if (Test-Path $dll) { return $dll }
    return $null
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Verify-All {
    $results = [ordered]@{}

    $results['Git'] = Check-Command -Command 'git'
    $results['CMake'] = Check-Command -Command 'cmake'
    $results['VS C++ Tools + Windows SDK'] = Test-VSBuildTools
    $results['VCRedistX64'] = $SkipVCRedist -or (Test-VCRedist)
    $results['Boost >= 1.78'] = Test-Boost
    $results['OpenSSL 3.x'] = Test-OpenSSL
    $boostRoot = [Environment]::GetEnvironmentVariable('BOOST_ROOT', 'Machine')
    $results['BOOST_ROOT env var'] = $boostRoot -and (Test-Path (Join-Path $boostRoot 'boost\version.hpp'))
    $opensslRoot = [Environment]::GetEnvironmentVariable('OPENSSL_ROOT_DIR', 'Machine')
    $results['OPENSSL_ROOT_DIR env var'] = $opensslRoot -and (Test-Path (Join-Path $opensslRoot 'include\openssl\ssl.h'))
    $results['MySQL staged (Database\)'] = Test-MySQLStaged -ScriptRoot $ScriptRoot

    Write-Log 'Verification summary:'
    foreach ($k in $results.Keys) {
        $ok = $results[$k]
        $lvl = if ($ok) { 'OK' } else { 'ERROR' }
        Write-Log (" - {0}: {1}" -f $k, ($(if ($ok) { 'PASS' } else { 'FAIL' }))) $lvl
    }

    return $results
}

function Invoke-CheckOnly {
    Write-Log 'Checking build dependencies.'
    Write-Log "Log file: $LogPath"

    $results = Verify-All

    $failed = @($results.GetEnumerator() | Where-Object { -not $_.Value })
    if ($failed.Count -gt 0) {
        Write-Log 'One or more checks failed.' 'ERROR'
        exit 1
    }

    Write-Log 'All dependency checks passed.' 'OK'
    exit 0
}

try {
    if ($CheckOnly) {
        Invoke-CheckOnly
    }

    Write-Log 'Starting build dependency installer.'
    Write-Log "Log file: $LogPath"

    Ensure-Admin

    if ($OfflineInstallerPath) {
        Write-Log "Offline installer path set: $OfflineInstallerPath"
    }

    Install-Git
    Install-CMake
    Install-VSBuildTools
    Install-VCRedist
    Install-Boost
    Install-OpenSSL
    Stage-MySQLFiles

    Refresh-Path

    $verify = Verify-All
    $failed = @($verify.GetEnumerator() | Where-Object { -not $_.Value })

    if ($failed.Count -gt 0) {
        Write-Log 'One or more dependency checks failed.' 'ERROR'
        exit 1
    }

    Write-Log 'All build dependencies are installed and verified.' 'OK'
    exit 0
}
catch {
    Write-Log ("Fatal error: " + $_.Exception.Message) 'ERROR'
    Write-Log "See log: $LogPath" 'ERROR'
    exit 1
}
