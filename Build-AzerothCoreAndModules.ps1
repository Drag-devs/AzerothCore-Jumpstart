$WorkDir = $PSScriptRoot
$SrcDir = "$WorkDir\Source"
$BuildDirStable = "$WorkDir\build-stable"
$BuildDirTest = "$WorkDir\build-test"
$MySqlInclude = "$WorkDir\Database\include"
$MySqlLib = "$WorkDir\Database\lib\libmysql.lib"

$cfg = Get-Content "$WorkDir\build-config.json" | ConvertFrom-Json

function Find-MySQLDll {
    # Returns the path to libmysql.dll: first checks staged Database\lib\, then registry.
    $staged = Join-Path $WorkDir 'Database\lib\libmysql.dll'
    if (Test-Path $staged) { return $staged }

    $regPaths = @('HKLM:\SOFTWARE\MySQL AB', 'HKLM:\SOFTWARE\WOW6432Node\MySQL AB')
    foreach ($base in $regPaths) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
            $loc = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).Location
            if ($loc) {
                $dll = Join-Path $loc 'lib\libmysql.dll'
                if (Test-Path $dll) { return $dll }
            }
        }
    }

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $result = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'MySQL Server' -and $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation } |
        ForEach-Object {
            $dll = Join-Path $_.InstallLocation 'lib\libmysql.dll'
            if (Test-Path $dll) { $dll }
        } | Select-Object -First 1
    if ($result) { return $result }

    # Fallback: check build-config.json for a user-supplied mysqlDir
    $configPath = Join-Path $WorkDir 'build-config.json'
    if (Test-Path $configPath) {
        try {
            $cfgMysql = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfgMysql.PSObject.Properties['mysqlDir'] -and $cfgMysql.mysqlDir) {
                $dll = Join-Path $cfgMysql.mysqlDir 'lib\libmysql.dll'
                if (Test-Path $dll) { return $dll }
            }
        } catch { }
    }

    return $null
}

function Invoke-PostBuildSetup {
    param([Parameter(Mandatory = $true)][string]$BuildOutputDir)

    if (-not (Test-Path $BuildOutputDir)) {
        Write-Host "[SKIP] Build output not found: $BuildOutputDir"
        return
    }

    Write-Host ""
    Write-Host "Post-build setup: $BuildOutputDir"

    # Copy libmysql.dll
    $mysqlDll = Find-MySQLDll
    if ($mysqlDll) {
        Copy-Item $mysqlDll -Destination $BuildOutputDir -Force
        Write-Host "  [OK] Copied libmysql.dll from $mysqlDll"
    } else {
        Write-Host "  [WARN] libmysql.dll not found - install MySQL Server or stage Database\lib\ manually."
    }

    # Copy OpenSSL DLLs
    $opensslBin = $null
    $opensslRoot = [Environment]::GetEnvironmentVariable('OPENSSL_ROOT_DIR', 'Machine')
    if (-not $opensslRoot) { $opensslRoot = $env:OPENSSL_ROOT_DIR }
    if ($opensslRoot -and (Test-Path (Join-Path $opensslRoot 'bin'))) {
        $opensslBin = Join-Path $opensslRoot 'bin'
    }

    if ($opensslBin) {
        foreach ($dll in @('legacy.dll', 'libcrypto-3-x64.dll', 'libssl-3-x64.dll')) {
            $src = Join-Path $opensslBin $dll
            if (Test-Path $src) {
                Copy-Item $src -Destination $BuildOutputDir -Force
                Write-Host "  [OK] Copied $dll"
            } else {
                Write-Host "  [WARN] $dll not found in $opensslBin"
            }
        }
    } else {
        Write-Host "  [WARN] OPENSSL_ROOT_DIR not set - OpenSSL DLLs not copied. Run option 9 first."
    }

    Write-Host ""
    Write-Host "  Config reminder - update these settings in worldserver.conf and authserver.conf:"
    Write-Host "    SourceDirectory  = path to your source folder (this repo's Source\ directory)"
    Write-Host "      -> $SrcDir"
    Write-Host "    DataDir          = path to your extracted client data folder (dbc, maps, vmaps, etc.)"
    Write-Host "    LoginDatabaseInfo, WorldDatabaseInfo, CharacterDatabaseInfo = MySQL connection strings"
    Write-Host "  Configs are in: $BuildOutputDir\configs\"
}

