Param {
    [Parameter(Mandatory=$false)]
    $UserName = "azbetsqluser",
    [Parameter(Mandatory=$true)]
    $Password
}
# Set up log backup
Get-Service SQLSERVERAGENT | Start-Service
Invoke-Sqlcmd -InputFile "MaintenanceSolution.sql"

# Create azbetsqluser login
$createLogin = "CREATE Login $UserName WITH Password = '$Password', SID = 0x593F982D94683D4ABA61D4390CF67FC9, CHECK_EXPIRATION=OFF, CHECK_POLICY=OFF"
$addLoginToSysAdmin = "ALTER SERVER ROLE sysadmin ADD MEMBER $UserName"

Invoke-Sqlcmd -Query $createLogin 
Invoke-Sqlcmd -Query $addLoginToSysAdmin
Restart-Service -Force MSSQLSERVER