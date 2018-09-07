#
# xSqlCreateVirtualDataDisk: DSC resource to create a virtual data disk 
#

function Get-TargetResource
{
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $NumberOfDisks,

        [ValidateNotNullOrEmpty()]
        [System.Uint32]
        $NumberOfColumns = 0,
        
        [parameter(Mandatory = $true)]
        [System.Array]$DiskLetters,

        [parameter(Mandatory = $true)]
        [System.String]$OptimizationType,

        [parameter(Mandatory = $true)]
        [System.Uint32]$StartingDeviceID,

        [ValidateNotNullOrEmpty()]
        [Bool]$RebootVirtualMachine = $false 
    )
    
    $bConfigured = Test-TargetResource -NumberOfDisks $NumberOfDisks -NumberOfColumns $NumberOfColumns -DiskLetters $DiskLetters -OptimizationType $OptimizationType -RebootVirtualMachine $RebootVirtualMachine

    $retVal = @{
        NumberOfDisks = $NumberOfDisks
        NumberOfColumns = $NumberOfColumns
        DiskLetters = $DiskLetters
        OptimizationType = $OptimizationType
        StartingDeviceID = $StartingDeviceID
        RebootVirtualMachine = $RebootVirtualMachine
    }

    $retVal
}


function Test-TargetResource
{
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $NumberOfDisks,

        [ValidateNotNullOrEmpty()]
        [System.Uint32]
        $NumberOfColumns = 0,
        
        [parameter(Mandatory = $true)]
        [System.Array]$DiskLetters,

        [parameter(Mandatory = $true)]
        [System.String]$OptimizationType,

        [parameter(Mandatory = $true)]
        [System.Uint32]$StartingDeviceID,

        [ValidateNotNullOrEmpty()]
        [Bool]$RebootVirtualMachine = $false 
    )
    
    $result = [System.Boolean]

    $i = 0
    $foundCount = 0
    Foreach($DiskLetter in $DiskLetters)
    {
        $letter = $DiskLetter[$i][0]
        Try 
        {
            if (Get-volume -DriveLetter $letter -ErrorAction SilentlyContinue) 
            {
                Write-Verbose "'$($letter)' exists on target."

                $foundCount++
            }
            else
            {
                Write-Verbose "'$($letter)' not Found."
            }
        }
        Catch 
        {
            throw "An error occured getting the '$($letter)' drive informations. Error: $($_.Exception.Message)"
        }
        $i++
    }
    if ($foundCount -eq 2)
    {
        $result = $true
    }
    else 
    {
        $result = $false
    }
    $result    
}