# Run a dependency script in the same console window via Start-Process -NoNewWindow.
function Invoke-DependencyScript {
    param([string]$ScriptPath, [string[]]$ExtraArgs = @())
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}

$choice = $null
while ($true) {
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "  AzerothCore Build Script"
    Write-Host "======================================================"
    Write-Host "[1] Build TEST  - git pull + cmake configure + clean build"
    Write-Host "[2] Build STABLE - cmake configure + clean build (no git)"
    Write-Host "[3] Build TEST  - git clone (wipe source) + cmake configure + clean build"
    Write-Host "[4] Build TEST  - cmake configure + clean build (no git)"
    Write-Host "[5] Build TEST  - cmake build only, no configure, no clean (fastest)"
    Write-Host ""
    Write-Host "[6] Post-build setup - copy DLLs and show config reminders"
    Write-Host ""
    Write-Host "[8] Check build dependencies"
    Write-Host "[9] Install build dependencies (requires admin - opens new window)"
    Write-Host ""
    Write-Host "[0] Exit"
    Write-Host ""
    $choice = Read-Host "Enter choice"

    if ($choice -eq "6") {
        Write-Host ""
        foreach ($dir in @($BuildDirTest, $BuildDirStable)) {
            if (Test-Path "$dir\bin\RelWithDebInfo") {
                Invoke-PostBuildSetup -BuildOutputDir "$dir\bin\RelWithDebInfo"
            }
        }
        Write-Host ""
        Read-Host "Press Enter to return to menu"
        continue
    }

    if ($choice -eq "8") {
        Write-Host ""
        $rc = Invoke-DependencyScript "$WorkDir\Install-Build-Dependencies.ps1" @('-CheckOnly', '-NoAutoElevate')
        if ($rc -eq 0) {
            Write-Host ""
            Write-Host "All dependency checks passed."
        } else {
            Write-Host ""
            Write-Host "[WARN] One or more dependency checks failed. Run option 9 to install missing items."
        }
        Write-Host ""
        Read-Host "Press Enter to return to menu"
        continue
    }

    if ($choice -eq "9") {
        Write-Host ""
        Write-Host "Launching installer elevated. A UAC prompt will appear - click Yes to continue."
        Write-Host ""
        # Must use Start-Process -Verb RunAs for elevation; output appears in the new window
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$WorkDir\Install-Build-Dependencies.ps1`"") `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if ($p.ExitCode -eq 0) {
            Write-Host "Installation completed successfully. Run option 8 to verify."
        } else {
            Write-Host "[WARN] Installer exited with code $($p.ExitCode). Check the logs\ folder for details."
        }
        Write-Host ""
        Read-Host "Press Enter to return to menu"
        continue
    }

    if ($choice -eq "0") {
        Write-Host "Exiting."
        exit 0
    }

    if ($choice -notin @("1","2","3","4","5")) {
        Write-Host "[ERROR] Invalid choice '$choice'."
        continue
    }

    break
}

$buildDir = $BuildDirTest
$updateSource = $false
$cleanSource = $false
$incremental = $false

switch ($choice) {
    "1" { $updateSource = $true;  Write-Host "Building TEST version..." }
    "2" { $buildDir = $BuildDirStable; Write-Host "Building STABLE version..." }
    "3" { $updateSource = $true; $cleanSource = $true; Write-Host "Building TEST version with fresh source..." }
    "4" { Write-Host "Building TEST from current local source..." }
    "5" { $incremental = $true; Write-Host "Incremental build TEST from current local source..." }
}

Set-Location $WorkDir

# Refresh PATH and user env vars so tools installed this session are found
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
if (-not $env:BOOST_ROOT) { $env:BOOST_ROOT = [Environment]::GetEnvironmentVariable('BOOST_ROOT','Machine') }
if (-not $env:OPENSSL_ROOT_DIR) { $env:OPENSSL_ROOT_DIR = [Environment]::GetEnvironmentVariable('OPENSSL_ROOT_DIR','Machine') }

