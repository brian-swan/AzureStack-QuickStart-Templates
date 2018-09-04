# Set up log backup
Get-Service SQLSERVERAGENT | Start-Service
Invoke-Sqlcmd -InputFile "MaintenanceSolution.sql"