function Set-TargetResource
{
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $NumberOfDisks,

        [ValidateNotNullOrEmpty()]
        [System.Uint32]
        $NumberOfColumns = 0,
        
        [parameter(Mandatory = $true)]
        [System.Array]$DiskLetters,

        [parameter(Mandatory = $true)]
        [System.String]$OptimizationType,

        [parameter(Mandatory = $true)]
        [System.Uint32]$StartingDeviceID,

        [ValidateNotNullOrEmpty()]
        [Bool]$RebootVirtualMachine = $false 
    )

    #Validating Paramters
    if ($NumberOfColumns -gt $NumberOfDisks)
    {
        Write-Verbose "NumberOfColumns ( $($NumberOfColumns) ) if greater than NumberOfDisks ( $($NumberOfDisks) ). exiting"
        return $false
    } 
        
    # Set the reboot flag if necessary
    if ($RebootVirtualMachine -eq $true)
    {
        $global:DSCMachineStatus = 1
    }
    
    #Validtion OptimizationType
    if(($OptimizationType.ToUpper().CompareTo("OLTP") -eq 1) -and ($OptimizationType.ToUpper().CompareTo("GENERAL") -eq 1) -and ($OptimizationType.ToUpper().CompareTo("DW") -eq 1))
    {
        Write-Error "OptimizationType $($OptimizationType) is not recognized, exiting..."
        return $false
    }
    
    # Setting up the Interleave size based on OptimizationType
    $InterleaveSizeInByte = 262144
    
    if($OptimizationType.ToUpper().CompareTo("OLTP") -eq 0)
    {
       $InterleaveSizeInByte = 65536
    }

    #Generating StoragePoolName
    $NewStoragePoolName = GenerateStoragePoolName

    #Get Disks for storage pool
    $DisksForStoragePool = GetPhysicalDisks -DeviceID $StartingDeviceID -NumberOfDisks $NumberOfDisks

    if (!$DisksForStoragePool)
    {
        Write-Error "Unable to get any disks for creating Storage Pool. exiting"
        return $false
    }

    if ($DisksForStoragePool -and (1 -eq $NumberOfDisks))
    {
        Write-Verbose "Got $($NumberOfDisks) disks for creating Storage Pool. "
    }
    elseif ($DisksForStoragePool -and ($DisksForStoragePool.Count -eq $NumberOfDisks))
    {
        Write-Verbose "Got $($NumberOfDisks) disks for creating Storage Pool. "
    }
    else 
    {
        Write-Error "Unable to get $($NumberOfDisks) disks for creating Storage Pool. exiting"
        return $false
    }

    #Creating Storage Pool
    Write-Verbose "Creating Storage Pool $($NewStoragePoolName)"

    Write-Verbose "Getting Storage SubSystem with friendly name containing 'Storage'"
    New-StoragePool -FriendlyName $NewStoragePoolName -StorageSubSystemUniqueId (Get-StorageSubSystem -FriendlyName '*Storage*').uniqueID -PhysicalDisks $DisksForStoragePool
    
    #Validating Storage Pool
    Verify-NewStoragePool -TimeOut 20
        
    Write-Verbose "Storage Pool $($NewStoragePoolName) created successfully."        
    
    $i = 0
    Foreach($physicalDisk in $DisksForStoragePool)
    {
        $NewVirtualDiskName = GenerateVirtualDiskName
        $NewVolumeLabelName = GenerateVolumeLabel
    
        #Creating Virtual Disk
        Write-Verbose "Creating Virtual Disk $($NewVirtualDiskName)"
    
        if ($NumberOfColumns -eq 0)
        {   
            Write-Verbose "Creating Virtual Disk $($NewVirtualDiskName) with AutoNumberOfColumns"
            
            New-VirtualDisk -FriendlyName $NewVirtualDiskName -StoragePoolFriendlyName $NewStoragePoolName -UseMaximumSize -Interleave $InterleaveSizeInByte -AutoNumberOfColumns  -ResiliencySettingName Simple -ProvisioningType Fixed
        }
        else 
        {
            Write-Verbose "Creating Virtual Disk $($NewVirtualDiskName) with $($NumberOfColumns) number of columns"
            
            New-VirtualDisk -FriendlyName $NewVirtualDiskName -StoragePoolFriendlyName $NewStoragePoolName -UseMaximumSize -Interleave $InterleaveSizeInByte -NumberOfColumns $NumberOfColumns -ResiliencySettingName Simple -ProvisioningType Fixed
        
        }

        #Validating Virtual Disk
        Verify-VirtualDisk -TimeOut 20

        #Initializing Disk
        Write-Verbose "Initializing Virtual Disk $($NewVirtualDiskName)"
    
        Initialize-Disk -VirtualDisk (Get-VirtualDisk -FriendlyName $NewVirtualDiskName)
       
        #Creating Partition
        $diskNumber = ((Get-VirtualDisk -FriendlyName $NewVirtualDiskName | Get-Disk).Number)
 
        Write-Verbose 'Creating Partition'
    
        New-Partition -DiskNumber $diskNumber -UseMaximumSize -DriveLetter $DiskLetters[$i][0]
    
        Verify-Partition -TimeOut 20 -DriveLetter $DiskLetters[$i][0]
 
        #Formatting Volume
        Write-Verbose 'Formatting Volume and Assigning Drive Letter'
        
        #All file systems that are used by Windows organize your hard disk based on cluster size (also known as allocation unit size). 
        #Cluster size represents the smallest amount of disk space that can be used to hold a file. 
        #When file sizes do not come out to an even multiple of the cluster size, additional space must be used to hold the file (up to the next multiple of the cluster size). On the typical hard disk partition, the average amount of space that is lost in this manner can be calculated by using the equation (cluster size)/2 * (number of files).  
        #In our case, the largest possible size is 64TB so we make 16KB as the default size and based on calculation even there is 1 million files on this disk, the extra wasted size is about 4GB
        Format-Volume -DriveLetter $DiskLetters[$i][0] -FileSystem NTFS -AllocationUnitSize 16384 -NewFileSystemLabel $NewVolumeLabelName -Confirm:$false -Force

        Verify-Volume -TimeOut 20 -DriveLetter $DiskLetters[$i][0]

        $i++
    }
    
    return $true
}


