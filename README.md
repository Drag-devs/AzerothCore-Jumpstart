# AzerothCore Build Scripts

PowerShell scripts for building [AzerothCore](https://www.azerothcore.org/) with custom modules on Windows. Includes an interactive build menu and an automated dependency installer.

## Files

| File | Purpose |
|---|---|
| `Build-AzerothCoreAndModules.ps1` | Interactive build menu - main entry point |
| `Install-Build-Dependencies.ps1` | Installs and verifies all required build tools |
| `build-config.json` | Defines the AzerothCore repo URL and module list |

---

## Prerequisites

### MySQL (manual install required)

**MySQL is not installed by the dependency script.** You must install MySQL separately and place the required files at these paths relative to the script root:

```
Database\include\   - MySQL headers (e.g. mysql.h)
Database\lib\libmysql.lib
```

The simplest way to obtain these is to install [MySQL Server](https://dev.mysql.com/downloads/mysql/) (8.0 recommended) and copy the `include` and `lib` folders from the MySQL installation into your `Database\` directory. The `libmysql.dll` must also be accessible at runtime (either in the same folder as the server binaries or on `PATH`).

### Automated Dependencies

The following are installed automatically by `Install-Build-Dependencies.ps1`:

| Dependency | Version | Install Method |
|---|---|---|
| Git | Latest | winget / offline |
| CMake | Latest | winget / offline |
| Visual Studio 2022 Build Tools | 17+ with C++ workload and Windows 10 SDK | winget / offline |
| Microsoft VC++ Redistributable x64 | 2015+ | winget / offline |
| Boost (prebuilt MSVC 14.3 binaries) | 1.87.0 | SourceForge download / offline |
| OpenSSL (full, not Light) | 3.x | winget / offline |

The script sets the `BOOST_ROOT` and `OPENSSL_ROOT_DIR` machine-level environment variables automatically after installation.

---

## Directory Layout

These scripts must live in the **root directory where builds will happen**. The expected layout after setup is:

```
<root>\
    Build-AzerothCoreAndModules.ps1
    Install-Build-Dependencies.ps1
    build-config.json
    Database\
        include\        <- MySQL headers
        lib\
            libmysql.lib
    Source\             <- cloned automatically by the build script
    build-test\         <- CMake build output (TEST builds)
    build-stable\       <- CMake build output (STABLE builds)
    logs\               <- installer and dependency check logs
```

Place all three scripts and `build-config.json` directly in this root folder before running anything. Do not run them from a subdirectory - relative paths are resolved from `$PSScriptRoot`.

---

## First-Time Setup

1. Copy the scripts and `build-config.json` into your build root directory.
2. Install MySQL and copy headers/lib into `Database\` as described above.
3. Right-click `Build-AzerothCoreAndModules.ps1` and choose **Run with PowerShell**, or run it from a PowerShell terminal:
   ```powershell
   .\Build-AzerothCoreAndModules.ps1
   ```
4. Select **option 9** to install build dependencies. A UAC prompt will appear - accept it.
5. Once complete, select **option 8** to verify all dependencies passed.
6. Select **option 1** for a first-time TEST build (clones source + modules, configures CMake, full build).

---

## Build Menu Options

| Option | Description |
|---|---|
| 1 | TEST - `git pull` existing source (or clone if missing) + CMake configure + clean build |
| 2 | STABLE - CMake configure + clean build, no git operations |
| 3 | TEST - wipe source entirely, fresh `git clone` + CMake configure + clean build |
| 4 | TEST - CMake configure + clean build using current local source, no git |
| 5 | TEST - incremental build only, no CMake configure, no clean (fastest) |
| 8 | Check all build dependencies without installing anything |
| 9 | Install build dependencies (opens an elevated PowerShell window) |
| 0 | Exit |

**TEST** builds output to `build-test\bin\RelWithDebInfo`.
**STABLE** builds output to `build-stable\bin\RelWithDebInfo`.

---

## Configuring Modules

Edit `build-config.json` to control which AzerothCore fork and modules are built:

```json
{
  "azerothcore": "https://github.com/your-org/azerothcore-wotlk",
  "modules": [
    "https://github.com/your-org/your-module"
  ]
}
```

Modules are cloned into `Source\modules\` and are wiped and re-cloned on any build option that performs a `git` update (options 1 and 3). Option 4 and 5 leave the modules directory untouched.

---

## Limitations

- **Windows only.** The scripts use winget, the Windows Registry, MSI/EXE installers, and Visual Studio toolchains. Linux/macOS builds are not supported.
- **MySQL is not automated.** The dependency installer does not install MySQL or configure the database server. See the Prerequisites section above.
- **Visual Studio 2022 only.** CMake is configured with the `"Visual Studio 17 2022"` generator. Earlier versions of Visual Studio are not supported.
- **x64 only.** All build targets and library paths are hardcoded for 64-bit Windows.
- **Boost download requires internet access** unless an offline installer path is provided via `-OfflineInstallerPath`. The Boost binary is approximately 300 MB.
- **Offline mode** requires all installers to be pre-staged at the path passed to `-OfflineInstallerPath`. See installer function comments for expected filenames.
- The build script does not install or start the AzerothCore database. That step must be performed separately using the AzerothCore database tools after a successful build.

---

## Offline / Air-Gapped Installation

Pass the path to a folder containing pre-downloaded installers:

```powershell
.\Install-Build-Dependencies.ps1 -OfflineInstallerPath "D:\Installers"
```

Expected filenames in that folder:

| File | Tool |
|---|---|
| `Git-*-64-bit.exe` | Git |
| `cmake-*-windows-x86_64.msi` | CMake |
| `vs_BuildTools.exe` | Visual Studio 2022 Build Tools |
| `VC_redist.x64.exe` | VC++ Redistributable |
| `boost_1_87_0-msvc-14.3-64.exe` | Boost 1.87.0 |
| `Win64OpenSSL-*.exe` | OpenSSL |

---

## Dependency Check Only

Run without installing to verify the current environment:

```powershell
.\Install-Build-Dependencies.ps1 -CheckOnly
```

Exits with code `0` if all checks pass, `1` if any fail. Log files are written to the `logs\` directory.
