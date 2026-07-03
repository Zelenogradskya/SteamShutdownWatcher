@echo off
setlocal
title Steam Shutdown Watcher

set "TMPPS=%TEMP%\SteamShutdownWatcher_%RANDOM%%RANDOM%.ps1"
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
echo It finds Steam and Steam library folders automatically.
echo If Steam download/install files stop changing for 5 minutes, Windows shuts down.
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
    [int]$PollSeconds = 15,
    [double]$QuietMinutes = 5,
    [int]$ShutdownTimeout = 60,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$BatDir = Split-Path -Parent $env:SSW_BAT
$LogPath = Join-Path $BatDir 'SteamShutdownWatcher.log'

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] $Message"
    Write-Host $line
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
    }
}

function ConvertFrom-VdfEscaped {
    param([string]$Value)
    return $Value.Replace('\"', '"').Replace('\\', '\')
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
        } catch {
        }
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

    if (-not (Test-Path -LiteralPath $Path)) {
        return 'missing'
    }

    $count = 0
    $bytes = [int64]0
    $latest = [int64]0

    try {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue) {
            $count += 1
            if (-not $item.PSIsContainer) {
                $bytes += [int64]$item.Length
            }
            $ticks = $item.LastWriteTimeUtc.Ticks
            if ($ticks -gt $latest) {
                $latest = $ticks
            }
        }
    } catch {
    }

    return "$count|$bytes|$latest"
}

function Test-TreeHasFiles {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    try {
        $item = Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        return $null -ne $item
    } catch {
        return $false
    }
}

function Get-WatcherState {
    param([string[]]$Libraries)

    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($library in $Libraries) {
        $steamApps = Join-Path $library 'steamapps'
        $parts.Add("LIB=$library")
        $parts.Add('DOWN=' + (Get-TreeSignature (Join-Path $steamApps 'downloading')))
        $parts.Add('TEMP=' + (Get-TreeSignature (Join-Path $steamApps 'temp')))
        $parts.Add('WORKSHOP=' + (Get-TreeSignature (Join-Path $steamApps 'workshop\downloads')))

        if (Test-Path -LiteralPath $steamApps -PathType Container) {
            foreach ($manifest in Get-ChildItem -LiteralPath $steamApps -File -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
                $parts.Add("MAN=$($manifest.Name)|$($manifest.Length)|$($manifest.LastWriteTimeUtc.Ticks)")
            }
        }
    }

    return ($parts -join "`n")
}

function Get-BlockingFolders {
    param([string[]]$Libraries)

    $folders = New-Object System.Collections.Generic.List[string]

    foreach ($library in $Libraries) {
        $steamApps = Join-Path $library 'steamapps'
        $path = Join-Path $steamApps 'downloading'
        if (Test-TreeHasFiles $path) {
            $folders.Add($path)
        }
    }

    return @($folders)
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

try {
    $steamRoot = Resolve-SteamRoot -ExplicitPath $SteamPath
} catch {
    Write-Log $_.Exception.Message
    exit 2
}

try {
    Set-Content -LiteralPath $LogPath -Value "Steam Shutdown Watcher log started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
} catch {
}

$libraries = @(Get-SteamLibraries -Root $steamRoot)
$lastState = Get-WatcherState -Libraries $libraries
$quietSince = Get-Date
$quietSeconds = $QuietMinutes * 60

Write-Log "Steam folder: $steamRoot"
Write-Log "Steam libraries:"
foreach ($library in $libraries) { Write-Log "  $library" }
Write-Log "Armed immediately. Shutdown after $QuietMinutes quiet minute(s)."
Write-Log "Quiet means: no changes in Steam download/install folders and appmanifest files."
Write-Log "Leftover steamapps\downloading folders are allowed if they stop changing."
if ($DryRun) {
    Write-Log 'Dry-run mode. The computer will NOT shut down.'
} else {
    Write-Log 'Shutdown is enabled. Cancel a scheduled shutdown with: shutdown /a'
}
Write-Log 'Press Ctrl+C to stop.'

try {
    while ($true) {
        Start-Sleep -Seconds $PollSeconds

        $libraries = @(Get-SteamLibraries -Root $steamRoot)
        $state = Get-WatcherState -Libraries $libraries
        $blockingFolders = @(Get-BlockingFolders -Libraries $libraries)

        if ($state -ne $lastState) {
            $lastState = $state
            $quietSince = Get-Date
            Write-Log 'Steam download/install files changed. Quiet timer reset.'
            continue
        }

        $elapsed = ((Get-Date) - $quietSince).TotalSeconds
        $remaining = [math]::Max(0, $quietSeconds - $elapsed)

        if ($remaining -gt 0) {
            if ($blockingFolders.Count -gt 0) {
                Write-Log ("Steam is quiet for {0:N0}s; waiting {1:N0}s more. Leftover downloading folder(s): {2}" -f $elapsed, $remaining, $blockingFolders.Count)
            } else {
                Write-Log ("Steam is quiet for {0:N0}s; waiting {1:N0}s more." -f $elapsed, $remaining)
            }
            continue
        }

        Write-Log 'Steam has been quiet long enough. Shutting down.'
        Invoke-Shutdown
        exit 0
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    exit 130
} catch {
    Write-Log "Unexpected error: $($_.Exception.Message)"
    exit 1
}