function GenerateVirtualDiskName
{
    $BaseName = 'SQLVMVirtualDisk'
    
    $NewName = $BaseName + ((Get-VirtualDisk | measure).Count + 1 )
    
    return $NewName
}


function GenerateVolumeLabel
{
    $BaseName = 'SQLVMDATA'
    
    $NewName = $BaseName + ((Get-VirtualDisk | measure).Count + 1 )
    
    return $NewName
}


function GenerateStoragePoolName
{
    $BaseName = 'SQLVMStoragePool'

    $NewName = $BaseName + ((Get-VirtualDisk | measure).Count + 1 )

    return $NewName
}


function GetPhysicalDisks
{
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $DeviceID,

        [parameter(Mandatory = $true)]
        [System.Uint32]
        $NumberOfDisks
    )

    $upperDeviceID = $DeviceID + $NumberOfDisks - 1

    $Disks= Get-PhysicalDisk | Where-Object { ([int]$_.DeviceId -ge $DeviceID) -and ([int]$_.DeviceId -le $upperDeviceID) -and ($_.CanPool -eq $true)}

    return $Disks
}


function Verify-NewStoragePool{
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $TimeOut
    )

   $timespan = new-timespan -Seconds $TimeOut

   $sw = [diagnostics.stopwatch]::StartNew()

    while ($sw.elapsed -lt $timespan){
        
    $StoragePool = Get-StoragePool -FriendlyName $NewStoragePoolName -ErrorAction SilentlyContinue

        if ($StoragePool){
            return $true
        }
 
        start-sleep -seconds 1
    }
 
    Write-Error "Unable to find Storage Pool $($NewStoragePoolName) after $($TimeOut)"
}


function Verify-VirtualDisk{
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $TimeOut
    )

   $timespan = new-timespan -Seconds $TimeOut

   $sw = [diagnostics.stopwatch]::StartNew()

    while ($sw.elapsed -lt $timespan){
        
    $VirtualDisk = Get-VirtualDisk -FriendlyName $NewVirtualDiskName -ErrorAction SilentlyContinue

        if ($VirtualDisk){
            return $true
        }
 
        start-sleep -seconds 1
    }
 
    Write-Error "Unable to find Vitrual Disk $($NewVirtualDiskName) after $($TimeOut)"
}

function Verify-Partition{
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $TimeOut,

        [parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter
    )

   $timespan = new-timespan -Seconds $TimeOut

   $sw = [diagnostics.stopwatch]::StartNew()

   while ($sw.elapsed -lt $timespan){
        
   $Partition = Get-partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue

       if ($Partition){
            return $true
       }
 
       start-sleep -seconds 1
    }
 
   Write-Error "Unable to find Partition $($DriveLetter) after $($TimeOut)"
}

function Verify-Volume{
    param
    (
        [parameter(Mandatory = $true)]
        [System.Uint32]
        $TimeOut,

        [parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter
    )

   $timespan = new-timespan -Seconds $TimeOut

   $sw = [diagnostics.stopwatch]::StartNew()

   while ($sw.elapsed -lt $timespan){
        
   $Volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue

       if ($Volume){
            return $true
       }
 
       start-sleep -seconds 1
    }
 
   Write-Error "Unable to find Volume $($DriveLetter) after $($TimeOut)"
}

Export-ModuleMember -Function *-TargetResource
