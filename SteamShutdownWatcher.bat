@echo off
setlocal
title Steam Shutdown Watcher

set "TMPPS=%TEMP%\SteamShutdownWatcher_%RANDOM%%RANDOM%%RANDOM%.ps1"
set "SSW_BAT=%~f0"
set "SSW_TMPPS=%TMPPS%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$bat=$env:SSW_BAT; $out=$env:SSW_TMPPS; $marker=('### SSW_'+'POWERSHELL ###'); $text=Get-Content -LiteralPath $bat -Raw; $pos=$text.IndexOf($marker); if($pos -lt 0){ exit 2 }; $payload=$text.Substring($pos + $marker.Length); Set-Content -LiteralPath $out -Value $payload -Encoding UTF8"
if errorlevel 1 (
    echo Could not unpack the embedded watcher.
    echo.
    pause
    exit /b 1
)

echo Steam Shutdown Watcher
echo.
echo Start this BAT before or during a Steam download.
echo It finds Steam libraries automatically, detects the active AppID,
echo and shuts Windows down after that AppID stops changing for 5 minutes.
echo.
echo A log is saved next to this BAT: SteamShutdownWatcher.log
echo Close this window or press Ctrl+C to stop.
echo Test mode from cmd: SteamShutdownWatcher.bat -DryRun
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

### SSW_POWERSHELL ###
param(
    [string]$SteamPath,
    [string[]]$AppId = @(),
    [int]$PollSeconds = 15,
    [double]$QuietMinutes = 5,
    [int]$ShutdownTimeout = 60,
    [switch]$DryRun
)

$BatDir = Split-Path -Parent $env:SSW_BAT
$LogPath = Join-Path $BatDir 'SteamShutdownWatcher.log'

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] $Message"
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
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
        if (Test-Path -LiteralPath (Join-Path $p 'steamapps') -PathType Container) {
            return (Resolve-Path -LiteralPath $p).Path
        }
        throw "The SteamPath folder does not contain steamapps: $ExplicitPath"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:STEAM_PATH) { $candidates.Add($env:STEAM_PATH) }

    foreach ($keyPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\Software\WOW6432Node\Valve\Steam',
        'HKLM:\Software\Valve\Steam'
    )) {
        try {
            $props = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            if ($props.SteamPath) { $candidates.Add([string]$props.SteamPath) }
            if ($props.InstallPath) { $candidates.Add([string]$props.InstallPath) }
        } catch {}
    }

    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Steam')) }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $p = $candidate -replace '/', '\'
        if (Test-Path -LiteralPath (Join-Path $p 'steamapps') -PathType Container) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }

    throw 'Steam was not found. You can run this BAT with: -SteamPath "C:\Path\To\Steam"'
}

function Get-SteamLibraries {
    param([string]$Root)

    $libraries = New-Object System.Collections.Generic.List[string]
    $libraries.Add($Root)

    $libraryFile = Join-Path $Root 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
        try {
            $text = Get-Content -LiteralPath $libraryFile -Raw -ErrorAction Stop
            foreach ($match in ([regex]'"path"\s+"((?:\\.|[^"\\])*)"').Matches($text)) {
                $p = (ConvertFrom-VdfEscaped $match.Groups[1].Value) -replace '/', '\'
                if (Test-Path -LiteralPath (Join-Path $p 'steamapps') -PathType Container) {
                    $libraries.Add((Resolve-Path -LiteralPath $p).Path)
                }
            }
        } catch {
            Write-Log "Could not parse Steam library file: $($_.Exception.Message)"
        }
    }

    return @($libraries | Select-Object -Unique)
}

function Get-TreeSignature {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }

    $count = 0
    $bytes = [int64]0
    $latest = [int64]0

    try {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue) {
            $count += 1
            if (-not $item.PSIsContainer) { $bytes += [int64]$item.Length }
            if ($item.LastWriteTimeUtc.Ticks -gt $latest) { $latest = $item.LastWriteTimeUtc.Ticks }
        }
    } catch {}

    return "$count|$bytes|$latest"
}

function Find-AppManifest {
    param([string[]]$Libraries, [string]$OneAppId)
    foreach ($library in $Libraries) {
        $manifest = Join-Path $library "steamapps\appmanifest_$OneAppId.acf"
        if (Test-Path -LiteralPath $manifest -PathType Leaf) { return $manifest }
    }
    return $null
}

