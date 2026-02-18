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
        if ($_.ClientName -and $_.FolderName) {
            $clientMap[$_.ClientName.Trim()] = $_.FolderName.Trim()
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

    # Resolve client folder name: mapping first, else best-match
    $clientFolderName = $null

    if ($clientMap.ContainsKey($clientName)) {
        $clientFolderName = $clientMap[$clientName]
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

        $clientFolderName = $best.Name
    }

    $activeClientPath  = Join-Path $ActiveRoot  $clientFolderName
    $archiveClientPath = Join-Path $ArchiveRoot $clientFolderName

    if (!(Test-Path $activeClientPath)) {
        $summary.Skipped_MissingClient++
        $skipped += [pscustomobject]@{
            ClientName    = $clientName
            ClientFolder  = $clientFolderName
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
            ClientFolder  = $clientFolderName
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
            ClientFolder  = $clientFolderName
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
            ClientFolder  = $clientFolderName
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
        ClientFolder  = $clientFolderName
        ProjectNumber = $projectNumber
        ProjectTitle  = $projectTitle
        JobFolder     = $jobFolder.Name
        SourcePath    = $src
        DestPath      = $dst
        Action        = $(if ($DryRun) { "WouldMove" } else { "Move" })
        WouldCreate   = $(if (!(Test-Path $archiveClientPath)) { "Create archive client folder" } else { "" })
    }
    $summary.WouldMoveCount++

    if ($DryRun) { continue }

    # Real run: create client folder if needed
    Ensure-Dir $archiveClientPath

    # Move via robocopy
    $args = @(
        "`"$src`"",
        "`"$dst`"",
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
            ClientName    = $clientName
            ClientFolder  = $clientFolderName
            ProjectNumber = $projectNumber
            ProjectTitle  = $projectTitle
            JobFolder     = $jobFolder.Name
            SourcePath    = $src
            DestPath      = $dst
            ExitCode      = $rc
            FailReason    = "Robocopy failed (exit code >= 8)"
        }
        "FAILED|ProjectNumber=$projectNumber|Client=$clientName|Source=$src|Dest=$dst|RobocopyExit=$rc" | Out-File $logPath -Append
    } else {
        $summary.MovedCount++
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
Write-Host ("RESULT|Log={0}|WouldMove={1}|Skipped={2}|FailedCsv={3}|Total={4}|WouldMoveCount={5}|Moved={6}|SkippedAmb={7}|SkippedMissClient={8}|SkippedMissJob={9}|SkippedDest={10}|SkippedMissingFields={11}|Failed={12}" -f `
    $logPath, $wouldMoveCsv, $skippedCsv, $failedCsv, `
    $summary.TotalRows, $summary.WouldMoveCount, $summary.MovedCount, `
    $summary.Skipped_Ambiguous, $summary.Skipped_MissingClient, $summary.Skipped_MissingJob, $summary.Skipped_DestExists, $summary.Skipped_MissingFields, $summary.Failed_Robocopy
)
