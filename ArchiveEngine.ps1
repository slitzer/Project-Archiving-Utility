param(
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$true)][string]$ActiveRoot,
    [Parameter(Mandatory=$true)][string]$ArchiveRoot,
    [Parameter(Mandatory=$false)][string]$ClientMapPath = "",
    [Parameter(Mandatory=$true)][string]$OutDir,
    [switch]$DryRun
)

# =========================
# HELPERS
# =========================
function Ensure-Dir {
    param([string]$p)
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
function Get-FieldString {
    param($Row, [string] $FieldName)
    $v = $Row.$FieldName
    if ($null -eq $v) { return "" }
    return $v.ToString().Trim()
}
function Normalize-ClientName {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    $x = $s.ToLowerInvariant()
    $x = $x -replace '\b(ltd|limited|pty|pty\.|inc|inc\.|llc|plc|company|co)\b', ''
    $x = $x -replace '[^a-z0-9 ]', ' '
    $x = $x -replace '\s+', ' '
    return $x.Trim()
}
function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return [int64]0 }

    $sum = (Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum

    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}
function Get-DestinationFreeBytes {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSDrive -and $null -ne $item.PSDrive.Free) {
            return [int64]$item.PSDrive.Free
        }
    } catch {}

    if ($Path -match '^[A-Za-z]:') {
        try {
            $driveRoot = $Path.Substring(0,1) + ':'
            $driveInfo = New-Object System.IO.DriveInfo($driveRoot)
            return [int64]$driveInfo.AvailableFreeSpace
        } catch {}
    }

    return $null
}

# =========================
# OUTPUT SETUP
# =========================
Ensure-Dir $OutDir
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath      = Join-Path $OutDir "ArchiveMove-$stamp.log"
$wouldMoveCsv = Join-Path $OutDir "WouldMove-$stamp.csv"
$skippedCsv   = Join-Path $OutDir "Skipped-$stamp.csv"
$failedCsv    = Join-Path $OutDir "Failed-$stamp.csv"

"=== Run started: $(Get-Date) ===" | Out-File $logPath -Append
"DryRun: $DryRun" | Out-File $logPath -Append
"CsvPath: $CsvPath" | Out-File $logPath -Append
"ActiveRoot: $ActiveRoot" | Out-File $logPath -Append
"ArchiveRoot: $ArchiveRoot" | Out-File $logPath -Append
"ClientMapPath: $ClientMapPath" | Out-File $logPath -Append
"OutDir: $OutDir" | Out-File $logPath -Append

# =========================
# VALIDATION
# =========================
if (!(Test-Path $ActiveRoot))  { throw "ActiveRoot '$ActiveRoot' is not accessible in THIS session." }
if (!(Test-Path $ArchiveRoot)) { throw "ArchiveRoot '$ArchiveRoot' is not accessible in THIS session." }
if (!(Test-Path $CsvPath))     { throw "CSV not found: $CsvPath" }

$rows = @(Import-Csv $CsvPath)

# =========================
# LOAD CLIENT FOLDER MAPPING
# =========================
$clientMap = @{}
if ($ClientMapPath -and (Test-Path $ClientMapPath)) {
    @(Import-Csv $ClientMapPath) | ForEach-Object {
        if ($_.ClientName) {
            $key = $_.ClientName.Trim()
            $sourceFolder = ""
            $destinationFolder = ""

            # Backward compatibility: existing map files can still use FolderName.
            if ($_.PSObject.Properties.Name -contains "FolderName" -and $_.FolderName) {
                $sourceFolder = $_.FolderName.Trim()
                $destinationFolder = $_.FolderName.Trim()
            }
            if ($_.PSObject.Properties.Name -contains "SourceFolderName" -and $_.SourceFolderName) {
                $sourceFolder = $_.SourceFolderName.Trim()
            }
            if ($_.PSObject.Properties.Name -contains "DestinationFolderName" -and $_.DestinationFolderName) {
                $destinationFolder = $_.DestinationFolderName.Trim()
            }

            if ($sourceFolder -or $destinationFolder) {
                $clientMap[$key] = [pscustomobject]@{
                    SourceFolderName      = $sourceFolder
                    DestinationFolderName = $destinationFolder
                }
            }
        }
    }
    "Loaded client mappings: $($clientMap.Count)" | Out-File $logPath -Append
} else {
    "Client mapping not provided/found; best-match selection will be used." | Out-File $logPath -Append
}

# Cache active client folders (PS 5.1 safe)
$activeClientFolders = Get-ChildItem -Path $ActiveRoot -ErrorAction Stop | Where-Object { $_.PSIsContainer }

# Results
$wouldMove = @()
$skipped   = @()
$failed    = @()

$summary = [ordered]@{
    TotalRows              = 0
    WouldMoveCount         = 0
    MovedCount             = 0
    Skipped_DestExists     = 0
    Skipped_MissingFields  = 0
    Skipped_MissingClient  = 0
    Skipped_MissingJob     = 0
    Skipped_Ambiguous      = 0
    Failed_Robocopy        = 0
    SpaceCheck_Performed   = 0
    SpaceCheck_Insufficient = 0
}

