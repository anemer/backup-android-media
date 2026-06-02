[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot,
    [string[]]$SourceDirs = @('/sdcard/DCIM', '/sdcard/Pictures', '/sdcard/Movies'),
    [string[]]$Extensions = @('.jpg', '.jpeg', '.png', '.heic', '.webp', '.gif', '.mp4', '.mov', '.m4v', '.3gp', '.mkv', '.webm'),
    [string]$FilenameContains,
    [string]$FilenameStartsWith,
    [string]$Serial,
    [switch]$DeleteAfterCopy,
    [switch]$SummaryOnly,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $adbCommand = Get-Command adb -ErrorAction Stop
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adbCommand.Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($Arguments | ForEach-Object {
        '"' + ($_ -replace '(\\*)"', '$1$1\"') + '"'
    }) -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $exitCode = $process.ExitCode
    $combinedOutput = @($standardOutput, $standardError) -join [Environment]::NewLine
    $output = @(
        $combinedOutput -split "`r?`n" | Where-Object { $_ -ne '' }
    )

    if (-not $AllowFailure -and $exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if (-not $message) {
            $message = 'adb command failed without output.'
        }

        throw "adb $($Arguments -join ' ') failed with exit code $exitCode. $message"
    }

    return [string[]]$output
}

function Get-AdbArgs {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Tail
    )

    if ($Serial) {
        return @('-s', $Serial) + $Tail
    }

    return $Tail
}

function ConvertTo-ShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Get-RemoteFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Directories
    )

    $matches = New-Object System.Collections.Generic.List[string]

    foreach ($directory in $Directories) {
        $shellDirectory = ConvertTo-ShellLiteral -Value $directory
        $command = "if [ -d $shellDirectory ]; then find $shellDirectory -type f; fi"
        $lines = Invoke-Adb -Arguments (Get-AdbArgs -Tail @('shell', $command))

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if (-not $trimmed) {
                continue
            }

            $fileName = [System.IO.Path]::GetFileName($trimmed)

            if ($FilenameStartsWith) {
                if (-not $fileName.StartsWith($FilenameStartsWith, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
            }

            if ($FilenameContains) {
                if ($fileName.IndexOf($FilenameContains, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue
                }
            }

            $extension = [System.IO.Path]::GetExtension($trimmed)
            if ($extension -and $Extensions -contains $extension.ToLowerInvariant()) {
                $matches.Add($trimmed)
            }
        }
    }

    return $matches
}

function Get-RemoteSize {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )

    $shellPath = ConvertTo-ShellLiteral -Value $RemotePath
    $sizeText = Invoke-Adb -Arguments (Get-AdbArgs -Tail @('shell', "stat -c '%s' $shellPath"))
    return [long]($sizeText | Select-Object -First 1).Trim()
}

function Format-ByteSize {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $size = [double]$Bytes
    $unitIndex = 0

    while ($size -ge 1024 -and $unitIndex -lt ($units.Length - 1)) {
        $size = $size / 1024
        $unitIndex++
    }

    if ($unitIndex -eq 0) {
        return "$Bytes $($units[$unitIndex])"
    }

    return ('{0:N2} {1}' -f $size, $units[$unitIndex])
}

function Get-DeviceProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    return ((Invoke-Adb -Arguments (Get-AdbArgs -Tail @('shell', 'getprop', $PropertyName))) | Select-Object -First 1).Trim()
}

function Get-DestinationPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    foreach ($sourceDir in $SourceDirs) {
        if ($RemotePath.StartsWith($sourceDir + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $RemotePath.Substring($sourceDir.Length + 1) -replace '/', '\'
            $sourceLeaf = Split-Path -Path $sourceDir -Leaf
            return Join-Path $BasePath (Join-Path $sourceLeaf $relativePath)
        }
    }

    $fallbackName = $RemotePath.TrimStart('/') -replace '/', '\'
    return Join-Path $BasePath $fallbackName
}

function Copy-RemoteFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [string]$LocalPath
    )

    $parent = Split-Path -Path $LocalPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Invoke-Adb -Arguments (Get-AdbArgs -Tail @('pull', $RemotePath, $LocalPath)) | Out-Null
}

