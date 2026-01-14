@echo off
setlocal EnableDelayedExpansion

echo === Starting Database Backup Job ===
echo Date: %date%  Time: %time%
echo Initializing environment...

:: ==================================================
:: PARAMETERS
:: %1 = SQL Server instance (e.g. localhost\SQLEXPRESS)
:: %2 = SQL username
:: %3 = SQL password
:: ==================================================

:: ==================================================
:: DATE VARIABLES (YYYY_MM_DD)
:: ==================================================
set DAY=%date:~-10,2%
set MONTH=%date:~-7,2%
set YEAR=%date:~-4%

:: ==================================================
:: CONFIGURATION
:: ==================================================
set SQL_INSTANCE=%1
set SQL_USER=%2
set SQL_PASSWORD=%3

set LOCAL_BACKUP_DIR=F:\DB
set NETWORK_ROOT=\\192.168.1.100\Public\DBFolder
set NETWORK_BACKUP_DIR=%NETWORK_ROOT%\%YEAR%_%MONTH%_%DAY%

set LOG_DIR=%LOCAL_BACKUP_DIR%\logs
set ARCHIVE_EXT=rar

:: ==================================================
:: PREPARE DIRECTORIES
:: ==================================================
if not exist "%LOCAL_BACKUP_DIR%" mkdir "%LOCAL_BACKUP_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

echo Local backup folder : %LOCAL_BACKUP_DIR%
echo Network backup path : %NETWORK_BACKUP_DIR%

:: ==================================================
:: GET DATABASE LIST
:: ==================================================
echo Retrieving database list...

sqlcmd -S %SQL_INSTANCE% -U %SQL_USER% -P %SQL_PASSWORD% ^
-Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4" ^
-h -1 -W > "%LOCAL_BACKUP_DIR%\databases.txt"

:: ==================================================
:: BACKUP AND COMPRESS DATABASES
:: ==================================================
for /F "usebackq tokens=*" %%D in ("%LOCAL_BACKUP_DIR%\databases.txt") do (
    echo Backing up database: %%D

    sqlcmd -S %SQL_INSTANCE% -U %SQL_USER% -P %SQL_PASSWORD% ^
    -Q "BACKUP DATABASE [%%D] TO DISK = N'%LOCAL_BACKUP_DIR%\%%D.bak' WITH INIT, STATS = 5" ^
    >> "%LOG_DIR%\%%D.log"

    if exist "C:\Program Files\WinRAR\Rar.exe" (
        "C:\Program Files\WinRAR\Rar.exe" a -ep1 ^
        "%LOCAL_BACKUP_DIR%\%%D.%ARCHIVE_EXT%" ^
        "%LOCAL_BACKUP_DIR%\%%D.bak" ^
        "%LOG_DIR%\%%D.log"
    ) else (
        echo WARNING: WinRAR not found. Compression skipped for %%D
    )
)

:: ==================================================
:: CONNECT TO NETWORK SHARE
:: ==================================================
echo Connecting to network storage...

NET USE "%NETWORK_ROOT%" /USER:Nas-User Password /PERSISTENT:NO >NUL 2>&1
IF ERRORLEVEL 1 (
    echo ERROR: Unable to connect to network share
    GOTO END
)

if not exist "%NETWORK_BACKUP_DIR%" mkdir "%NETWORK_BACKUP_DIR%"

:: ==================================================
:: COPY BACKUPS TO NETWORK
:: ==================================================
echo Copying backup archives to network location...
xcopy /Y "%LOCAL_BACKUP_DIR%\*.%ARCHIVE_EXT%" "%NETWORK_BACKUP_DIR%" >NUL

:: ==================================================
:: CLEANUP
:: ==================================================
echo Cleaning temporary files...
del /Q "%LOCAL_BACKUP_DIR%\*.bak" >NUL 2>&1
del /Q "%LOCAL_BACKUP_DIR%\*.%ARCHIVE_EXT%" >NUL 2>&1
del /Q "%LOCAL_BACKUP_DIR%\databases.txt" >NUL 2>&1

echo === Backup Completed Successfully ===
echo End time: %date% %time%

:END
endlocal
exit /b 0
