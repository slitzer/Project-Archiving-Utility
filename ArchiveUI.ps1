#requires -version 5.1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# -------------------------
# CONFIG DEFAULTS
# -------------------------
$script:EnginePath = Join-Path $PSScriptRoot "ArchiveEngine.ps1"
if (!(Test-Path $script:EnginePath)) {
    $script:EnginePath = "C:\TRANSFERSCRIPT\ArchiveEngine.ps1"
}

$script:LastWouldMovePath = $null
$script:LastSkippedPath   = $null
$script:LastLogPath       = $null

# -------------------------
# THEME
# -------------------------
$script:Themes = @{
    Dark = @{
        WindowBg   = "#0F1115"
        Text       = "#E6E6E6"
        Muted      = "#A6ABB5"
        PanelBg    = "#131720"
        CardBg     = "#171A21"
        Border     = "#2E3550"
        InputBg    = "#0E1016"
        OutputBg   = "#0B0D12"
        Accent     = "#4CC2FF"
        Warn       = "#FFB020"
        Danger     = "#FF5C7A"
        Ok         = "#37D67A"
    }
    Light = @{
        WindowBg   = "#F4F6FA"
        Text       = "#1E2430"
        Muted      = "#5B6578"
        PanelBg    = "#FFFFFF"
        CardBg     = "#FFFFFF"
        Border     = "#CBD3E1"
        InputBg    = "#FFFFFF"
        OutputBg   = "#FFFFFF"
        Accent     = "#0B74FF"
        Warn       = "#B25A00"
        Danger     = "#B00020"
        Ok         = "#0A7A35"
    }
}
$script:CurrentTheme = "Light"

function New-Brush([string]$hex) {
    $bc = New-Object System.Windows.Media.BrushConverter
    $b = $bc.ConvertFromString($hex)
    if ($b -is [System.Windows.Media.SolidColorBrush]) { $b.Freeze() }
    return $b
}

function Apply-Theme {
    param([System.Windows.Window]$Window, [string]$ThemeName)

    if (-not $script:Themes.ContainsKey($ThemeName)) { return }
    $t = $script:Themes[$ThemeName]
    $script:CurrentTheme = $ThemeName

    # Update Window
    $Window.Background = New-Brush $t.WindowBg
    $Window.Foreground = New-Brush $t.Text

    # Update resources used by XAML
    $Window.Resources["BrushWindowBg"] = New-Brush $t.WindowBg
    $Window.Resources["BrushText"]     = New-Brush $t.Text
    $Window.Resources["BrushMuted"]    = New-Brush $t.Muted
    $Window.Resources["BrushPanelBg"]  = New-Brush $t.PanelBg
    $Window.Resources["BrushCardBg"]   = New-Brush $t.CardBg
    $Window.Resources["BrushBorder"]   = New-Brush $t.Border
    $Window.Resources["BrushInputBg"]  = New-Brush $t.InputBg
    $Window.Resources["BrushOutputBg"] = New-Brush $t.OutputBg
    $Window.Resources["BrushAccent"]   = New-Brush $t.Accent
    $Window.Resources["BrushWarn"]     = New-Brush $t.Warn
    $Window.Resources["BrushDanger"]   = New-Brush $t.Danger
    $Window.Resources["BrushOk"]       = New-Brush $t.Ok
}

# -------------------------
# UI HELPERS
# -------------------------
function Select-Folder {
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.ShowNewFolderButton = $true
    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $fb.SelectedPath }
    return $null
}
function Select-File([string]$filter) {
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = $filter
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $ofd.FileName }
    return $null
}

function Append-Output([string]$s) {
    $txtOutput.AppendText($s + "`r`n")
    $txtOutput.ScrollToEnd()
}

function Safe-Count($obj) { return @($obj).Count }
function Format-Bytes([Nullable[Int64]]$bytes) {
    if ($null -eq $bytes) { return "Unknown" }
    $units = @("B", "KB", "MB", "GB", "TB")
    $value = [double]$bytes
    $idx = 0
    while ($value -ge 1024 -and $idx -lt ($units.Count - 1)) {
        $value = $value / 1024
        $idx++
    }
    return ("{0:N2} {1} ({2} bytes)" -f $value, $units[$idx], $bytes)
}

function Parse-ResultLine([string]$line) {
    # RESULT|Log=...|WouldMove=...|Skipped=...|Total=...|WouldMoveCount=...|Moved=...|SkippedAmb=...|...|Failed=...
    $d = @{}
    if (-not $line) { return $d }
    if ($line -notmatch "^RESULT\|") { return $d }

    $parts = $line.Split('|')
    foreach ($p in $parts) {
        if ($p -eq "RESULT") { continue }
        $kv = $p.Split('=',2)
        if ($kv.Count -eq 2) { $d[$kv[0]] = $kv[1] }
    }
    return $d
}

