Param
(
    [Parameter(Mandatory=$true)]
    [string]$UserName,

    [Parameter(Mandatory=$true)]
    [string]$Password,

    [Parameter(Mandatory=$true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory=$true)]
    [string]$ConnectMachines, #semicolon separated list of machine names e.g. "vm1;vm2"

    [Parameter(Mandatory=$true)]
    [string]$StorageAccountKey,

    # default deployment branch to master for now to keep things the same
    [Parameter(Mandatory=$False)]
    [string]$DeploymentBranch = "master"
)

# Set up log backup
Get-Service SQLSERVERAGENT | Start-Service
Invoke-Sqlcmd -InputFile "MaintenanceSolution.sql"

# Create azbetsqluser login
$createLogin = "CREATE Login $UserName WITH Password = '$Password', SID = 0x593F982D94683D4ABA61D4390CF67FC9, CHECK_EXPIRATION=OFF, CHECK_POLICY=OFF"
$addLoginToSysAdmin = "ALTER SERVER ROLE sysadmin ADD MEMBER $UserName"
Invoke-Sqlcmd -Query $createLogin 
Invoke-Sqlcmd -Query $addLoginToSysAdmin
Restart-Service -Force MSSQLSERVER

# Install AzBet Monitor
if( $null -eq (Get-Module -ListAvailable -Name AzureRM.Storage))
{
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module AzureRM.Storage -Force
}
$context = New-AzureStorageContext -StorageAccountName azurestackbetastorage -StorageAccountKey $StorageAccountKey
Get-AzureStorageBlobContent -Context $context -Container azbetdrops -Blob Deploy-Monitoring-Remote.ps1 -Destination C:\
Get-AzureStorageBlobContent -Context $context -Container azbetdrops -Blob AzBet.Monitor_$DeploymentBranch.zip -Destination C:\
Expand-Archive -Path C:\AzBet.Monitor_$DeploymentBranch.zip -DestinationPath C:\AzBet.Monitor
$configXml = [Xml] (Get-Content C:\AzBet.Monitor\AzBet.Monitor.azbetstackerpaaswebstp1.exe.config)
($configXml.SelectNodes("/configuration/appSettings/add") | where {$_.key -eq "LogEnvironment"}).value = $EnvironmentName
($configXml.SelectNodes("/configuration/appSettings/add") | where {$_.key -eq "MachineRole"}).value = "database"
($configXml.SelectNodes("/configuration/appSettings/add") | where {$_.key -eq "ConnectMachines"}).value = $ConnectMachines
$configXml.Save("C:\AzBet.Monitor\AzBet.Monitor.$EnvironmentName.exe.config")
Compress-Archive -Path C:\AzBet.Monitor\AzBet.Monitor.$EnvironmentName.exe.config -Update -DestinationPath C:\AzBet.Monitor_$DeploymentBranch.zip
Remove-Item -Path C:\AzBet.Monitor -Recurse -Force
& C:\Deploy-Monitoring-Remote.ps1 -PackageUrl C:\AzBet.Monitor_$DeploymentBranch.zip -environment $EnvironmentName