foreach ($r in $rows) {
    $summary.TotalRows++

    $projectNumber = Get-FieldString $r "Project Number"
    $projectTitle  = Get-FieldString $r "Project Title"
    $clientName    = Get-FieldString $r "Client Name"

    if (-not $projectNumber -or -not $clientName) {
        $summary.Skipped_MissingFields++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = ""
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = ""
            SourcePath    = ""
            DestPath      = ""
            SkipReason    = "Missing required fields (Client Name / Project Number)"
        }
        continue
    }

    # Resolve source/destination client folder names: mapping first, else best-match
    $sourceClientFolderName = $null
    $destinationClientFolderName = $null

    if ($clientMap.ContainsKey($clientName)) {
        $mapped = $clientMap[$clientName]
        $sourceClientFolderName = $mapped.SourceFolderName
        $destinationClientFolderName = $mapped.DestinationFolderName

        if (-not $sourceClientFolderName -and $destinationClientFolderName) {
            $sourceClientFolderName = $destinationClientFolderName
        }
        if (-not $destinationClientFolderName -and $sourceClientFolderName) {
            $destinationClientFolderName = $sourceClientFolderName
        }
    } else {
        $target = Normalize-ClientName $clientName
        $tWords = $target.Split(' ') | Where-Object { $_ -ne "" }

        $candidates = @()
        foreach ($f in $activeClientFolders) {
            $cand = Normalize-ClientName $f.Name
            if (-not $cand) { continue }
            $cWords = $cand.Split(' ') | Where-Object { $_ -ne "" }
            $score = ($tWords | Where-Object { $cWords -contains $_ }).Count
            $candidates += [pscustomobject]@{ Name = $f.Name; Score = $score }
        }
        $candidates = $candidates | Sort-Object Score -Descending

        $best   = $candidates | Select-Object -First 1
        $second = $candidates | Select-Object -Skip 1 -First 1

        if ($null -eq $best -or $best.Score -lt 1) {
            $summary.Skipped_MissingClient++
            $skipped += [pscustomobject]@{
                ClientName    = $clientName
                ClientFolder  = ""
                ProjectNumber = $projectNumber
                ProjectTitle  = $projectTitle
                JobFolder     = ""
                SourcePath    = ""
                DestPath      = ""
                SkipReason    = "No matching client folder found (add to ClientFolderMap.csv)"
            }
            continue
        }

        if ($second -and ($second.Score -eq $best.Score)) {
            $summary.Skipped_Ambiguous++
            $skipped += [pscustomobject]@{
                ClientName    = $clientName
                ClientFolder  = ""
                ProjectNumber = $projectNumber
                ProjectTitle  = $projectTitle
                JobFolder     = ""
                SourcePath    = ""
                DestPath      = ""
                SkipReason    = "Ambiguous client folder match (tie) - add mapping"
            }
            continue
        }

        $sourceClientFolderName = $best.Name
        $destinationClientFolderName = $best.Name
    }

    if (-not $sourceClientFolderName -or -not $destinationClientFolderName) {
        $summary.Skipped_MissingClient++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = ""
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = ""
            SourcePath    = ""
            DestPath      = ""
            SkipReason    = "Client mapping is missing source/destination folder name"
        }
        continue
    }

    $activeClientPath  = Join-Path $ActiveRoot  $sourceClientFolderName
    $archiveClientPath = Join-Path $ArchiveRoot $destinationClientFolderName

    if (!(Test-Path $activeClientPath)) {
        $summary.Skipped_MissingClient++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = $sourceClientFolderName
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = ""
            SourcePath    = $activeClientPath
            DestPath      = $archiveClientPath
            SkipReason    = "Active client folder missing"
        }
        continue
    }

    # Find job folder under Active\Client\ that starts with the project number
    $jobCandidates = @(Get-ChildItem -Path $activeClientPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer -and $_.Name -match ("^\s*" + [regex]::Escape($projectNumber) + "\b") })

    if ($jobCandidates.Count -eq 0) {
        $summary.Skipped_MissingJob++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = $sourceClientFolderName
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = ""
            SourcePath    = $activeClientPath
            DestPath      = $archiveClientPath
            SkipReason    = "Job folder not found under client folder (number prefix missing)"
        }
        continue
    }

    if ($jobCandidates.Count -gt 1) {
        $summary.Skipped_Ambiguous++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = $sourceClientFolderName
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = ""
            SourcePath    = $activeClientPath
            DestPath      = $archiveClientPath
            SkipReason    = "Multiple job folders match number (ambiguous)"
        }
        continue
    }

    $jobFolder = $jobCandidates[0]
    $src = $jobFolder.FullName
    $dst = Join-Path $archiveClientPath $jobFolder.Name

    if (Test-Path $dst) {
        $summary.Skipped_DestExists++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = $sourceClientFolderName
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = $jobFolder.Name
            SourcePath    = $src
            DestPath      = $dst
            SkipReason    = "Destination already exists"
        }
        continue
    }

    $wouldMove += [pscustomobject]@{
        ClientName    = $clientName
        ClientFolder  = $sourceClientFolderName
        ProjectNumber = $projectNumber
        ProjectTitle  = $projectTitle
        JobFolder     = $jobFolder.Name
        SourcePath    = $src
        DestPath      = $dst
        SourceSizeBytes = 0
        Action        = $(if ($DryRun) { "WouldMove" } else { "Move" })
        WouldCreate   = $(if (!(Test-Path $archiveClientPath)) { "Create archive client folder" } else { "" })
    }
    $summary.WouldMoveCount++
}

