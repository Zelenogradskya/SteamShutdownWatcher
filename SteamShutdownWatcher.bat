@echo off
setlocal
title Steam Shutdown Watcher

set "TMPPS=%TEMP%\SteamShutdownWatcher_%RANDOM%%RANDOM%.ps1"
set "SSW_BAT=%~f0"
set "SSW_TMPPS=%TMPPS%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$bat=$env:SSW_BAT; $out=$env:SSW_TMPPS; $marker=('### POWERSHELL_'+'PAYLOAD ###'); $text=Get-Content -LiteralPath $bat -Raw; $pos=$text.IndexOf($marker); if($pos -lt 0){ exit 2 }; $payload=$text.Substring($pos + $marker.Length); Set-Content -LiteralPath $out -Value $payload -Encoding UTF8"
if errorlevel 1 (
    echo Could not unpack the embedded PowerShell watcher.
    echo.
    pause
    exit /b 1
)

echo Steam Shutdown Watcher
echo.
echo This single BAT file will find Steam, detect Steam library folders,
echo wait for active downloads/installations to finish, then shut Windows down.
echo.
echo Close this window or press Ctrl+C to stop watching.
echo To test without shutdown, run this BAT from cmd with: -DryRun
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%" %*
set "EXIT_CODE=%ERRORLEVEL%"

del "%TMPPS%" >nul 2>nul

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Watcher exited with code %EXIT_CODE%.
    echo.
    pause
)

exit /b %EXIT_CODE%

### POWERSHELL_PAYLOAD ###
param(
    [string[]]$AppId = @(),
    [string]$SteamPath,
    [int]$PollSeconds = 20,
    [double]$StableMinutes = 5,
    [int]$ShutdownTimeout = 60,
    [switch]$DryRun,
    [switch]$AssumeActive
)

$InstalledFlag = 4

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$stamp] $Message"
}

