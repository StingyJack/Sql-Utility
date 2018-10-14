<#
    This will extract details about locks that were taken for userland objects in a SQL XML trace file and present them 
    as an entire JSON'ed set or as only the interesting records in both JSON and text formats.
    
    Copyright 2018  Andrew Stanton 
#>
$ErrorActionPreference = 'Stop'
$Error.Clear()
Clear-Host

. $PSScriptRoot\Get-SqlSysObjects.ps1
. $PSScriptRoot\Get-SqlAllocUnits.ps1


#the path to the trace xml file
$traceXmlFilePath = "C:\Temp\TraceBeforeChanges.xml"

#this is needed to get the sys.objects and sys.allocation_units to show instead of object id's
$sourceDatabaseConnectionString = "Server=.\SQLEXPRESS;Database=YourDbServer;trusted_connection=yes"

#many columns may be in the trace file, we generally only care about these in the extraction (reduces noise)
$columnsToExtract = @("TextData","TransactionID","SPID","Duration","StartTime","EndTime","ObjectID"  `
                        ,"ObjectID2","Type","BinaryData","ObjectID", "Mode","SPID")

Write-Host "Reading Sql Xml trace file at '$traceXmlFilePath'"
$traceXmlFileContent= [xml](Get-Content -Path $traceXmlFilePath)
$totalEventsCount = $traceXmlFileContent.TraceData.Events.ChildNodes.Count
Write-Host ("Found {0:N0} events" -f $totalEventsCount)

$sysObjects = Get-SqlSysObjects -ConnectionString $sourceDatabaseConnectionString
$allocUnits = Get-SqlAllocUnits -ConnectionString $sourceDatabaseConnectionString

$extractedLockDetails = @()
$skippedEventCount = 0

for($i = 0; $i -lt $totalEventsCount;$i++)
{
    $currentTraceEvent = $traceXmlFileContent.TraceData.Events.ChildNodes[$i]

    if ($currentTraceEvent.name -ieq "Trace Start" `
        -or $currentTraceEvent.name -ieq "Trace Stop" `
        -or $currentTraceEvent.name -ieq "Trace Pause")
    {
        $skippedEventCount++
        Write-Host "Skipping $($currentTraceEvent.name) event" -ForegroundColor DarkYellow
        continue
    }

    $props = @{EventName=$currentTraceEvent.name;EventID=$currentTraceEvent.id}

    for($j = 0; $j -lt $currentTraceEvent.ChildNodes.Count;$j++)
    {
        $currentTraceEventColumn = $currentTraceEvent.ChildNodes[$j]
        if ($columnsToExtract -icontains $currentTraceEventColumn.name)
        {
            $extractValue = $currentTraceEventColumn.'#text'

            if ($currentTraceEventColumn.name -ieq "Type")
            {
                $extractValue = switch ($extractValue) #sys.syslockinfo.rsc_type
                {
                    "2" { "Database"}
                    "3" { "File"}
                    "4" { "Index"}
                    "5" { "Table"}
                    "6" { "Page"}
                    "7" { "Key"}
                    "8" { "Extent"}
                    "9" { "RowID"}
                    "10" { "Application"}
                }
            }
            if ($currentTraceEventColumn.name -ieq "Mode")
            {
                $extractValue = switch ($extractValue) #sys.syslockinfo.rsc_type
                {
                    "0" { "0 - NULL"}
                    "1" { "1 - Schema Stability"}
                    "2" { "2 - Schema Modification"}
                    "3" { "3 - Shared"}
                    "4" { "4 - Update"}
                    "5" { "5 - Exclusive"}
                    "6" { "6 - Intent Shared"}
                    "7" { "7 - Intent Update"}
                    "8" { "8 - Intent Exclusive"}
                    "15" { "15 - RangeI-N"}
                    default { "$extractValue - Unknown"}
                }
            }
            if ($currentTraceEventColumn.name -ilike "ObjectID*" -and $extractValue -ne "0" )
            {
                $idValue = [long]$extractValue

                if ($idValue -lt 0)
                {
                    $props.Add($currentTraceEventColumn.name + "Name", "#TempObject")
                    $props.Add($currentTraceEventColumn.name + "TypeDesc", "#TempObject")
                }
                if ($idValue -le [int]::MaxValue)
                {
                    if ($sysObjects.ContainsKey($idValue))
                    {
                        $sysObject = $sysObjects[$idValue]
                        $props.Add($currentTraceEventColumn.name + "Name", $sysObject.Name)
                        $props.Add($currentTraceEventColumn.name + "TypeDesc", $sysObject.TypeDesc)
                    }
                    else
                    {
                        Write-Verbose "Could not locate a sysobject for id: $idValue"
                    }
                }
                else 
                {
                    if ($allocUnits.ContainsKey($idValue))
                    {
                        $allocUnitDefs = $allocUnits[$idValue]
                        $allocUnitNameDetail = "ContainerId_$idValue"
                        $allocUnitTypeDetail = @()
                        foreach ($aud in $allocUnitDefs)
                        {
                            $allocUnitTypeDetail += "$($aud.AllocUnitId) - $($aud.TypeDesc)"
                        }
                        $props.Add($currentTraceEventColumn.name + "Name", $allocUnitNameDetail)
                        $props.Add($currentTraceEventColumn.name + "TypeDesc", [string]::Join(",", $allocUnitTypeDetail))
                    }
                }
            } # if ($currentTraceEventColumn.name -ilike "ObjectID*" -and $extractValue -ne "0" )
            if ($currentTraceEventColumn.name -ilike "*Time")
            {
                $extractValue = [Convert]::ToDateTime($extractValue)
            }

            $props.Add($currentTraceEventColumn.name, $extractValue)
        }
    } # next $j
    
    $extractedLockDetails += (New-Object -TypeName PSObject -Property $props)
    Write-Progress -Activity ("Extracting details from {0:N0} events. ({1:N0} skipped)" -f ($totalEventsCount - $skippedEventCount),$skippedEventCount) -PercentComplete (($i / ($totalEventsCount - $skippedEventCount)) * 100) -Status ("Item {0:N0} of {1:N0}" -f $i, ($totalEventsCount - $skippedEventCount))
} # next $i

$extractedLockDetailsPath = [IO.Path]::ChangeExtension($traceXmlFilePath ,"extractedLockDetails.json")
Write-Host ("Writing {0:N0} events to {1}" -f $extractedLockDetails.Count, $extractedLockDetailsPath )
$extractedLockDetails | ConvertTo-Json | Out-File -FilePath ($extractedLockDetailsPath )

$interestingRecordsTextFilePath = [IO.Path]::ChangeExtension($traceXmlFilePath ,"interestingRecords.txt")
$interestingRecordsJsonFilePath = [IO.Path]::ChangeExtension($traceXmlFilePath ,"interestingRecords.json")
$interestingRecords = $extractedLockDetails | Where-Object {$_.ObjectID -ine "0" -and ([string]::IsNullOrWhiteSpace($_.ObjectIdName) -eq $false) -and $_.ObjectIdName -notlike "sys*" `
                                                            -and $_.Mode -ine "2 - Schema Modification" -and $_.Mode -ine "1 - Schema Stability" -and $_.Mode -ine "0 - NULL" `
                                                            -and $_.ObjectIdTypeDesc -ine "SQL_STORED_PROCEDURE"} 

Write-Host ("Processing {0:N0} interesting events" -f $interestingRecords.Count)
$oldestInterestingDate = $interestingRecords | Select-Object -ExpandProperty StartTime | Sort-Object | Select-Object -First 1

$lockDurations = @{}
$recID = 0
foreach($interestingRecord in $interestingRecords)
{
    $recID++
    $msFromZeroTime = $interestingRecord.StartTime.Subtract($oldestInterestingDate).TotalMilliseconds
    $interestingRecord | Add-Member -MemberType NoteProperty -Name MsFromZeroTime -Value $msFromZeroTime
    $interestingRecord | Add-Member -MemberType NoteProperty -Name RecId -Value $recID
    
    if ($interestingRecord.EventName -ieq "Lock:Acquired")
    {
        if ($lockDurations.ContainsKey($interestingRecord.ObjectID) -eq $false)
        {
            $lockDurations.Add($interestingRecord.ObjectID, $interestingRecord)
        }
        $interestingRecord | Add-Member -MemberType NoteProperty -Name LockDuration -Value 0
    }
    elseif ($interestingRecord.EventName -ieq "Lock:Released")
    {
        if ($lockDurations.ContainsKey($interestingRecord.ObjectID))
        {
            $startTime = $lockDurations[$interestingRecord.ObjectID].StartTime 
            $endTime = $interestingRecord.StartTime #EndTime?
            $duration = $endTime.Subtract($startTime).TotalMilliseconds
            $interestingRecord | Add-Member -MemberType NoteProperty -Name LockDuration  -Value $duration
            $lockDurations.Remove($interestingRecord.ObjectID)
        }
    }
    else
    {
        $interestingRecord | Add-Member -MemberType NoteProperty -Name LockDuration  -Value -1
    }


    $interestingRecord | Add-Member -MemberType NoteProperty -Name Objects -Value @()

    if ($interestingRecord.ObjectID -eq $interestingRecord.ObjectID2)
    {
        $interestingRecord | Add-Member -MemberType NoteProperty -Name SimpleObjectID -Value $interestingRecord.ObjectID
        $interestingRecord | Add-Member -MemberType NoteProperty -Name SimpleObjectName -Value $interestingRecord.ObjectIDName
        $interestingRecord | Add-Member -MemberType NoteProperty -Name SimpleObjectTypeDesc -Value $interestingRecord.ObjectIDTypeDesc
    }
    else
    {
        $interestingRecord | Add-Member -MemberType NoteProperty -Name SimpleObjectID -Value -1
        $interestingRecord | Add-Member -MemberType NoteProperty -Name SimpleObjectName -Value "Multiple"
        $interestingRecord | Add-Member -MemberType NoteProperty -Name SimpleObjectTypeDesc -Value "Different"
    }

}

Write-Host ("Writing {0:N0} complete interesting event details to {1}" -f $interestingRecords.Count, $interestingRecordsJsonFilePath)
$interestingRecords | ConvertTo-Json | Out-File $interestingRecordsJsonFilePath

Write-Host ("Writing {0:N0} summarized interesting event details to {1}" -f $interestingRecords.Count, $interestingRecordsTextFilePath)
$interestingRecords | FT -Property RecId,MsFromZeroTime,SPID,EventName,Mode,LockDuration,SimpleObjectId,SimpleObjectName,SimpleObjectTypeDesc | Out-File $interestingRecordsTextFilePath

#write out both the objectID values. Usually there are only one
#$interestingRecords | FT -Property StartTime,SPID,EventName,Mode,LockDuration,ObjectId,ObjectIdName,ObjectIdTypeDesc,ObjectId2,ObjectId2Name,ObjectId2TypeDesc | Out-File $interestingRecordsTextFilePath


Write-Host "Complete" -ForegroundColor Green