# SQL Server Distributed Backup Automation

## Overview
This project provides a centralized and automated solution for running SQL Server backups across multiple remote servers using PowerShell and batch scripts.

## Features
- Parallel execution across multiple SQL Servers
- CSV-based configuration
- SQL connectivity validation
- Remote batch execution via xp_cmdshell
- Backup verification and success detection
- Consolidated logging and reporting

## Requirements
- PowerShell 5.1+
- SqlServer PowerShell module
- SQL Server permissions to execute xp_cmdshell
- Batch backup script present on target servers

## Usage

1. Copy the `savedb.bat` file to each target SQL Server.
2. Ensure the file path matches the `BatchFile` value in `conex.csv`.
3. Configure the CSV file with the correct server and credential details.
4. Run the PowerShell orchestration script.
5. Review the consolidated log file for results.

## Security Notes
- Avoid using `sa`
- Use least-privilege SQL logins
- Protect credentials and restrict xp_cmdshell usage

## License
MIT