function Update-CardsFromResult($res) {
    # WouldMove comes from engine summary (best truth)
    $cardWouldMove.Text = ("" + $res["WouldMoveCount"])

    # Skipped = rows in skipped csv if present; else compute from Total - WouldMove? (but destination exists etc are in skipped)
    $skippedCount = 0
    $ambCount = 0
    $failedCount = 0

    if ($res.ContainsKey("Failed")) { $failedCount = [int]$res["Failed"] }
    if ($res.ContainsKey("SkippedAmb")) { $ambCount = [int]$res["SkippedAmb"] }

    if ($script:LastSkippedPath -and (Test-Path $script:LastSkippedPath)) {
        $rows = @(Import-Csv $script:LastSkippedPath)
        $skippedCount = $rows.Count
        # Ambiguous in skipped file can be bigger than summary field, but we trust engine summary for "ambiguous"
        # Still, if summary is missing, fallback:
        if (-not $res.ContainsKey("SkippedAmb")) {
            $ambCount = @($rows | Where-Object { $_.SkipReason -match "Ambiguous" }).Count
        }
    } else {
        # fallback
        if ($res.ContainsKey("Total")) {
            $total = [int]$res["Total"]
            $would = [int]$res["WouldMoveCount"]
            $skippedCount = [Math]::Max(0, ($total - $would))
        }
    }

    $cardSkipped.Text   = ("" + $skippedCount)
    $cardAmbiguous.Text = ("" + $ambCount)
    $cardFailed.Text    = ("" + $failedCount)
}