function Find-AppLibrary {
    param([string[]]$Libraries, [string]$OneAppId)
    foreach ($library in $Libraries) {
        if (Test-Path -LiteralPath (Join-Path $library "steamapps\appmanifest_$OneAppId.acf") -PathType Leaf) {
            return $library
        }
        if (Test-Path -LiteralPath (Join-Path $library "steamapps\downloading\$OneAppId")) {
            return $library
        }
    }
    return $null
}

function Get-DownloadingAppStates {
    param([string[]]$Libraries)

    $states = @{}
    foreach ($library in $Libraries) {
        $dir = Join-Path $library 'steamapps\downloading'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        foreach ($folder in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' })) {
            $part = "$library|$(Get-TreeSignature -Path $folder.FullName)"
            if ($states.ContainsKey($folder.Name)) {
                $states[$folder.Name] += "`n$part"
            } else {
                $states[$folder.Name] = $part
            }
        }
    }
    return $states
}

function Get-ActiveAppIds {
    param([string[]]$Libraries, [hashtable]$PreviousDownloadStates)

    $active = New-Object System.Collections.Generic.HashSet[string]
    foreach ($id in @(Get-IncompleteManifestAppIds -Libraries $Libraries)) {
        [void]$active.Add($id)
    }

    # Steam often leaves old folders in downloading. They count only after their contents change.
    $currentDownloadStates = Get-DownloadingAppStates -Libraries $Libraries
    foreach ($id in $currentDownloadStates.Keys) {
        if ($PreviousDownloadStates.ContainsKey($id) -and $PreviousDownloadStates[$id] -ne $currentDownloadStates[$id]) {
            [void]$active.Add($id)
        }
    }

    $PreviousDownloadStates.Clear()
    foreach ($id in $currentDownloadStates.Keys) {
        $PreviousDownloadStates[$id] = $currentDownloadStates[$id]
    }

    return @($active)
}

function Get-IncompleteManifestAppIds {
    param([string[]]$Libraries)
    $ids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($library in $Libraries) {
        $steamApps = Join-Path $library 'steamapps'
        if (-not (Test-Path -LiteralPath $steamApps -PathType Container)) { continue }

        foreach ($file in Get-ChildItem -LiteralPath $steamApps -File -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            if ($file.BaseName -notmatch '^appmanifest_(\d+)$') { continue }
            $id = $matches[1]
            try { $pairs = Read-VdfPairs -Path $file.FullName } catch { continue }

            $toDownload = Get-IntValue -Data $pairs -Key 'BytesToDownload'
            $downloaded = Get-IntValue -Data $pairs -Key 'BytesDownloaded'
            $toStage = Get-IntValue -Data $pairs -Key 'BytesToStage'
            $staged = Get-IntValue -Data $pairs -Key 'BytesStaged'

            if (($toDownload -gt 0 -and $downloaded -lt $toDownload) -or ($toStage -gt 0 -and $staged -lt $toStage)) {
                [void]$ids.Add($id)
            }
        }
    }
    return @($ids)
}

function Get-WatchedState {
    param([string[]]$Libraries, [string[]]$WatchedIds)

    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($id in @($WatchedIds | Sort-Object { [int64]$_ } | Select-Object -Unique)) {
        $library = Find-AppLibrary -Libraries $Libraries -OneAppId $id
        $parts.Add("APP=$id")

        if (-not $library) {
            $parts.Add('LIB=missing')
            continue
        }

        $steamApps = Join-Path $library 'steamapps'
        $parts.Add("LIB=$library")
        $parts.Add('DOWN=' + (Get-TreeSignature (Join-Path $steamApps "downloading\$id")))

        $manifest = Join-Path $steamApps "appmanifest_$id.acf"
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            $file = Get-Item -LiteralPath $manifest
            $parts.Add("MAN=$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
            try {
                $pairs = Read-VdfPairs -Path $manifest
                foreach ($key in @('StateFlags', 'BytesToDownload', 'BytesDownloaded', 'BytesToStage', 'BytesStaged', 'UpdateResult')) {
                    if ($pairs.ContainsKey($key)) { $parts.Add("$key=$($pairs[$key])") }
                }
            } catch {
                $parts.Add('MANREAD=failed')
            }
        } else {
            $parts.Add('MAN=missing')
        }
    }

    return ($parts -join "`n")
}