function Remove-RemoteFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )

    $shellPath = ConvertTo-ShellLiteral -Value $RemotePath
    Invoke-Adb -Arguments (Get-AdbArgs -Tail @('shell', "rm -f $shellPath")) | Out-Null
}

function Write-Detail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $SummaryOnly) {
        Write-Host $Message
    }
}

$state = ((Invoke-Adb -Arguments (Get-AdbArgs -Tail @('get-state')) -AllowFailure) | Select-Object -First 1).Trim()
if ($state -ne 'device') {
    throw 'No authorized Android device is connected. Check USB debugging and run adb devices.'
}

$serialText = if ($Serial) { $Serial } else { ((Invoke-Adb -Arguments @('get-serialno')) | Select-Object -First 1).Trim() }
$model = Get-DeviceProperty -PropertyName 'ro.product.model'
if (-not $model) {
    $model = 'android-device'
}

$safeModel = ($model -replace '[^A-Za-z0-9._-]', '_').Trim('_')
if (-not $safeModel) {
    $safeModel = 'android-device'
}

$backupRoot = Join-Path $DestinationRoot $safeModel
if (-not (Test-Path -LiteralPath $backupRoot) -and -not $DryRun) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
}

$remoteFiles = @(Get-RemoteFiles -Directories $SourceDirs | Sort-Object -Unique)

if (-not $remoteFiles.Count) {
    Write-Host 'No matching media files found in the configured source directories.'
    return
}

$copiedCount = 0
$deletedCount = 0
$skippedCount = 0
$listedBytes = [long]0

Write-Host "Device: $model ($serialText)"
Write-Host "Destination: $backupRoot"
Write-Host "Media files found: $($remoteFiles.Count)"
if ($DryRun) {
    Write-Host 'Mode: dry run'
} elseif ($DeleteAfterCopy) {
    Write-Host 'Mode: copy then delete verified files from the phone'
} else {
    Write-Host 'Mode: copy only'
}

foreach ($remoteFile in $remoteFiles) {
    $destinationPath = Get-DestinationPath -RemotePath $remoteFile -BasePath $backupRoot
    $existing = Get-Item -LiteralPath $destinationPath -ErrorAction SilentlyContinue
    $remoteSize = Get-RemoteSize -RemotePath $remoteFile
    $listedBytes += $remoteSize

    if ($existing) {
        if ($existing.Length -eq $remoteSize) {
            $skippedCount++
            if ($DeleteAfterCopy -and -not $DryRun) {
                Remove-RemoteFile -RemotePath $remoteFile
                $deletedCount++
                Write-Detail "Deleted already-backed-up file: $remoteFile"
            } else {
                Write-Detail "Skipped existing match: $remoteFile"
            }
            continue
        }
    }

    if ($DryRun) {
        Write-Detail "Would copy: $remoteFile -> $destinationPath"
        if ($DeleteAfterCopy) {
            Write-Detail "Would delete after copy: $remoteFile"
        }
        continue
    }

    Copy-RemoteFile -RemotePath $remoteFile -LocalPath $destinationPath

    $localFile = Get-Item -LiteralPath $destinationPath -ErrorAction Stop
    if ($localFile.Length -ne $remoteSize) {
        throw "Size mismatch after copy for $remoteFile. Remote=$remoteSize Local=$($localFile.Length)"
    }

    $copiedCount++
    Write-Detail "Copied: $remoteFile"

    if ($DeleteAfterCopy) {
        Remove-RemoteFile -RemotePath $remoteFile
        $deletedCount++
        Write-Detail "Deleted from phone: $remoteFile"
    }
}

Write-Host ''
Write-Host 'Summary'
Write-Host "Listed files: $($remoteFiles.Count)"
Write-Host "Copied: $copiedCount"
Write-Host "Deleted: $deletedCount"
Write-Host "Skipped existing: $skippedCount"
Write-Host "Listed total size: $(Format-ByteSize -Bytes $listedBytes) ($listedBytes bytes)"
$scriptStopwatch.Stop()
Write-Host "Elapsed time: $($scriptStopwatch.Elapsed.ToString('hh\:mm\:ss'))"