function ConvertFrom-VdfEscaped {
    param([string]$Value)
    return $Value.Replace('\"', '"').Replace('\\', '\')
}

function Read-VdfPairs {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $result = @{}
    $regex = [regex]'"((?:\\.|[^"\\])*)"\s+"((?:\\.|[^"\\])*)"'
    foreach ($match in $regex.Matches($text)) {
        $key = ConvertFrom-VdfEscaped $match.Groups[1].Value
        $value = ConvertFrom-VdfEscaped $match.Groups[2].Value
        $result[$key] = $value
    }
    return $result
}

function Get-IntValue {
    param([hashtable]$Data, [string]$Key)
    $value = [int64]0
    if ($Data.ContainsKey($Key)) {
        [void][int64]::TryParse([string]$Data[$Key], [ref]$value)
    }
    return $value
}

function Resolve-SteamRoot {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        $p = $ExplicitPath -replace '/', '\'
        if (Test-Path -LiteralPath (Join-Path $p "steamapps") -PathType Container) {
            return (Resolve-Path -LiteralPath $p).Path
        }
        throw "The SteamPath folder does not contain steamapps: $ExplicitPath"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:STEAM_PATH) { $candidates.Add($env:STEAM_PATH) }

    foreach ($keyPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\Software\WOW6432Node\Valve\Steam",
        "HKLM:\Software\Valve\Steam"
    )) {
        try {
            $props = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            if ($props.SteamPath) { $candidates.Add([string]$props.SteamPath) }
            if ($props.InstallPath) { $candidates.Add([string]$props.InstallPath) }
        } catch {
        }
    }

    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} "Steam")) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles "Steam")) }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $p = $candidate -replace '/', '\'
        if (Test-Path -LiteralPath (Join-Path $p "steamapps") -PathType Container) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }

    throw "Steam was not found. Run this BAT with: -SteamPath `"C:\Path\To\Steam`""
}

function Get-SteamLibraries {
    param([string]$Root)

    $libraries = New-Object System.Collections.Generic.List[string]
    $libraries.Add($Root)

    $libraryFile = Join-Path $Root "steamapps\libraryfolders.vdf"
    if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
        try {
            $text = Get-Content -LiteralPath $libraryFile -Raw -ErrorAction Stop
            foreach ($match in ([regex]'"path"\s+"((?:\\.|[^"\\])*)"').Matches($text)) {
                $p = (ConvertFrom-VdfEscaped $match.Groups[1].Value) -replace '/', '\'
                if (Test-Path -LiteralPath (Join-Path $p "steamapps") -PathType Container) {
                    $libraries.Add((Resolve-Path -LiteralPath $p).Path)
                }
            }
        } catch {
            Write-Log "Could not parse libraryfolders.vdf: $($_.Exception.Message)"
        }
    }

    return @($libraries | Select-Object -Unique)
}

function Get-DownloadingAppIds {
    param([string[]]$Libraries)
    $ids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($library in $Libraries) {
        $dir = Join-Path $library "steamapps\downloading"
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' } |
            ForEach-Object { [void]$ids.Add($_.Name) }
    }
    return @($ids)
}

function Get-AppManifests {
    param([string[]]$Libraries)
    foreach ($library in $Libraries) {
        $steamApps = Join-Path $library "steamapps"
        if (Test-Path -LiteralPath $steamApps -PathType Container) {
            Get-ChildItem -LiteralPath $steamApps -File -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue
        }
    }
}

function Get-ManifestAppId {
    param($File)
    if ($File.BaseName -match '^appmanifest_(\d+)$') { return $matches[1] }
    return $null
}

function Get-ManifestSignature {
    param($File)
    try {
        $pairs = Read-VdfPairs -Path $File.FullName
        $state = Get-IntValue -Data $pairs -Key "StateFlags"
        $dl = Get-IntValue -Data $pairs -Key "BytesDownloaded"
        $stage = Get-IntValue -Data $pairs -Key "BytesStaged"
        return "$($File.LastWriteTimeUtc.Ticks)|$state|$dl|$stage|$($File.Length)"
    } catch {
        return "$($File.LastWriteTimeUtc.Ticks)|$($File.Length)"
    }
}

function New-ManifestSnapshot {
    param([string[]]$Libraries)
    $snapshot = @{}
    foreach ($file in Get-AppManifests -Libraries $Libraries) {
        $id = Get-ManifestAppId $file
        if ($id) { $snapshot[$id] = Get-ManifestSignature $file }
    }
    return $snapshot
}

function Get-ChangedManifestAppIds {
    param([string[]]$Libraries, [hashtable]$Snapshot)
    $changed = New-Object System.Collections.Generic.HashSet[string]
    foreach ($file in Get-AppManifests -Libraries $Libraries) {
        $id = Get-ManifestAppId $file
        if (-not $id) { continue }
        $sig = Get-ManifestSignature $file
        if ($Snapshot.ContainsKey($id) -and $Snapshot[$id] -ne $sig) {
            [void]$changed.Add($id)
        }
        $Snapshot[$id] = $sig
    }
    return @($changed)
}

function Get-IncompleteManifestAppIds {
    param([string[]]$Libraries)
    $ids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($file in Get-AppManifests -Libraries $Libraries) {
        $id = Get-ManifestAppId $file
        if (-not $id) { continue }
        try { $pairs = Read-VdfPairs -Path $file.FullName } catch { continue }
        $toDownload = Get-IntValue -Data $pairs -Key "BytesToDownload"
        $downloaded = Get-IntValue -Data $pairs -Key "BytesDownloaded"
        $toStage = Get-IntValue -Data $pairs -Key "BytesToStage"
        $staged = Get-IntValue -Data $pairs -Key "BytesStaged"
        if (($toDownload -gt 0 -and $downloaded -lt $toDownload) -or ($toStage -gt 0 -and $staged -lt $toStage)) {
            [void]$ids.Add($id)
        }
    }
    return @($ids)
}

function Find-AppManifest {
    param([string[]]$Libraries, [string]$OneAppId)
    foreach ($library in $Libraries) {
        $manifest = Join-Path $library "steamapps\appmanifest_$OneAppId.acf"
        if (Test-Path -LiteralPath $manifest -PathType Leaf) { return $manifest }
    }
    return $null
}

function Test-AppComplete {
    param([string[]]$Libraries, [string]$OneAppId)

    if ((Get-DownloadingAppIds -Libraries $Libraries) -contains $OneAppId) {
        return @{ Complete = $false; Reason = "still has a steamapps\downloading folder" }
    }

    $manifest = Find-AppManifest -Libraries $Libraries -OneAppId $OneAppId
    if (-not $manifest) {
        return @{ Complete = $false; Reason = "manifest not found yet" }
    }

    try { $data = Read-VdfPairs -Path $manifest } catch {
        return @{ Complete = $false; Reason = "manifest unreadable: $($_.Exception.Message)" }
    }

    $name = if ($data.ContainsKey("name") -and $data["name"]) { $data["name"] } else { "appid $OneAppId" }
    $toDownload = Get-IntValue -Data $data -Key "BytesToDownload"
    $downloaded = Get-IntValue -Data $data -Key "BytesDownloaded"
    $toStage = Get-IntValue -Data $data -Key "BytesToStage"
    $staged = Get-IntValue -Data $data -Key "BytesStaged"

    if ($toDownload -gt 0 -and $downloaded -lt $toDownload) {
        return @{ Complete = $false; Reason = "$name downloading $downloaded/$toDownload bytes" }
    }
    if ($toStage -gt 0 -and $staged -lt $toStage) {
        return @{ Complete = $false; Reason = "$name installing $staged/$toStage bytes" }
    }

    if ($data.ContainsKey("installdir") -and $data["installdir"]) {
        $installDir = Join-Path (Split-Path -Parent $manifest) ("common\" + $data["installdir"])
        if (Test-Path -LiteralPath $installDir -PathType Container) {
            return @{ Complete = $true; Reason = "$name install folder exists" }
        }
        return @{ Complete = $false; Reason = "$name install folder not found yet" }
    }

    $flags = Get-IntValue -Data $data -Key "StateFlags"
    if (($flags -band $InstalledFlag) -eq $InstalledFlag) {
        return @{ Complete = $true; Reason = "$name installed flag is set" }
    }

    return @{ Complete = $false; Reason = "$name is not complete yet" }
}

function Format-Ids {
    param([string[]]$Ids)
    $items = @($Ids | Where-Object { $_ } | Sort-Object { [int64]$_ } | Select-Object -Unique)
    if ($items.Count -eq 0) { return "none" }
    return ($items -join ", ")
}

function Invoke-Shutdown {
    param([bool]$NoShutdown)
    if ($NoShutdown) {
        Write-Log "DRY RUN: would execute: shutdown /s /t $ShutdownTimeout"
        return
    }
    Write-Log "Executing: shutdown /s /t $ShutdownTimeout"
    & shutdown /s /t $ShutdownTimeout
}

if ($PollSeconds -lt 5) { $PollSeconds = 5 }
if ($StableMinutes -lt 0) { $StableMinutes = 0 }

$targetAppIds = @($AppId | Where-Object { $_ } | ForEach-Object { [string]$_ })
$badIds = @($targetAppIds | Where-Object { $_ -notmatch '^\d+$' })
if ($badIds.Count -gt 0) {
    Write-Log "Invalid AppId value(s): $($badIds -join ', ')"
    exit 2
}

try {
    $steamRoot = Resolve-SteamRoot -ExplicitPath $SteamPath
} catch {
    Write-Log $_.Exception.Message
    exit 2
}

$libraries = @(Get-SteamLibraries -Root $steamRoot)
$snapshot = New-ManifestSnapshot -Libraries $libraries
$watched = New-Object System.Collections.Generic.HashSet[string]
$observed = [bool]$AssumeActive
$stableSince = $null
$stableSeconds = $StableMinutes * 60

Write-Log "Steam folder: $steamRoot"
Write-Log "Steam libraries:"
foreach ($library in $libraries) { Write-Log "  $library" }
if ($targetAppIds.Count -gt 0) {
    Write-Log "Watching selected AppID(s): $(Format-Ids $targetAppIds)"
} else {
    Write-Log "Auto mode: watching Steam downloads/installations that appear or change."
}
if ($DryRun) {
    Write-Log "Dry-run mode. The computer will NOT shut down."
} else {
    Write-Log "Shutdown is enabled. Cancel later with: shutdown /a"
}
Write-Log "Press Ctrl+C to stop."

try {
    while ($true) {
        $libraries = @(Get-SteamLibraries -Root $steamRoot)
        $downloading = @(Get-DownloadingAppIds -Libraries $libraries)
        $incomplete = @(Get-IncompleteManifestAppIds -Libraries $libraries)
        $changed = @(Get-ChangedManifestAppIds -Libraries $libraries -Snapshot $snapshot)
        $activitySignals = @($downloading + $changed) | Where-Object { $_ } | Select-Object -Unique
        $observationSignals = @($downloading + $changed + $incomplete) | Where-Object { $_ } | Select-Object -Unique

        if ($targetAppIds.Count -gt 0) {
            foreach ($id in $targetAppIds) { [void]$watched.Add($id) }
            $relevantActivity = @($activitySignals | Where-Object { $targetAppIds -contains $_ })
            $relevantObservation = @($observationSignals | Where-Object { $targetAppIds -contains $_ })
        } else {
            foreach ($id in $observationSignals) { [void]$watched.Add($id) }
            $relevantActivity = @($activitySignals | Where-Object { @($watched) -contains $_ })
            $relevantObservation = @($observationSignals | Where-Object { @($watched) -contains $_ })
        }

        if ($relevantObservation.Count -gt 0) {
            $observed = $true
        }

        if ($relevantActivity.Count -gt 0) {
            $stableSince = $null
            Write-Log "Steam activity detected: $(Format-Ids $relevantActivity)"
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if ($watched.Count -eq 0) {
            Write-Log "No Steam download/install activity detected yet."
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if (-not $observed -and $targetAppIds.Count -gt 0) {
            Write-Log "Selected AppID(s) are not active yet."
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if ($null -eq $stableSince) {
            $stableSince = Get-Date
            Write-Log "No Steam download/install activity now. Starting quiet timer."
        }

        $elapsed = ((Get-Date) - $stableSince).TotalSeconds
        $remaining = [math]::Max(0, $stableSeconds - $elapsed)
        if ($remaining -gt 0) {
            Write-Log ("Stable for {0:N0}s; waiting {1:N0}s more." -f $elapsed, $remaining)
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        Write-Log "Steam has been quiet long enough. Shutting down."
        Invoke-Shutdown -NoShutdown ([bool]$DryRun)
        exit 0
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    exit 130
} catch {
    Write-Log "Unexpected error: $($_.Exception.Message)"
    exit 1
}
