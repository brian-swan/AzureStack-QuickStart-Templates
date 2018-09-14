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
    [string]$DeploymentBranch = "master",

    [ValidateSet("true", "false")]
    [string] $IsIaasDeployment
)

if($IaasDeployment -eq "true")
{
    $IsIaasDeployment = $true
}
else
{
    $IsIaasDeployment = $false
}

# Set up log backup
Get-Service SQLSERVERAGENT | Start-Service
Invoke-Sqlcmd -InputFile "MaintenanceSolution.sql"

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

# Attach 2nd data disk
$disk = Get-Disk | Where partitionstyle -eq 'raw' | Where number -ne $null | sort number | select -last 1
$driveLetter = "G"
$label = "SQLVMDATA2"
$disk | Initialize-Disk -PartitionStyle MBR -PassThru | New-Partition -UseMaximumSize -DriveLetter $driveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force

# Resotre AzBet database (and ASPState database, if necessary)
if(-not (Test-Path "G:\LOG"))
{
    New-Item -ItemType Directory -Path "G:\LOG"
}

$restoreAzbetDb = @"
RESTORE DATABASE AzBetDB FROM DISK = 'C:\AzBetDB.bak'
WITH MOVE 'AzBetDB' TO 'F:\DATA\AzBetDB.mdf',
MOVE 'AzBetDB_log' TO 'G:\LOG\AzBetDB_log.ldf',
REPLACE
"@

$restoreAzbetDbWithNORECOVERY = @"
RESTORE DATABASE AzBetDB FROM DISK = 'C:\AzBetDB.bak'
WITH MOVE 'AzBetDB' TO 'F:\DATA\AzBetDB.mdf',
MOVE 'AzBetDB_log' TO 'G:\LOG\AzBetDB_log.ldf',
REPLACE, NORECOVERY
"@

$restoreAspstateDb = @"
RESTORE DATABASE ASPState FROM DISK = 'C:\ASPState.bak'
WITH MOVE 'ASPState' TO 'F:\DATA\ASPState.mdf',
MOVE 'ASPState_log' TO 'G:\LOG\ASPState_log.ldf',
REPLACE
"@

$restoreAspstateDbWithNORECOVERY = @"
RESTORE DATABASE ASPState FROM DISK = 'C:\ASPState.bak'
WITH MOVE 'ASPState' TO 'F:\DATA\ASPState.mdf',
MOVE 'ASPState_log' TO 'G:\LOG\ASPState_log.ldf',
REPLACE, NORECOVERY
"@

$getPrimaryName = @"
SELECT
ISNULL(agstates.primary_replica, '') AS [PrimaryName]
FROM master.sys.availability_groups AS AG
LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states as agstates
    ON AG.group_id = agstates.group_id
INNER JOIN master.sys.availability_replicas AS AR
    ON AG.group_id = AR.group_id
INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates
    ON AR.replica_id = arstates.replica_id AND arstates.is_local = 1
WHERE AG.name = 'alwayson-ag'
"@

$azBetJoinedAvGroup = @"
select count(*) as result from sys.dm_hadr_database_replica_states as r
join sys.databases as s
on r.database_id = s.database_id
where s.name = 'AzBetDB'
"@

$aspStateJoinedAvGroup = @"
select count(*) as result from sys.dm_hadr_database_replica_states as r
join sys.databases as s
on r.database_id = s.database_id
where s.name = 'ASPState'
"@

$joinAzBetDBPrimaryToAG = "ALTER AVAILABILITY GROUP `"alwayson-ag`" ADD DATABASE AzBetDB"

$joinAzBetDBSecondaryToAG = "ALTER DATABASE AzBetDB SET HADR AVAILABILITY GROUP = `"alwayson-ag`""

$joinASPStatePrimaryToAG = "ALTER AVAILABILITY GROUP `"alwayson-ag`" ADD DATABASE ASPState"

$joinASPStateSecondaryToAG = "ALTER DATABASE ASPState SET HADR AVAILABILITY GROUP = `"alwayson-ag`""

if(-not (Test-Path C:\AzBetDB.bak))
{
    $context = New-AzureStorageContext -StorageAccountName azurestackbetastorage -StorageAccountKey $StorageAccountKey
    Get-AzureStorageBlobContent -Context $context -Container azbetdrops -Blob AzBetDB.bak -Destination C:\
    if($IsIaasDeployment)
    {
        Get-AzureStorageBlobContent -Context $context -Container azbetdrops -Blob ASPState.bak -Destination C:\
    }
}

$isPrimary = Invoke-SqlCmd -Query "select sys.fn_hadr_is_primary_replica ( 'AutoHa-sample' )"
$primaryNameResult = Invoke-Sqlcmd -Query $getPrimaryName
$primaryName = $primaryNameResult['PrimaryName']

if($isPrimary.Column1 -eq $true)
{
    Invoke-Sqlcmd -Query $restoreAzbetDb -QueryTimeout 300
    Invoke-Sqlcmd -Query $joinAzBetDBPrimaryToAG -QueryTimeout 300
    if($IsIaasDeployment)
    {
        Invoke-Sqlcmd -Query $restoreAspstateDb -QueryTimeout 300
        Invoke-Sqlcmd -Query $joinASPStatePrimaryToAG -QueryTimeout 300
    }
}
else
{
    # On the secondary, we need to wait for the DB to be joined tot he AV group on the master.
    # Wait at most 20 min (120 x 10s)
    for($i = 0; $i -lt 120; $i++)
    {
        Write-Host("Waiting for AzBetDB to join Availability Group (sleeping 10 seconds)...")
        Start-Sleep -Seconds 10
        $result = Invoke-Sqlcmd $azbetJoinedAvGroup -ServerInstance $primaryName
        if ($result['result'] -gt 1)
        {
            Write-Host "Joining AzBetDB to secondary..."
            break
        }
    }
    Invoke-Sqlcmd -Query $restoreAzbetDbWithNORECOVERY -QueryTimeout 300
    Invoke-Sqlcmd -Query $joinAzBetDBSecondaryToAG -QueryTimeout 300
    if($IsIaasDeployment)
    {
         # On the secondary, we need to wait for the DB to be joined tot he AV group on the master.
        # Wait at most 20 min (120 x 10s)
        for($i = 0; $i -lt 120; $i++)
        {
            Write-Host("Waiting for ASPState to join Availability Group (sleeping 10 seconds)...")
            Start-Sleep -Seconds 10
            $result = Invoke-Sqlcmd $aspStateJoinedAvGroup -ServerInstance $primaryName
            if ($result['result'] -gt 1)
            {
                Write-Host "Joining ASPState to secondary..."
                break
            }
        }
        Invoke-Sqlcmd -Query $restoreAspstateDbWithNORECOVERY -QueryTimeout 300
        Invoke-Sqlcmd -Query $joinASPStateSecondaryToAG -QueryTimeout 300
    }
}