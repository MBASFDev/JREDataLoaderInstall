<#
.SYNOPSIS
    Automated installer: Azul Zulu JRE (latest) + Salesforce Data Loader (latest).
    Windows version - uses only built-in PowerShell/Windows tools, no Python required.

.NOTES
    Behavior summary:
      - If not running elevated, prompts (pop-up) to relaunch as Administrator.
      - If NEITHER Java nor Data Loader is found -> installs both (latest).
      - If EITHER is found but out of date -> updates whichever is out of date.
      - If BOTH are found and already latest -> shows a pop-up confirming this
        and exits without re-downloading anything.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$Env:ProgramFiles\Zulu",
    [switch]$Silent   # skip the directory prompt, just use $InstallDir / default
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Popup($message, $title = "Installer") {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($message, $title, `
        [System.Windows.Forms.MessageBoxButtons]::OK, `
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Find-JavaExe {
    <#
        Looks for an existing java.exe in several ways, since Java isn't
        always on PATH or JAVA_HOME after install:
          1. java on PATH
          2. an existing JAVA_HOME (machine or user scope)
          3. a direct filesystem search of common install locations,
             checking the fast-path "<root>\bin\java.exe" first, falling
             back to an error-tolerant recursive search.
    #>
    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCmd) { return $javaCmd.Source }

    $existingHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
    if (-not $existingHome) { $existingHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "User") }
    if ($existingHome) {
        $candidate = Join-Path $existingHome "bin\java.exe"
        if (Test-Path $candidate) { return $candidate }
    }

    $searchRoots = @(
        "$Env:ProgramFiles\Zulu",
        "${Env:ProgramFiles(x86)}\Zulu",
        "$Env:ProgramFiles\Java",
        "${Env:ProgramFiles(x86)}\Java",
        "$Env:ProgramFiles\Eclipse Adoptium",
        "$Env:ProgramFiles\Microsoft\jdk*"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $searchRoots) {
        $direct = Join-Path $root "bin\java.exe"
        if (Test-Path $direct) { return $direct }

        $found = Get-ChildItem -Path $root -Filter "java.exe" -Recurse -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

function Get-InstalledJavaVersion {
    $javaExePath = Find-JavaExe
    if (-not $javaExePath) { return $null }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $verOutput = & $javaExePath -version 2>&1 | Select-Object -First 1
        if ($verOutput -match '"([\d\._]+)"') {
            return @{ Version = $matches[1]; Path = $javaExePath }
        }
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return $null
}

function Compare-VersionStrings($installed, $latest) {
    $instParts   = ($installed -split '[._]') | ForEach-Object { [int]($_ -replace '\D', '0') }
    $latestParts = ($latest    -split '[._]') | ForEach-Object { [int]($_ -replace '\D', '0') }
    $maxLen = [Math]::Max($instParts.Count, $latestParts.Count)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $a = if ($i -lt $instParts.Count)   { $instParts[$i] }   else { 0 }
        $b = if ($i -lt $latestParts.Count) { $latestParts[$i] } else { 0 }
        if ($a -lt $b) { return $false }
        if ($a -gt $b) { return $true }
    }
    return $true
}

function Get-JarManifestVersion($jarPath) {
    # Reads Implementation-Version out of the jar's own MANIFEST.MF instead of
    # trusting the filename - survives naming changes across releases.
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq "META-INF/MANIFEST.MF" } | Select-Object -First 1
            if (-not $entry) { return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try {
                $manifest = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
            if ($manifest -match 'Implementation-Version:\s*(\S+)') { return $matches[1] }
        } finally {
            $zip.Dispose()
        }
    } catch {
        return $null
    }
    return $null
}

