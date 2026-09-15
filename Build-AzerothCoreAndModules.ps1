$WorkDir = $PSScriptRoot
$SrcDir = "$WorkDir\Source"
$BuildDirStable = "$WorkDir\build-stable"
$BuildDirTest = "$WorkDir\build-test"
$MySqlInclude = "$WorkDir\Database\include"
$MySqlLib = "$WorkDir\Database\lib\libmysql.lib"

$cfg = Get-Content "$WorkDir\build-config.json" | ConvertFrom-Json

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
    Write-Host "[8] Check build dependencies"
    Write-Host "[9] Install build dependencies (requires admin - opens new window)"
    Write-Host ""
    Write-Host "[0] Exit"
    Write-Host ""
    $choice = Read-Host "Enter choice"

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

Write-Host ""
Write-Host "======================================================"
Write-Host "  Build complete for choice $choice."
Write-Host "  Output: $buildDir\bin\RelWithDebInfo"
Write-Host "======================================================"
Read-Host "Press Enter to exit"