# Dry-run based capacity check
$totalWouldMoveBytes = [int64]0
foreach ($m in $wouldMove) {
    $sizeBytes = Get-FolderSizeBytes -Path $m.SourcePath
    $m.SourceSizeBytes = $sizeBytes
    $totalWouldMoveBytes += $sizeBytes
}

$destinationFreeBytes = Get-DestinationFreeBytes -Path $ArchiveRoot
$insufficientSpace = $false
if ($null -ne $destinationFreeBytes) {
    $summary.SpaceCheck_Performed = 1
    if ($totalWouldMoveBytes -gt $destinationFreeBytes) {
        $summary.SpaceCheck_Insufficient = 1
        $insufficientSpace = $true
    }
}

"=== Capacity check ===" | Out-File $logPath -Append
"TotalWouldMoveBytes: $totalWouldMoveBytes" | Out-File $logPath -Append
"DestinationFreeBytes: $destinationFreeBytes" | Out-File $logPath -Append
"InsufficientSpace: $insufficientSpace" | Out-File $logPath -Append

if ($insufficientSpace -and -not $DryRun) {
    "ALERT|Insufficient destination space. Required=$totalWouldMoveBytes bytes, Free=$destinationFreeBytes bytes. Move aborted." | Out-File $logPath -Append
} elseif (-not $DryRun) {
    foreach ($m in $wouldMove) {
        $archiveClientPath = Split-Path -Parent $m.DestPath

        # Real run: create client folder if needed
        Ensure-Dir $archiveClientPath

        # Move via robocopy
        $args = @(
            "`"$($m.SourcePath)`"",
            "`"$($m.DestPath)`"",
            "/E",
            "/MOVE",
            "/R:2","/W:5",
            "/COPY:DAT","/DCOPY:DAT",
            "/XJ",
            "/NP"
        )

        $p = Start-Process -FilePath robocopy.exe -ArgumentList $args -Wait -PassThru
        $rc = $p.ExitCode
        if ($rc -ge 8) {
            $summary.Failed_Robocopy++
            $failed += [pscustomobject]@{
                ClientName    = $m.ClientName
                ClientFolder  = $m.ClientFolder
                ProjectNumber = $m.ProjectNumber
                ProjectTitle  = $m.ProjectTitle
                JobFolder     = $m.JobFolder
                SourcePath    = $m.SourcePath
                DestPath      = $m.DestPath
                ExitCode      = $rc
                FailReason    = "Robocopy failed (exit code >= 8)"
            }
            "FAILED|ProjectNumber=$($m.ProjectNumber)|Client=$($m.ClientName)|Source=$($m.SourcePath)|Dest=$($m.DestPath)|RobocopyExit=$rc" | Out-File $logPath -Append
        } else {
            $summary.MovedCount++
        }
    }
}

# Export reports
$wouldMove | Export-Csv -NoTypeInformation -Encoding UTF8 $wouldMoveCsv
$skipped   | Export-Csv -NoTypeInformation -Encoding UTF8 $skippedCsv
$failed    | Export-Csv -NoTypeInformation -Encoding UTF8 $failedCsv

"=== Summary ===" | Out-File $logPath -Append
$summary.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" | Out-File $logPath -Append }
"WouldMove report: $wouldMoveCsv" | Out-File $logPath -Append
"Skipped report: $skippedCsv" | Out-File $logPath -Append
"Failed report: $failedCsv" | Out-File $logPath -Append
"=== Run ended: $(Get-Date) ===" | Out-File $logPath -Append

# One-line result for the UI to parse
Write-Host ("RESULT|Log={0}|WouldMove={1}|Skipped={2}|FailedCsv={3}|Total={4}|WouldMoveCount={5}|Moved={6}|SkippedAmb={7}|SkippedMissClient={8}|SkippedMissJob={9}|SkippedDest={10}|SkippedMissingFields={11}|Failed={12}|SpaceCheckPerformed={13}|SpaceCheckInsufficient={14}|TotalWouldMoveBytes={15}|DestinationFreeBytes={16}" -f `
    $logPath, $wouldMoveCsv, $skippedCsv, $failedCsv, `
    $summary.TotalRows, $summary.WouldMoveCount, $summary.MovedCount, `
    $summary.Skipped_Ambiguous, $summary.Skipped_MissingClient, $summary.Skipped_MissingJob, $summary.Skipped_DestExists, $summary.Skipped_MissingFields, $summary.Failed_Robocopy, `
    $summary.SpaceCheck_Performed, $summary.SpaceCheck_Insufficient, $totalWouldMoveBytes, $destinationFreeBytes
)