function Find-InstalledDataLoader {
    $searchRoots = @(
        [Environment]::GetFolderPath("Desktop"),
        $Env:ProgramFiles,
        ${Env:ProgramFiles(x86)},
        $Env:USERPROFILE,
        "C:\"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($root in $searchRoots) {
        $jars = Get-ChildItem -Path $root -Filter "dataloader*.jar" -Recurse -Depth 4 -Force -ErrorAction SilentlyContinue
        foreach ($jar in $jars) {
            $version = Get-JarManifestVersion -jarPath $jar.FullName
            if ($version) { return @{ Version = $version; Path = $jar.FullName } }
            # Fallback: parse the filename if the manifest lookup didn't pan out
            if ($jar.Name -match 'dataloader-?(\d+(?:\.\d+)+)') {
                return @{ Version = $matches[1]; Path = $jar.FullName }
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# PHASE 0: Ensure the script is running elevated (Administrator).
# If not, prompt the user to confirm, then relaunch elevated automatically.
# Works whether the script was downloaded and run locally, or invoked via
# "irm <url> | iex" (in that case we re-launch using the same URL).
# ---------------------------------------------------------------------------
if (-not (Test-Admin)) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $response = [System.Windows.Forms.MessageBox]::Show(
        "This installer needs Administrator rights to install Java and Data Loader system-wide.`n`nRelaunch this script as Administrator now?",
        "Administrator rights required",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($response -eq [System.Windows.Forms.DialogResult]::Yes) {
        Write-Host "Relaunching elevated ..." -ForegroundColor Yellow

        # $PSCommandPath is empty when run via "irm <url> | iex" (piped, no
        # local file) - in that case, relaunch by re-downloading + running
        # from the same URL. Otherwise, relaunch the local script file.
        if ($PSCommandPath) {
            $relaunchArgs = @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
            if ($Silent) { $relaunchArgs += "-Silent" }
            Start-Process -FilePath "powershell.exe" -ArgumentList $relaunchArgs -Verb RunAs
        } else {
            $scriptUrl = "https://raw.githubusercontent.com/MBASFDev/JREDataLoaderInstall/main/Install-AzulAndDataLoader.ps1"
            $relaunchCmd = "irm $scriptUrl | iex"
            if ($Silent) { $relaunchCmd = "& { `$Silent = `$true; $relaunchCmd }" }
            Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $relaunchCmd) -Verb RunAs
        }
        exit 0
    } else {
        Write-Host "Cannot continue without Administrator rights. Exiting." -ForegroundColor Red
        exit 1
    }
}

try {
# ---------------------------------------------------------------------------
# PHASE 1: Detect system specs
# ---------------------------------------------------------------------------
Write-Host "=== Phase 1: Detecting system specifications ===" -ForegroundColor Cyan

$arch = $Env:PROCESSOR_ARCHITECTURE
switch ($arch) {
    "AMD64" { $zuluArch = "x64" }
    "ARM64" { $zuluArch = "aarch64" }
    default { $zuluArch = "x86" }
}

Write-Host "Detected OS: Windows | Arch: $zuluArch"
Write-Host "Running as Administrator: $true"

# ---------------------------------------------------------------------------
# PHASE 2: Prompt for install directory
# ---------------------------------------------------------------------------
Write-Host "`n=== Phase 2: Choose install directory ===" -ForegroundColor Cyan
Write-Host "Default: $InstallDir"

if (-not $Silent) {
    $userInput = Read-Host "Press Enter to accept the default, or type a custom path"
    if ($userInput.Trim().Length -gt 0) { $InstallDir = $userInput.Trim() }
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-Host "Using install directory: $InstallDir"

# ---------------------------------------------------------------------------
# PHASE 3: Check for an existing Java install, skip if already latest,
#          otherwise download + install latest Azul Zulu JRE (MSI)
# ---------------------------------------------------------------------------
Write-Host "`n=== Phase 3: Checking / Installing Azul Zulu JRE ===" -ForegroundColor Cyan

$azulApi = "https://api.azul.com/metadata/v1/zulu/packages/"
$queryParams = "java_package_type=jre&os=windows&arch=$zuluArch&archive_type=msi&latest=true&release_status=ga&availability_types=CA&page=1&page_size=1"
$metaUrl = "$azulApi`?$queryParams"

Write-Host "Querying Azul metadata API for the latest JRE version ..."
$packages = Invoke-RestMethod -Uri $metaUrl -Method Get

if (-not $packages -or $packages.Count -eq 0) {
    throw "Could not find a matching Azul Zulu JRE MSI package. Check https://www.azul.com/downloads/ manually."
}

$pkgUuid = $packages[0].package_uuid
$detail = Invoke-RestMethod -Uri "$azulApi$pkgUuid" -Method Get
$downloadUrl = $detail.download_url
$latestJavaVersion = ($detail.java_version -join ".")
Write-Host "Latest Azul Zulu JRE available: $latestJavaVersion"

$existingJava = Get-InstalledJavaVersion
$javaUpToDate = $false

if ($existingJava) {
    Write-Host "Found existing Java install: version $($existingJava.Version) at $($existingJava.Path)"
    if (Compare-VersionStrings -installed $existingJava.Version -latest $latestJavaVersion) {
        Write-Host "Installed Java is already up to date (or newer)." -ForegroundColor Yellow
        $javaUpToDate = $true
    } else {
        Write-Host "Installed Java ($($existingJava.Version)) is older than the latest ($latestJavaVersion) - will upgrade."
    }
} else {
    Write-Host "No existing Java installation detected."
}

if (-not $javaUpToDate) {
    $tempMsi = Join-Path $Env:TEMP "zulu_jre_installer.msi"
    Write-Host "Downloading: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempMsi -UseBasicParsing

    Write-Host "Installing MSI silently to $InstallDir ..."
    $msiArgs = @("/i", "`"$tempMsi`"", "/qn", "INSTALLDIR=`"$InstallDir`"")
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -notin @(0, 3010)) {
        throw "msiexec failed with exit code $($proc.ExitCode). Try re-running this script as Administrator."
    }
    if ($proc.ExitCode -eq 3010) {
        Write-Host "Install succeeded but a reboot is recommended to fully apply changes." -ForegroundColor Yellow
    }
    Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
    Write-Host "Azul Zulu JRE installed/updated."
} else {
    Write-Host "Azul Zulu JRE install skipped (already latest)."
}

# ---------------------------------------------------------------------------
# PHASE 3b: Locate JAVA_HOME and persist environment variables
# ---------------------------------------------------------------------------
Write-Host "`n=== Phase 3b: Configuring JAVA_HOME / PATH ===" -ForegroundColor Cyan

if ($javaUpToDate -and $existingJava) {
    $javaHome = (Get-Item $existingJava.Path).Directory.Parent.FullName
} else {
    $javaExePath = Find-JavaExe
    if (-not $javaExePath) {
        throw "Could not locate java.exe under $InstallDir after install."
    }
    $javaHome = (Get-Item $javaExePath).Directory.Parent.FullName
}
Write-Host "JAVA_HOME will be set to: $javaHome"

[Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$javaHome\bin*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$javaHome\bin", "Machine")
}
Write-Host "JAVA_HOME and PATH set at Machine scope."

$Env:JAVA_HOME = $javaHome
$Env:PATH = "$javaHome\bin;$Env:PATH"

Write-Host "Verifying Java install ..."
& "$javaHome\bin\java.exe" -version

# ---------------------------------------------------------------------------
# PHASE 4: Check for an existing Data Loader install anywhere on the system,
#          compare with the latest available version, and only download +
#          reinstall if missing or outdated.
# ---------------------------------------------------------------------------
Write-Host "`n=== Phase 4: Checking / Installing Salesforce Data Loader ===" -ForegroundColor Cyan

$dataLoaderPage = "https://developer.salesforce.com/tools/data-loader"
$releasesApi = "https://api.github.com/repos/forcedotcom/dataloader/releases/latest"
Write-Host "Querying the Data Loader GitHub releases API for the latest version ..."

$winUrl = $null
$latestDataLoaderVersion = $null
try {
    $releaseInfo = Invoke-RestMethod -Uri $releasesApi -Headers @{ "User-Agent" = "PowerShell" }
    $latestDataLoaderVersion = $releaseInfo.tag_name -replace '^v', ''
    $winAsset = $releaseInfo.assets |
        Where-Object { $_.name -match '\.zip$' -and $_.name -match 'win' } |
        Select-Object -First 1
    if (-not $winAsset) {
        # some releases don't tag "win" in the name - fall back to any zip asset
        $winAsset = $releaseInfo.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    }
    if ($winAsset) { $winUrl = $winAsset.browser_download_url }
} catch {
    Write-Host "GitHub releases API lookup failed, falling back to scraping the download page ..." -ForegroundColor Yellow
}

if (-not $winUrl) {
    Write-Host "Fetching Data Loader page to find the latest Windows download link ..."
    $html = Invoke-WebRequest -Uri $dataLoaderPage -UseBasicParsing | Select-Object -ExpandProperty Content
    $dlMatches = [regex]::Matches($html, 'https://[^\s"''<>]+dataloader[^\s"''<>]*\.zip', 'IgnoreCase')
    $winUrl = $dlMatches | Where-Object { $_.Value -match "win" } | Select-Object -First 1 -ExpandProperty Value
    if (-not $winUrl -and $dlMatches.Count -gt 0) { $winUrl = $dlMatches[0].Value }
    if (-not $winUrl) {
        throw "Could not auto-detect the Data Loader download URL. Get it manually from $dataLoaderPage"
    }
    if (-not $latestDataLoaderVersion -and $winUrl -match '(\d+(?:\.\d+)+)') {
        $latestDataLoaderVersion = $matches[1]
    }
}
Write-Host "Latest Data Loader available: $(if ($latestDataLoaderVersion) { $latestDataLoaderVersion } else { '(version unknown, will treat as needing install)' })"

Write-Host "Searching common locations for an existing Data Loader install ..."
$existingDataLoader = Find-InstalledDataLoader
$dataLoaderUpToDate = $false

if ($existingDataLoader) {
    Write-Host "Found existing Data Loader: version $($existingDataLoader.Version) at $($existingDataLoader.Path)"
    if ($latestDataLoaderVersion -and (Compare-VersionStrings -installed $existingDataLoader.Version -latest $latestDataLoaderVersion)) {
        Write-Host "Installed Data Loader is already up to date (or newer)." -ForegroundColor Yellow
        $dataLoaderUpToDate = $true
    } else {
        Write-Host "Installed Data Loader ($($existingDataLoader.Version)) is older than the latest ($latestDataLoaderVersion) - will upgrade."
    }
} else {
    Write-Host "No existing Data Loader installation detected."
}

if ($javaUpToDate -and $dataLoaderUpToDate) {
    $msg = "Both Azul Zulu JRE ($($existingJava.Version)) and Salesforce Data Loader " +
           "($($existingDataLoader.Version)) are already up to date. No changes were made."
    Write-Host "`n$msg" -ForegroundColor Green
    Show-Popup -message $msg -title "Nothing to install"
    exit 0
}

if (-not $dataLoaderUpToDate) {
    $desktopDir = [Environment]::GetFolderPath("Desktop")
    $tempZip = Join-Path $desktopDir "dataloader.zip"
    Write-Host "Downloading: $winUrl"
    Invoke-WebRequest -Uri $winUrl -OutFile $tempZip -UseBasicParsing

    $versionSuffix = if ($latestDataLoaderVersion) { "v$latestDataLoaderVersion" } else { "v_unknown" }
    $extractDir = Join-Path $desktopDir "dataloader_$versionSuffix"

    # Clean up any leftover shortcuts pointing at an older Data Loader
    # install (install.bat creates a Desktop shortcut for Data Loader) so
    # upgrades don't leave a dead/duplicate shortcut behind.
    $oldShortcuts = Get-ChildItem -Path $desktopDir -Filter "*.lnk" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "Data ?Loader" }
    foreach ($shortcut in $oldShortcuts) {
        Write-Host "Removing outdated Data Loader shortcut: $($shortcut.FullName)"
        Remove-Item $shortcut.FullName -Force -ErrorAction SilentlyContinue
    }

    # Clean up any older dataloader_v* folders on the Desktop so we don't
    # leave stale/outdated installs lying around after an upgrade.
    $oldVersionDirs = Get-ChildItem -Path $desktopDir -Directory -Filter "dataloader_v*" -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -ne $extractDir }
    foreach ($oldDir in $oldVersionDirs) {
        Write-Host "Removing outdated Data Loader folder: $($oldDir.FullName)"
        Remove-Item $oldDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    Write-Host "Data Loader package extracted to: $extractDir"

    $installScript = Get-ChildItem -Path $extractDir -Filter "install.bat" -Recurse | Select-Object -First 1
    if (-not $installScript) {
        throw "Could not find install.bat in the downloaded Data Loader package."
    }

    Write-Host "Running Data Loader installer: $($installScript.FullName)"
    Push-Location $installScript.Directory.FullName
    try {
        & $installScript.FullName
    } finally {
        Pop-Location
    }
    Write-Host "Data Loader installed/updated."
} else {
    Write-Host "Data Loader install skipped (already latest)."
}

Write-Host "`n=== All installations complete! ===" -ForegroundColor Green
Write-Host "JAVA_HOME: $javaHome"
Write-Host "Open a new terminal session for PATH changes to take effect elsewhere."

} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
} finally {
    Write-Host "`nPress Enter to close this window..."
    Read-Host | Out-Null
}