function Format-Ids {
    param([string[]]$Ids)
    $items = @($Ids | Where-Object { $_ } | Sort-Object { [int64]$_ } | Select-Object -Unique)
    if ($items.Count -eq 0) { return 'none' }
    return ($items -join ', ')
}

function Invoke-Shutdown {
    if ($DryRun) {
        Write-Log "DRY RUN: would execute: shutdown /s /t $ShutdownTimeout"
        return
    }
    Write-Log "Executing: shutdown /s /t $ShutdownTimeout"
    & shutdown /s /t $ShutdownTimeout
}

if ($PollSeconds -lt 5) { $PollSeconds = 5 }
if ($QuietMinutes -lt 0) { $QuietMinutes = 0 }

$targetIds = @($AppId | Where-Object { $_ } | ForEach-Object { [string]$_ })
$badIds = @($targetIds | Where-Object { $_ -notmatch '^\d+$' })
if ($badIds.Count -gt 0) {
    Write-Log "Invalid AppId value(s): $($badIds -join ', ')"
    exit 2
}

try {
    Set-Content -LiteralPath $LogPath -Value "Steam Shutdown Watcher log started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
} catch {}

try {
    $steamRoot = Resolve-SteamRoot -ExplicitPath $SteamPath
} catch {
    Write-Log $_.Exception.Message
    exit 2
}

$libraries = @(Get-SteamLibraries -Root $steamRoot)
$watched = New-Object System.Collections.Generic.HashSet[string]
foreach ($id in $targetIds) { [void]$watched.Add($id) }

$lastState = $null
$quietSince = $null
$quietSeconds = $QuietMinutes * 60
$previousDownloadStates = @{}

Write-Log "Steam folder: $steamRoot"
Write-Log "Steam libraries:"
foreach ($library in $libraries) { Write-Log "  $library" }
if ($targetIds.Count -gt 0) {
    Write-Log "Watching selected AppID(s): $(Format-Ids $targetIds)"
} else {
    Write-Log 'Auto mode: waiting for active Steam AppID(s).'
}
Write-Log "Shutdown after watched AppID(s) stop changing for $QuietMinutes quiet minute(s)."
if ($DryRun) {
    Write-Log 'Dry-run mode. The computer will NOT shut down.'
} else {
    Write-Log 'Shutdown is enabled. Cancel a scheduled shutdown with: shutdown /a'
}
Write-Log 'Press Ctrl+C to stop.'

try {
    while ($true) {
        $libraries = @(Get-SteamLibraries -Root $steamRoot)

        if ($targetIds.Count -eq 0) {
            $found = @(Get-ActiveAppIds -Libraries $libraries -PreviousDownloadStates $previousDownloadStates) |
                Where-Object { $_ } | Select-Object -Unique

            foreach ($id in $found) { [void]$watched.Add($id) }
            if ($found.Count -gt 0) {
                Write-Log "Detected active AppID(s): $(Format-Ids $found)"
            }
        }

        $watchedIds = @($watched)
        if ($watchedIds.Count -eq 0) {
            Write-Log 'No active Steam AppID detected yet.'
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $state = Get-WatchedState -Libraries $libraries -WatchedIds $watchedIds

        if ($null -eq $lastState) {
            $lastState = $state
            $quietSince = Get-Date
            Write-Log "Started watching AppID(s): $(Format-Ids $watchedIds)"
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if ($state -ne $lastState) {
            $lastState = $state
            $quietSince = Get-Date
            Write-Log "Watched AppID(s) changed: $(Format-Ids $watchedIds). Quiet timer reset."
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $elapsed = ((Get-Date) - $quietSince).TotalSeconds
        $remaining = [math]::Max(0, $quietSeconds - $elapsed)

        if ($remaining -gt 0) {
            Write-Log ("Watched AppID(s) quiet for {0:N0}s; waiting {1:N0}s more." -f $elapsed, $remaining)
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        Write-Log 'Watched Steam AppID(s) have been quiet long enough. Shutting down.'
        Invoke-Shutdown
        exit 0
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    exit 130
} catch {
    Write-Log "Unexpected error: $($_.Exception.Message)"
    exit 1
}
