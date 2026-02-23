# Project Archiver (P:\ ➜ A:\) — Archive Engine + UI

A PowerShell toolset to **bulk archive completed jobs** by moving job folders from an Active root (e.g. `P:\`) into an Archive root (e.g. `A:\`) using a **Projects CSV export** from ProWorkFlow.

It supports:
- **Dry Run** reporting (no changes)
- **Real Move** using `robocopy /MOVE`
- **Skip reasons** (dest exists, missing client folder, missing job folder, ambiguous client match, etc.)
- **Client folder mapping** (to solve “Burger King vs Burger King Ltd vs BK Industries” problems)
- A **WPF UI** (Winutil-style vibe) with:
  - Summary cards (WouldMove / Skipped / Ambiguous / Failed)
  - Preview grids (WouldMove + Skipped)
  - “Fix mappings” grid to append mappings into `ClientFolderMap.csv`
  - Logs browser

> Designed to chew through backlog runs **after-hours / weekends** with clear reporting.

## Run in PowerShell (Elevated)
'''
irm "https://raw.githubusercontent.com/slitzer/Project-Archiving-Utility/main/install.ps1" | iex
'''

---

## Folder Structure

Recommended base folder:

----C:\TRANSFERSCRIPT
---ArchiveEngine.ps1
---ArchiveUI.ps1
---ProjectsToArchive.csv
---ClientFolderMap.csv
--Logs
-ArchiveMove-YYYYMMDD-HHMMSS.log
-WouldMove-YYYYMMDD-HHMMSS.csv
-Skipped-YYYYMMDD-HHMMSS.csv


---

## Data / Inputs

### 1) Projects CSV (from ProWorkFlow)
Export a CSV containing at minimum these headers:

- `Category`
- `Project Number`
- `Project Title`
- `Client Name`

The script **uses**:
- `Project Number` (required)
- `Client Name` (required)
- `Project Title` (optional but included in logs)

### 2) Client Folder Map (optional but strongly recommended)
`ClientFolderMap.csv` format:

```csv
ClientName,SourceFolderName,DestinationFolderName
Burger King,BK Ltd,Burger King Archive
Mad Butcher,Mad Butcher Limited,Mad Butcher Limited
```

Use this when:

    Client names in ProWorkFlow do not match server folder names

    Multiple folders are close matches (ambiguous)

    You want deterministic matching

What It Does

For each row in the Projects CSV:

    Determine the client folder in the Active root (P:\ClientFolder)

        Prefer exact mapping from ClientFolderMap.csv (SourceFolderName/DestinationFolderName, with FolderName still supported for backward compatibility)

        Otherwise use best-match scoring (normalized name word overlap)

    Inside the client folder, find a job folder whose name starts with the project number:

        Example match: 12345 - Something Something

    Create archive folder path if needed:

        A:\DestinationFolderName\

    Move the job folder into archive:

        From: P:\SourceFolderName\12345 - ...

        To: A:\DestinationFolderName\12345 - ...

    Log every decision:

        WouldMove or Move

        Skipped + reason

    The engine will not overwrite existing destination folders. If destination exists, it is skipped.

Run Modes
Dry Run (recommended first)

Dry Run produces reports but does not move anything.

```powershell
powershell -ExecutionPolicy Bypass -File C:\TRANSFERSCRIPT\ArchiveEngine.ps1 \
  -CsvPath C:\TRANSFERSCRIPT\ProjectsToArchive.csv \
  -ActiveRoot P:\ \
  -ArchiveRoot A:\ \
  -OutDir C:\TRANSFERSCRIPT\Logs \
  -ClientMapPath C:\TRANSFERSCRIPT\ClientFolderMap.csv \
  -DryRun
```

Outputs in C:\TRANSFERSCRIPT\Logs\:

    WouldMove-*.csv

    Skipped-*.csv

    ArchiveMove-*.log

Real Move (production)

```powershell
powershell -ExecutionPolicy Bypass -File C:\TRANSFERSCRIPT\ArchiveEngine.ps1 \
  -CsvPath C:\TRANSFERSCRIPT\ProjectsToArchive.csv \
  -ActiveRoot P:\ \
  -ArchiveRoot A:\ \
  -OutDir C:\TRANSFERSCRIPT\Logs \
  -ClientMapPath C:\TRANSFERSCRIPT\ClientFolderMap.csv
```

    Strongly recommended to run after-hours due to network and file server load.

Using the UI

Launch:

powershell -ExecutionPolicy Bypass -File C:\TRANSFERSCRIPT\ArchiveUI.ps1

Run Tab

    Select/confirm:

        Move From Root (e.g. P:\)

        Move To Root (e.g. A:\)

        Projects CSV

        Client Map CSV

        Logs folder

    Tick “Dry Run” for a no-change run

    Click:

        Dry Run

        Run Move

        Logs (opens logs folder)

Summary cards update from the last run.
Preview Tab

    Load and preview:

        WouldMove CSV

        Skipped CSV

    View skip breakdown by reason

    Generate mapping suggestions (based on ambiguous/missing client rows)

Mappings Tab

    Shows suggested mappings in a grid

    You can edit both SourceFolderName and DestinationFolderName fields

    Select rows and click Append selected to map

    Optional overwrite mode (if your UI has it enabled)

Logs Tab

    Lists log/report files in the logs directory

    Open selected log/report

    Refresh list

Safety / Guardrails
Drive letters must exist in the same user context

If you run PowerShell as admin or a different user, P:\ and A:\ may not exist.

Fix options:

    Run in the same user context that sees those drives (usually non-elevated)

    Or change the roots to UNC paths (recommended long-term)

        Example: \\server\share\...

What it will NOT do

    It will not overwrite destination folders

    It will not merge folders

    It will not guess if multiple job folders match the same project number (it will skip as ambiguous)

Skipped Reasons (Common)
Destination already exists

    Job may already be archived

    Or partially moved earlier

    Manual review needed if you want to merge/overwrite

Active client folder missing

    Client folder name in PWF doesn’t exist on P:\

    Add a mapping, or create the client folder, or confirm job already moved

Job folder not found under client folder

    No folder under the client begins with the project number

    Common causes:

        Folder renamed

        Project number not included at the start

        Job already moved

        Job stored in a different structure

Ambiguous client folder match (tie)

    Multiple client folders scored equally (“Eaton”, “Eaton Electrical”, “Eaton Industries”)

    Fix: add a mapping entry to force the correct folder

Recommended Workflow (Backlog Clearing)

    Export backlog list from ProWorkFlow to ProjectsToArchive.csv

    Run a Dry Run and review:

        WouldMove count (good)

        Skipped reasons (fixable items)

    Use UI “Fix mappings” to reduce ambiguity

    Re-run Dry Run until acceptable skip rate

    Run Real Move after-hours

    After file moves are complete, close projects in ProWorkFlow manually

Performance Notes

Archiving is I/O heavy:

    Many small files = slower

    Large files = faster per file but heavy on bandwidth

    Expect slower performance during office hours

Recommendation:

    Run after hours or on weekends

    If possible, run from a machine close to the file server (low latency)

Troubleshooting
“Drive P: does not exist”

    You are running in a context that doesn’t have mapped drives

    Run non-elevated

    Or convert to UNC paths

“Unexpected token '??'”

    You’re on Windows PowerShell 5.1 (no null-coalescing ??)

    Ensure scripts do not use ?? and use PS 5.1 safe patterns:

        if ($null -eq $x) { ... }

CSV imports but 0 rows

    The headers don’t match expected column names exactly

    Confirm the CSV has:

        Project Number

        Client Name

        Project Title (optional)

    Open CSV in Notepad and confirm delimiter is comma

Logs show “Ambiguous”

    Add mappings in ClientFolderMap.csv (or via UI tab)

Files moved but some remain behind

    Robocopy exit codes can indicate partial issues (locked files)

    Re-run after hours

    Check ArchiveMove-*.log for details

Admin / Support Notes
Robocopy behavior

Engine uses:

    /E copy subfolders including empty

    /MOVE move files + dirs

    /R:2 /W:5 minimal retries

    /COPY:DAT /DCOPY:DAT data/attributes/timestamps

    /XJ avoid junction loops

    /NP no progress spam

Robocopy exit code interpretation:

    < 8 generally OK

    >= 8 treated as failure in summary

Outlook archiving

This tool currently focuses on file server archiving (P:\ ➜ A:).
Outlook/mailbox folder moves are typically a separate phase because they depend on:

    Exchange vs M365 vs local PST

    Delegate permissions

    Folder naming consistency

    Throttling / API constraints

Change Log

    v1: Engine + reporting (Dry Run / Move)

    v2: UI with summary cards, previews, mapping editor, logs browser

    v3: Theme toggle + persistent settings (optional)