function Run-Engine([bool]$Dry) {
    $txtOutput.Clear()

    $from = $txtFrom.Text.Trim()
    $to   = $txtTo.Text.Trim()
    $csv  = $txtCsv.Text.Trim()
    $map  = $txtMap.Text.Trim()
    $logs = $txtLogs.Text.Trim()

    Append-Output ("=== Starting run: " + (Get-Date) )
    Append-Output ("Engine: " + $script:EnginePath)
    Append-Output ("From:   " + $from)
    Append-Output ("To:     " + $to)
    Append-Output ("CSV:    " + $csv)
    Append-Output ("Map:    " + $map)
    Append-Output ("Logs:   " + $logs)
    Append-Output ("DryRun: " + $Dry)

    if (!(Test-Path $script:EnginePath)) { Append-Output "ERROR: Engine not found."; return }
    if (!(Test-Path $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }

    # Build args
    $argList = @(
        "-NoProfile","-ExecutionPolicy","Bypass",
        "-File", $script:EnginePath,
        "-CsvPath", $csv,
        "-ActiveRoot", $from,
        "-ArchiveRoot", $to,
        "-OutDir", $logs
    )
    if ($map) { $argList += @("-ClientMapPath", $map) }
    if ($Dry) { $argList += "-DryRun" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = ($argList | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    $null = $p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($stdout) { Append-Output $stdout.TrimEnd() }
    if ($stderr) {
        Append-Output "ERROR:"
        Append-Output $stderr.TrimEnd()
    }
    Append-Output ("ExitCode: " + $p.ExitCode)

    # Parse RESULT line (last one usually)
    $resultLine = ($stdout -split "`r?`n" | Where-Object { $_ -match "^RESULT\|" } | Select-Object -Last 1)
    $res = Parse-ResultLine $resultLine

    if ($res.ContainsKey("WouldMove")) { $script:LastWouldMovePath = $res["WouldMove"] }
    if ($res.ContainsKey("Skipped"))   { $script:LastSkippedPath   = $res["Skipped"] }
    if ($res.ContainsKey("Log"))       { $script:LastLogPath       = $res["Log"] }

    if ($res.Count -gt 0) {
        Update-CardsFromResult $res
        Refresh-LogsList

        if ($res.ContainsKey("SpaceCheckPerformed") -and $res["SpaceCheckPerformed"] -eq "1") {
            $needBytes = [int64]$res["TotalWouldMoveBytes"]
            $freeBytes = [int64]$res["DestinationFreeBytes"]
            Append-Output ("Capacity check: required=" + (Format-Bytes $needBytes) + ", free=" + (Format-Bytes $freeBytes))

            if ($res.ContainsKey("SpaceCheckInsufficient") -and $res["SpaceCheckInsufficient"] -eq "1") {
                $msg = "Insufficient destination space detected.`n`nRequired: " + (Format-Bytes $needBytes) + "`nAvailable: " + (Format-Bytes $freeBytes)
                Append-Output ("ALERT: " + $msg.Replace("`n", " "))
                [System.Windows.MessageBox]::Show($msg, "Storage Alert", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        } else {
            Append-Output "Capacity check: destination free space could not be determined."
        }
    }
}

function Refresh-LogsList {
    $lstLogs.Items.Clear()
    $dir = $txtLogs.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    if (!(Test-Path $dir)) { return }

    $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 200

    foreach ($f in $files) { $null = $lstLogs.Items.Add($f.FullName) }
}

function Load-LatestToState {
    $dir = $txtLogs.Text.Trim()
    if (!(Test-Path $dir)) { Append-Output "Logs directory not found."; return }

    $wm = Get-ChildItem -Path $dir -Filter "WouldMove-*.csv" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $sk = Get-ChildItem -Path $dir -Filter "Skipped-*.csv" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $lg = Get-ChildItem -Path $dir -Filter "ArchiveMove-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    $script:LastWouldMovePath = $(if ($wm) { $wm.FullName } else { $null })
    $script:LastSkippedPath   = $(if ($sk) { $sk.FullName } else { $null })
    $script:LastLogPath       = $(if ($lg) { $lg.FullName } else { $null })

    Append-Output "Loaded latest:"
    Append-Output ("  WouldMove: " + $(if ($script:LastWouldMovePath) { $script:LastWouldMovePath } else { "<none>" }))
    Append-Output ("  Skipped:   " + $(if ($script:LastSkippedPath)   { $script:LastSkippedPath }   else { "<none>" }))
    Append-Output ("  Log:       " + $(if ($script:LastLogPath)       { $script:LastLogPath }       else { "<none>" }))
}

function Load-WouldMovePreview([string]$path) {
    if (!(Test-Path $path)) { Append-Output "WouldMove CSV not found."; return }
    $rows = @(Import-Csv $path)
    $gridMain.ItemsSource = $rows
    $gridSkips.ItemsSource = @()
}

function Load-SkippedPreview([string]$path) {
    if (!(Test-Path $path)) { Append-Output "Skipped CSV not found."; return }
    $rows = @(Import-Csv $path)

    $gridMain.ItemsSource = $rows

    $byReason = @()
    if ($rows.Count -gt 0) {
        $byReason = $rows |
            Group-Object -Property SkipReason |
            Sort-Object -Property Count -Descending |
            ForEach-Object {
                [pscustomobject]@{
                    SkipReason = $_.Name
                    Count      = $_.Count
                }
            }
        $byReason = @($byReason)
    }
    $gridSkips.ItemsSource = $byReason
}

# -------------------------
# Mapping Suggestions
# -------------------------
function Normalize-ClientNameLocal {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    $x = $s.ToLowerInvariant()
    $x = $x -replace '\b(ltd|limited|pty|pty\.|inc|inc\.|llc|plc|company|co)\b', ''
    $x = $x -replace '[^a-z0-9 ]', ' '
    $x = $x -replace '\s+', ' '
    return $x.Trim()
}

function Get-BestFolderSuggestion {
    param(
        [string]$ClientName,
        $Folders
    )

    if (-not $Folders -or @($Folders).Count -eq 0) {
        return [pscustomobject]@{ Name = ""; Score = 0; Tie = $false }
    }

    $target = Normalize-ClientNameLocal $ClientName
    $tWords = $target.Split(' ') | Where-Object { $_ -ne "" }

    $cand = @()
    foreach ($f in $Folders) {
        $norm = Normalize-ClientNameLocal $f.Name
        if (-not $norm) { continue }
        $cWords = $norm.Split(' ') | Where-Object { $_ -ne "" }
        $score = ($tWords | Where-Object { $cWords -contains $_ }).Count
        $cand += [pscustomobject]@{ Name = $f.Name; Score = $score }
    }

    $cand = $cand | Sort-Object Score -Descending
    $best = $cand | Select-Object -First 1
    $second = $cand | Select-Object -Skip 1 -First 1

    $bestName = $(if ($best -and $best.Score -gt 0) { $best.Name } else { "" })
    $bestScore = $(if ($best) { [int]$best.Score } else { 0 })
    $tie = $false
    if ($second -and $best -and ($second.Score -eq $best.Score) -and $bestScore -gt 0) { $tie = $true }

    return [pscustomobject]@{ Name = $bestName; Score = $bestScore; Tie = $tie }
}

function Suggest-MappingsFromSkipped {
    $gridMappings.ItemsSource = @()
    $txtMapStatus.Text = ""

    $skPath = $script:LastSkippedPath
    if (-not $skPath -or !(Test-Path $skPath)) {
        $txtMapStatus.Text = "No skipped file loaded. Run a dry run first or click Load Latest."
        return
    }

    $from = $txtFrom.Text.Trim()
    if (!(Test-Path $from)) {
        $txtMapStatus.Text = "Move From root is not accessible (need active drive mounted)."
        return
    }

    $to = $txtTo.Text.Trim()
    if (!(Test-Path $to)) {
        $txtMapStatus.Text = "Move To root is not accessible (need archive drive mounted)."
        return
    }

    $activeFolders = @(Get-ChildItem -Path $from -Directory -ErrorAction SilentlyContinue)
    if ($activeFolders.Count -eq 0) {
        $txtMapStatus.Text = "No client folders found under Move From root."
        return
    }

    $archiveFolders = @(Get-ChildItem -Path $to -Directory -ErrorAction SilentlyContinue)

    $sk = @(Import-Csv $skPath)
    $needs = @($sk | Where-Object {
        $_.SkipReason -match "No matching client folder" -or $_.SkipReason -match "Ambiguous client folder match"
    })

    $uniqClients = @($needs | Select-Object -ExpandProperty ClientName -Unique)

    $out = @()
    foreach ($cn in $uniqClients) {
        if ([string]::IsNullOrWhiteSpace($cn)) { continue }

        $src = Get-BestFolderSuggestion -ClientName $cn -Folders $activeFolders
        $dst = Get-BestFolderSuggestion -ClientName $cn -Folders $archiveFolders

        $out += [pscustomobject]@{
            Use                      = $(if ($src.Name -or $dst.Name) { $true } else { $false })
            ClientName               = $cn
            SourceFolderName         = $src.Name
            DestinationFolderName    = $(if ($dst.Name) { $dst.Name } else { $src.Name })
            SuggestedSourceFolder    = $src.Name
            SuggestedDestinationFolder = $(if ($dst.Name) { $dst.Name } else { $src.Name })
            SourceScore              = $src.Score
            DestinationScore         = $dst.Score
            SourceTie                = $src.Tie
            DestinationTie           = $dst.Tie
        }
    }

    $gridMappings.ItemsSource = @($out)
    $txtMapStatus.Text = ("Loaded {0} mapping suggestions from Skipped." -f $out.Count)
}

function Append-MappingsToMap {
    $mapPath = $txtMap.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($mapPath)) {
        $txtMapStatus.Text = "Client map path is blank."
        return
    }

    $items = @($gridMappings.ItemsSource)
    if ($items.Count -eq 0) { $txtMapStatus.Text = "No mapping rows loaded."; return }

    $selected = @($items | Where-Object {
        $_.Use -eq $true -and
        -not [string]::IsNullOrWhiteSpace($_.SourceFolderName) -and
        -not [string]::IsNullOrWhiteSpace($_.DestinationFolderName)
    })
    if ($selected.Count -eq 0) {
        $txtMapStatus.Text = "Nothing selected (tick Use and set both SourceFolderName and DestinationFolderName)."
        return
    }

    $overwrite = $chkOverwrite.IsChecked -eq $true

    $dict = @{}
    if (Test-Path $mapPath) {
        $existing = @(Import-Csv $mapPath)
        foreach ($e in $existing) {
            if (-not $e.ClientName) { continue }
            $key = $e.ClientName.Trim()

            $sourceFolder = ""
            $destinationFolder = ""
            if ($e.PSObject.Properties.Name -contains "FolderName" -and $e.FolderName) {
                $sourceFolder = $e.FolderName.Trim()
                $destinationFolder = $e.FolderName.Trim()
            }
            if ($e.PSObject.Properties.Name -contains "SourceFolderName" -and $e.SourceFolderName) {
                $sourceFolder = $e.SourceFolderName.Trim()
            }
            if ($e.PSObject.Properties.Name -contains "DestinationFolderName" -and $e.DestinationFolderName) {
                $destinationFolder = $e.DestinationFolderName.Trim()
            }

            if ($sourceFolder -or $destinationFolder) {
                if (-not $sourceFolder) { $sourceFolder = $destinationFolder }
                if (-not $destinationFolder) { $destinationFolder = $sourceFolder }
                $dict[$key] = [pscustomobject]@{
                    SourceFolderName = $sourceFolder
                    DestinationFolderName = $destinationFolder
                }
            }
        }
    }

    foreach ($s in $selected) {
        $cn = $s.ClientName.Trim()
        $src = $s.SourceFolderName.Trim()
        $dst = $s.DestinationFolderName.Trim()

        if ($dict.ContainsKey($cn)) {
            if ($overwrite) {
                $dict[$cn] = [pscustomobject]@{ SourceFolderName = $src; DestinationFolderName = $dst }
            }
        } else {
            $dict[$cn] = [pscustomobject]@{ SourceFolderName = $src; DestinationFolderName = $dst }
        }
    }

    $outRows = @()
    foreach ($k in ($dict.Keys | Sort-Object)) {
        $v = $dict[$k]
        $outRows += [pscustomobject]@{
            ClientName = $k
            SourceFolderName = $v.SourceFolderName
            DestinationFolderName = $v.DestinationFolderName
        }
    }

    $dir = Split-Path -Parent $mapPath
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $outRows | Export-Csv -NoTypeInformation -Encoding UTF8 $mapPath
    $txtMapStatus.Text = ("Wrote {0} mappings to {1}" -f $outRows.Count, $mapPath)
}

# -------------------------
# XAML
# -------------------------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Project Archiver" Height="860" Width="1220" WindowStartupLocation="CenterScreen"
        Background="{DynamicResource BrushWindowBg}" Foreground="{DynamicResource BrushText}">
  <Window.Resources>
    <SolidColorBrush x:Key="BrushWindowBg" Color="#0F1115"/>
    <SolidColorBrush x:Key="BrushText" Color="#E6E6E6"/>
    <SolidColorBrush x:Key="BrushMuted" Color="#A6ABB5"/>
    <SolidColorBrush x:Key="BrushPanelBg" Color="#131720"/>
    <SolidColorBrush x:Key="BrushCardBg" Color="#171A21"/>
    <SolidColorBrush x:Key="BrushBorder" Color="#2E3550"/>
    <SolidColorBrush x:Key="BrushInputBg" Color="#0E1016"/>
    <SolidColorBrush x:Key="BrushOutputBg" Color="#0B0D12"/>
    <SolidColorBrush x:Key="BrushAccent" Color="#4CC2FF"/>
    <SolidColorBrush x:Key="BrushWarn" Color="#FFB020"/>
    <SolidColorBrush x:Key="BrushDanger" Color="#FF5C7A"/>
    <SolidColorBrush x:Key="BrushOk" Color="#37D67A"/>

    <Style TargetType="Button">
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,10,8"/>
      <Setter Property="Background" Value="{DynamicResource BrushPanelBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource BrushText}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="0,0,10,8"/>
      <Setter Property="Background" Value="{DynamicResource BrushInputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource BrushText}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="{DynamicResource BrushInputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource BrushText}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BrushBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="RowBackground" Value="{DynamicResource BrushInputBg}"/>
      <Setter Property="AlternatingRowBackground" Value="{DynamicResource BrushPanelBg}"/>
      <Setter Property="HeadersVisibility" Value="All"/>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,12">
      <StackPanel Orientation="Horizontal">
        <TextBlock FontSize="22" FontWeight="Bold" Text="Project Archiving Utility"/>
        <TextBlock Margin="12,6,0,0" Foreground="{DynamicResource BrushMuted}" Text="Minimal deps, Winutil-ish"/>
      </StackPanel>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Foreground="{DynamicResource BrushMuted}" Margin="0,0,8,0" Text="Theme:"/>
        <ToggleButton Name="tglTheme" Width="84" Height="26" Content="Dark" />
      </StackPanel>
    </DockPanel>

    <TabControl Grid.Row="1" Name="tabs" Background="{DynamicResource BrushPanelBg}">
      <TabItem Header=" Run ">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <UniformGrid Grid.Row="0" Columns="4" Margin="0,0,0,12">
            <Border Background="{DynamicResource BrushCardBg}" CornerRadius="14" Margin="0,0,12,0" Padding="14">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Text="Would Move" Foreground="{DynamicResource BrushAccent}"/>
                <TextBlock Name="cardWouldMove" FontSize="28" FontWeight="Bold" Text="0" Margin="0,6,0,0"/>
                <TextBlock Foreground="{DynamicResource BrushMuted}" Text="Matches ready to transfer"/>
              </StackPanel>
            </Border>

            <Border Background="{DynamicResource BrushCardBg}" CornerRadius="14" Margin="0,0,12,0" Padding="14">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Text="Skipped" Foreground="{DynamicResource BrushWarn}"/>
                <TextBlock Name="cardSkipped" FontSize="28" FontWeight="Bold" Text="0" Margin="0,6,0,0"/>
                <TextBlock Foreground="{DynamicResource BrushMuted}" Text="Needs attention/manual checks"/>
              </StackPanel>
            </Border>

            <Border Background="{DynamicResource BrushCardBg}" CornerRadius="14" Margin="0,0,12,0" Padding="14">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Text="Ambiguous" Foreground="{DynamicResource BrushWarn}"/>
                <TextBlock Name="cardAmbiguous" FontSize="28" FontWeight="Bold" Text="0" Margin="0,6,0,0"/>
                <TextBlock Foreground="{DynamicResource BrushMuted}" Text="Fixable via mappings"/>
              </StackPanel>
            </Border>

            <Border Background="{DynamicResource BrushCardBg}" CornerRadius="14" Padding="14">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Text="Failed" Foreground="{DynamicResource BrushDanger}"/>
                <TextBlock Name="cardFailed" FontSize="28" FontWeight="Bold" Text="0" Margin="0,6,0,0"/>
                <TextBlock Foreground="{DynamicResource BrushMuted}" Text="Robocopy failures (exitcode >= 8)"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Grid.Column="0" Margin="0,0,10,8" VerticalAlignment="Center" Text="Move From Root:"/>
            <TextBox  Name="txtFrom" Grid.Row="0" Grid.Column="1" Text="P:\"/>
            <Button   Name="btnFrom" Grid.Row="0" Grid.Column="2" Content="Browse"/>

            <TextBlock Grid.Row="1" Grid.Column="0" Margin="0,0,10,8" VerticalAlignment="Center" Text="Move To Root:"/>
            <TextBox  Name="txtTo" Grid.Row="1" Grid.Column="1" Text="A:\"/>
            <Button   Name="btnTo" Grid.Row="1" Grid.Column="2" Content="Browse"/>

            <TextBlock Grid.Row="2" Grid.Column="0" Margin="0,0,10,8" VerticalAlignment="Center" Text="Projects CSV:"/>
            <TextBox  Name="txtCsv" Grid.Row="2" Grid.Column="1" Text="C:\TRANSFERSCRIPT\ProjectsToArchive.csv"/>
            <Button   Name="btnCsv" Grid.Row="2" Grid.Column="2" Content="Browse"/>

            <TextBlock Grid.Row="3" Grid.Column="0" Margin="0,0,10,8" VerticalAlignment="Center" Text="Client Map CSV:"/>
            <TextBox  Name="txtMap" Grid.Row="3" Grid.Column="1" Text="C:\TRANSFERSCRIPT\ClientFolderMap.csv"/>
            <Button   Name="btnMap" Grid.Row="3" Grid.Column="2" Content="Browse"/>

            <TextBlock Grid.Row="4" Grid.Column="0" Margin="0,0,10,8" VerticalAlignment="Center" Text="Logs Folder:"/>
            <TextBox  Name="txtLogs" Grid.Row="4" Grid.Column="1" Text="C:\TRANSFERSCRIPT\Logs"/>
            <Button   Name="btnLogs" Grid.Row="4" Grid.Column="2" Content="Browse"/>

            <CheckBox Name="chkDry" Grid.Row="5" Grid.Column="1" Content="Dry run (no changes)" IsChecked="True" Margin="0,2,10,0"/>

            <StackPanel Grid.Row="5" Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
              <Button Name="btnDryRun" Content="Dry Run"/>
              <Button Name="btnRun" Content="Run Move" Margin="0,0,0,8"/>
              <Button Name="btnOpenLogs" Content="Open Logs Folder" Margin="0,0,0,8"/>
            </StackPanel>
          </Grid>

          <TextBox Name="txtOutput" Grid.Row="2"
                   FontFamily="Consolas" FontSize="12"
                   Background="{DynamicResource BrushOutputBg}"
                   BorderBrush="{DynamicResource BrushBorder}"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   IsReadOnly="True" TextWrapping="NoWrap"/>
        </Grid>
      </TabItem>

      <TabItem Header=" Preview ">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <DockPanel Grid.Row="0" Grid.ColumnSpan="2" Margin="0,0,0,10">
            <TextBlock FontWeight="Bold" Text="WouldMove / Skipped Preview" />
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button Name="btnPreviewWouldMove" Content="WouldMove"/>
              <Button Name="btnPreviewSkipped" Content="Skipped"/>
              <Button Name="btnLoadLast" Content="Load Latest Results" Margin="0,0,0,8"/>
            </StackPanel>
          </DockPanel>

          <DataGrid Name="gridMain" Grid.Row="1" Grid.Column="0" AutoGenerateColumns="True" IsReadOnly="True"/>

          <StackPanel Grid.Row="1" Grid.Column="1" Margin="12,0,0,0">
            <TextBlock FontWeight="Bold" Text="Skipped counts by reason" Margin="0,0,0,6"/>
            <DataGrid Name="gridSkips" AutoGenerateColumns="True" IsReadOnly="True" Height="260"/>
            <Separator Margin="0,12,0,12"/>
            <TextBlock FontWeight="Bold" Text="Quick actions" Margin="0,0,0,6"/>
            <Button Name="btnGenSuggestions" Content="Generate mapping suggestions from last Skipped"/>
            <Button Name="btnOpenSuggestions" Content="Open ClientFolderMap.csv" Margin="0,0,0,8"/>
          </StackPanel>
        </Grid>
      </TabItem>

      <TabItem Header=" Mappings ">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <DockPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock FontWeight="Bold" Text="Fix mappings (edit SourceFolderName + DestinationFolderName, then append to ClientFolderMap.csv)"/>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <CheckBox Name="chkOverwrite" Content="Overwrite existing" Margin="0,2,14,0"/>
              <Button Name="btnAppendMappings" Content="Append selected to map"/>
              <Button Name="btnReloadMap" Content="Reload log list" Margin="0,0,0,8"/>
            </StackPanel>
          </DockPanel>

          <DataGrid Name="gridMappings" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="False">
            <DataGrid.Columns>
              <DataGridCheckBoxColumn Header="Use" Binding="{Binding Use}" Width="60"/>
              <DataGridTextColumn Header="ClientName" Binding="{Binding ClientName}" IsReadOnly="True" Width="*"/>
              <DataGridTextColumn Header="SourceFolderName (edit)" Binding="{Binding SourceFolderName}" Width="*"/>
              <DataGridTextColumn Header="DestinationFolderName (edit)" Binding="{Binding DestinationFolderName}" Width="*"/>
              <DataGridTextColumn Header="Suggested Source" Binding="{Binding SuggestedSourceFolder}" IsReadOnly="True" Width="*"/>
              <DataGridTextColumn Header="Suggested Destination" Binding="{Binding SuggestedDestinationFolder}" IsReadOnly="True" Width="*"/>
              <DataGridTextColumn Header="Src Score" Binding="{Binding SourceScore}" IsReadOnly="True" Width="80"/>
              <DataGridTextColumn Header="Dst Score" Binding="{Binding DestinationScore}" IsReadOnly="True" Width="80"/>
              <DataGridCheckBoxColumn Header="Src Tie" Binding="{Binding SourceTie}" IsReadOnly="True" Width="70"/>
              <DataGridCheckBoxColumn Header="Dst Tie" Binding="{Binding DestinationTie}" IsReadOnly="True" Width="70"/>
            </DataGrid.Columns>
          </DataGrid>

          <TextBlock Name="txtMapStatus" Grid.Row="2" Foreground="{DynamicResource BrushMuted}" Margin="0,10,0,0" TextWrapping="Wrap"/>
        </Grid>
      </TabItem>

      <TabItem Header=" Logs ">
        <Grid Margin="10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <ListBox Name="lstLogs" Grid.Column="0" Background="{DynamicResource BrushOutputBg}" BorderBrush="{DynamicResource BrushBorder}" BorderThickness="1" />
          <StackPanel Grid.Column="1" Margin="12,0,0,0">
            <Button Name="btnRefreshLogs" Content="Refresh"/>
            <Button Name="btnOpenSelected" Content="Open Selected"/>
            <Button Name="btnOpenFolder2" Content="Open Logs Folder" Margin="0,0,0,8"/>
          </StackPanel>
        </Grid>
      </TabItem>
    </TabControl>

    <TextBlock Grid.Row="2" Foreground="{DynamicResource BrushMuted}" Margin="0,12,0,0"
               Text="Tip: Do a dry run first. Real moves should be scheduled after-hours to reduce network impact."/>
  </Grid>
</Window>
"@

# Load XAML
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Bind controls
$txtFrom = $window.FindName("txtFrom")
$txtTo   = $window.FindName("txtTo")
$txtCsv  = $window.FindName("txtCsv")
$txtMap  = $window.FindName("txtMap")
$txtLogs = $window.FindName("txtLogs")
$chkDry  = $window.FindName("chkDry")
$txtOutput = $window.FindName("txtOutput")

$cardWouldMove = $window.FindName("cardWouldMove")
$cardSkipped   = $window.FindName("cardSkipped")
$cardAmbiguous = $window.FindName("cardAmbiguous")
$cardFailed    = $window.FindName("cardFailed")

$btnFrom = $window.FindName("btnFrom")
$btnTo   = $window.FindName("btnTo")
$btnCsv  = $window.FindName("btnCsv")
$btnMap  = $window.FindName("btnMap")
$btnLogs = $window.FindName("btnLogs")

$btnDryRun   = $window.FindName("btnDryRun")
$btnRun      = $window.FindName("btnRun")
$btnOpenLogs = $window.FindName("btnOpenLogs")

$btnPreviewWouldMove = $window.FindName("btnPreviewWouldMove")
$btnPreviewSkipped   = $window.FindName("btnPreviewSkipped")
$btnLoadLast         = $window.FindName("btnLoadLast")

$gridMain = $window.FindName("gridMain")
$gridSkips = $window.FindName("gridSkips")

$btnGenSuggestions  = $window.FindName("btnGenSuggestions")
$btnOpenSuggestions = $window.FindName("btnOpenSuggestions")

$gridMappings = $window.FindName("gridMappings")
$btnAppendMappings = $window.FindName("btnAppendMappings")
$btnReloadMap = $window.FindName("btnReloadMap")
$chkOverwrite = $window.FindName("chkOverwrite")
$txtMapStatus = $window.FindName("txtMapStatus")

$lstLogs = $window.FindName("lstLogs")
$btnRefreshLogs = $window.FindName("btnRefreshLogs")
$btnOpenSelected = $window.FindName("btnOpenSelected")
$btnOpenFolder2  = $window.FindName("btnOpenFolder2")

$tglTheme = $window.FindName("tglTheme")

# Apply initial theme
Apply-Theme -Window $window -ThemeName $script:CurrentTheme
$tglTheme.Content = $script:CurrentTheme

# Events
$btnFrom.Add_Click({ $p = Select-Folder; if ($p) { $txtFrom.Text = $p } })
$btnTo.Add_Click({ $p = Select-Folder; if ($p) { $txtTo.Text = $p } })
$btnCsv.Add_Click({ $p = Select-File "CSV files (*.csv)|*.csv"; if ($p) { $txtCsv.Text = $p } })
$btnMap.Add_Click({ $p = Select-File "CSV files (*.csv)|*.csv"; if ($p) { $txtMap.Text = $p } })
$btnLogs.Add_Click({ $p = Select-Folder; if ($p) { $txtLogs.Text = $p; Refresh-LogsList } })

$btnOpenLogs.Add_Click({ if (Test-Path $txtLogs.Text) { Start-Process explorer.exe $txtLogs.Text } })

$btnDryRun.Add_Click({ Run-Engine -Dry $true })
$btnRun.Add_Click({ Run-Engine -Dry $false })

$btnLoadLast.Add_Click({ Load-LatestToState })

$btnPreviewWouldMove.Add_Click({
    if ($script:LastWouldMovePath -and (Test-Path $script:LastWouldMovePath)) {
        Load-WouldMovePreview $script:LastWouldMovePath
    } else {
        Append-Output "No WouldMove CSV loaded. Click Load Latest Results or run a dry run."
    }
})

$btnPreviewSkipped.Add_Click({
    if ($script:LastSkippedPath -and (Test-Path $script:LastSkippedPath)) {
        Load-SkippedPreview $script:LastSkippedPath
        # Update Skipped/Ambiguous card counters from file too (handy when just loading latest)
        $rows = @(Import-Csv $script:LastSkippedPath)
        $cardSkipped.Text = ("" + $rows.Count)
        $cardAmbiguous.Text = ("" + @($rows | Where-Object { $_.SkipReason -match "Ambiguous" }).Count)
    } else {
        Append-Output "No Skipped CSV loaded. Click Load Latest Results or run a dry run."
    }
})

$btnGenSuggestions.Add_Click({ Suggest-MappingsFromSkipped })
$btnAppendMappings.Add_Click({ Append-MappingsToMap })

$btnOpenSuggestions.Add_Click({
    $mp = $txtMap.Text.Trim()
    if ($mp -and (Test-Path $mp)) { Start-Process notepad.exe $mp }
    elseif ($mp) { Append-Output "Map file not found yet: $mp" }
})

$btnReloadMap.Add_Click({ Refresh-LogsList })

$btnRefreshLogs.Add_Click({ Refresh-LogsList })
$btnOpenFolder2.Add_Click({ if (Test-Path $txtLogs.Text) { Start-Process explorer.exe $txtLogs.Text } })
$btnOpenSelected.Add_Click({
    $sel = $lstLogs.SelectedItem
    if ($sel -and (Test-Path $sel)) { Start-Process $sel }
})

$tglTheme.Add_Click({
    if ($script:CurrentTheme -eq "Dark") {
        Apply-Theme -Window $window -ThemeName "Light"
    } else {
        Apply-Theme -Window $window -ThemeName "Dark"
    }
    $tglTheme.Content = $script:CurrentTheme
})

# Initial output
$txtOutput.Clear()
Append-Output "Ready."
Append-Output "Tip: Click 'Load Latest Results' to pull the newest logs into the UI."
Refresh-LogsList

# Show UI
$null = $window.ShowDialog()
