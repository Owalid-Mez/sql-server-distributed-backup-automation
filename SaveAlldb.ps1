# ======== CONFIG ========
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configFile = Join-Path $scriptDir "conex.csv"
$logFile = Join-Path $scriptDir "backup_results.log"
$tempDir = Join-Path $scriptDir "JobLogs"
# ========================

# Check for SqlServer module
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "Invoke-Sqlcmd not found. Install the SqlServer module first." -ForegroundColor Red
    exit
}

# Read server list
if (-not (Test-Path $configFile)) {
    Write-Host "Config file not found: $configFile" -ForegroundColor Red
    exit
}

# Create temp log folder
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

$servers = Import-Csv -Path $configFile

# Start logging
"==============================" | Out-File $logFile
"Backup Run - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $logFile -Append
"==============================" | Out-File $logFile -Append

$jobs = @()

foreach ($entry in $servers) {
    $serverName = $entry.ServerName
    $server = $entry.ServerInstance
    $user = $entry.Username
    $password = $entry.Password
    $bat = $entry.BatchFile
    $jobLog = Join-Path $tempDir "$($serverName -replace '[^a-zA-Z0-9_-]', '_').log"

    $jobs += Start-Job  -ScriptBlock {
        
        param($serverName, $server, $user, $password, $bat, $jobLog)
        Import-Module SQLPS 
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] Server: ${serverName} (${server})" | Out-File $jobLog

        $status = "UNKNOWN"
        $safeBat = $bat -replace "'", "''"

        try {
            # Step 1: Test connection
            Invoke-Sqlcmd -ServerInstance $server -Username $user -Password $password -Query "SELECT 1" -ErrorAction Stop | Out-Null
        } catch {
            "    FAILED - Cannot connect to SQL Server: $($_.Exception.Message)" | Out-File $jobLog -Append
            Write-Output "$serverName|FAILED (Connection)"
            return
        }

        try {
            # Step 2: Check batch file
           
$escapedPath = $bat -replace "'", "''"
$query = @"
DECLARE @exists INT;

EXEC master.dbo.xp_fileexist N'$escapedPath', @exists OUTPUT;

SELECT @exists AS FileExists;
"@

$fileCheck = Invoke-Sqlcmd -ServerInstance $server `
                           -Username $user `
                           -Password $password `
                           -Query $query `
                           -ErrorAction Stop

if ($fileCheck -and $fileCheck.FileExists -ne $null) {
    $fileExists = [int]$fileCheck.FileExists
} else {
    $fileExists = 0
}


Write-Host "[${fileExists}] this test file [$escapedPath]" -ForegroundColor Green
if ($fileExists -eq 1) {
    Write-Host "[$serverName]  Batch file found and accessible." -ForegroundColor Green
    "    Batch file verified: $bat" | Out-File $jobLog -Append
}
else {
    Write-Host "[$serverName]  File not found or inaccessible." -ForegroundColor Red
    "    FAILED - Batch file missing: $bat" | Out-File $jobLog -Append
    Write-Output "$serverName|FAILED (File Missing)"
    return
}

        } catch {
            "    FAILED - xp_fileexist error: $($_.Exception.Message)" | Out-File $jobLog -Append
            Write-Output "$serverName|FAILED (xp_fileexist error)"
            return
        }

   try {
    # Step 3: Enable xp_cmdshell and run batch
    $sql = @"
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
EXEC xp_cmdshell '$safeBat $server $user $password';
"@

    $result = Invoke-Sqlcmd -ServerInstance $server -Username $user -Password $password -Query $sql -QueryTimeout 0 -ErrorAction Stop

    # --- Write raw output to log (filter out NULL/empty rows) ---
    $cleanResult = @()
    if ($result) {
        $cleanResult = $result | Where-Object { $_ -and $_ -ne $null -and ($_ -ne "" -and ($_ -ne "NULL")) }
        if ($cleanResult.Count -gt 0) {
            "---- xp_cmdshell Output ----" | Out-File $jobLog -Append
            $cleanResult | ForEach-Object {
                ($_ | Out-String).Trim() | Out-File $jobLog -Append
            }
            "---- End of Output ----" | Out-File $jobLog -Append
        } else {
            "    (xp_cmdshell returned no visible output)" | Out-File $jobLog -Append
        }
    } else {
        "    (No data returned by xp_cmdshell)" | Out-File $jobLog -Append
    }

    # --- Detect actual success message from .bat file ---
$joinedOutput = ($cleanResult | ForEach-Object { $_.output }) -join "`n"

if ($joinedOutput -match "Backup Completed Successfully") {
    "    SUCCESS (Detected success message)" | Out-File $jobLog -Append
    Write-Output "$serverName|SUCCESS"
}
else {
    "    FAILED - No success message detected in batch output" | Out-File $jobLog -Append
    Write-Output "$serverName|FAILED (No success message)"
}
}
catch {
    "    FAILED - xp_cmdshell execution error: $($_.Exception.Message)" | Out-File $jobLog -Append
    Write-Output "$serverName|FAILED (Execution Error)"
}
    } -ArgumentList $serverName, $server, $user, $password, $bat, $jobLog
}

Write-Host "`nStarted $($jobs.Count) parallel jobs..." -ForegroundColor Yellow

# --- PROGRESS LOOP ---
$total = $jobs.Count
while ($true) {
    $completed = ($jobs | Where-Object { $_.State -eq 'Completed' }).Count
    $running = ($jobs | Where-Object { $_.State -eq 'Running' }).Count
    $percent = [math]::Round(($completed / $total) * 100, 2)

    Write-Progress -Activity "Running SQL Backups" `
                   -Status "Running: $running | Completed: $completed " `
                   -PercentComplete $percent
    if ($completed -eq $total) { break }
    Start-Sleep -Seconds 3
}

Write-Host "`nAll backup jobs completed!" -ForegroundColor Green

# --- Collect Results ---
$results = @()
foreach ($job in $jobs) {
    $output = Receive-Job -Job $job -Keep
    foreach ($line in $output) {
        if ($line -match '\|') {
            $parts = $line -split '\|'
            $results += [PSCustomObject]@{
                Server = $parts[0]
                Status = $parts[1]
            }
        }
    }
}

Write-Host "`n=== FINAL STATUS REPORT ===" -ForegroundColor Cyan
foreach ($r in $results) {
    if ($r.Status -like "*SUCCESS*") {
        Write-Host ("{0,-25} : {1}" -f $r.Server, $r.Status) -ForegroundColor Green
    } else {
        Write-Host ("{0,-25} : {1}" -f $r.Server, $r.Status) -ForegroundColor Red
    }
}

$total = $results.Count
$success = ($results | Where-Object { $_.Status -like "*SUCCESS*" }).Count
$failed = $total - $success
Write-Host "`nTotal: $total | Success: $success | Failed: $failed" -ForegroundColor Yellow

# Merge logs
Write-Host "`nMerging logs..." -ForegroundColor Yellow
Get-ChildItem $tempDir -Filter *.log | Sort-Object Name | ForEach-Object {
    Get-Content $_.FullName | Out-File $logFile -Append
}

# Cleanup
Remove-Job -Job $jobs -Force
# Remove-Item $tempDir -Recurse -Force  # Comment out if you want to inspect logs

Add-Content $logFile "`nAll servers processed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "`nResults logged to: $logFile" -ForegroundColor Cyan
Write-Host "Appuyez sur une touche pour fermer..." -ForegroundColor Yellow
[void][System.Console]::ReadKey($true)