# Verify required tools and env vars are present before doing any work
$missingTools = @('git','cmake') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missingTools.Count -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] Required tools not found on PATH: $($missingTools -join ', ')"
    Write-Host "        Run option 9 from the main menu to install build dependencies."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

$missingVars = @{}
if (-not $env:BOOST_ROOT)        { $missingVars['BOOST_ROOT'] = 'Boost installation directory' }
if (-not $env:OPENSSL_ROOT_DIR)  { $missingVars['OPENSSL_ROOT_DIR'] = 'OpenSSL installation directory' }
if ($missingVars.Count -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] Required environment variables are not set:"
    foreach ($v in $missingVars.GetEnumerator()) {
        Write-Host "        $($v.Key) - $($v.Value)"
    }
    Write-Host "        Run option 9 from the main menu to install build dependencies."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# Treat source dir as missing if it exists but isn't a git repo
$srcIsRepo = (Test-Path $SrcDir) -and (Test-Path "$SrcDir\.git")

# Handle source
if ($cleanSource) {
    if (Test-Path $SrcDir) { Remove-Item $SrcDir -Recurse -Force }
    Write-Host "Cloning fresh AzerothCore repo..."
    git clone $cfg.azerothcore $SrcDir
} elseif ($updateSource) {
    if ($srcIsRepo) {
        Set-Location $SrcDir
        git reset --hard
        git pull
        Set-Location $WorkDir
    } else {
        if (Test-Path $SrcDir) { Remove-Item $SrcDir -Recurse -Force }
        Write-Host "Source not found or not a git repo, cloning fresh..."
        git clone $cfg.azerothcore $SrcDir
    }
} else {
    if (-not $srcIsRepo) {
        Write-Host "[ERROR] Source directory not found or not a git repo. Run option 1 or 3 first."
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "Using current local source..."
}

# Ensure modules directory exists
if (-not (Test-Path "$SrcDir\modules")) { New-Item -ItemType Directory -Path "$SrcDir\modules" | Out-Null }

# Refresh modules only when updating source
if ($updateSource) {
    Set-Location "$SrcDir\modules"
    Write-Host "Refreshing modules..."
    foreach ($url in $cfg.modules) {
        $name = $url.Split('/')[-1]
        if (Test-Path $name) { Remove-Item $name -Recurse -Force }
        git clone $url
    }
    Set-Location $WorkDir
}

if (-not $incremental) {
    Write-Host ""
    Write-Host "Configuring CMake for choice $choice..."
    cmake -S $SrcDir `
          -B $buildDir `
          -G "Visual Studio 17 2022" -A x64 `
          -DMYSQL_INCLUDE_DIR="$MySqlInclude" `
          -DMYSQL_LIBRARY="$MySqlLib" `
          --fresh

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "[ERROR] CMake configuration failed. Check output above."
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }
}

if ($incremental) {
    Write-Host ""
    Write-Host "Incremental build (skipping CMake configure)..."
    cmake --build $buildDir --config RelWithDebInfo
} else {
    cmake --build $buildDir --config RelWithDebInfo --clean-first
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ERROR] Build failed. Check output above."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "======================================================"
Write-Host "  Build complete for choice $choice."
Write-Host "  Output: $buildDir\bin\RelWithDebInfo"
Write-Host "======================================================"

Invoke-PostBuildSetup -BuildOutputDir "$buildDir\bin\RelWithDebInfo"

Write-Host ""
Write-Host "Next steps:"
Write-Host "  - If not already done, copy .conf.dist files to .conf in the configs\ folder"
Write-Host "  - Set DataDir in worldserver.conf to your extracted client data folder"
Write-Host "  - Set database connection strings (LoginDatabaseInfo, WorldDatabaseInfo, CharacterDatabaseInfo)"
Write-Host "  - See: https://www.azerothcore.org/wiki/windows-server-setup"
Write-Host ""
Read-Host "Press Enter to exit"
