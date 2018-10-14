<#
    SYNOPSIS: Gets the contents of the sys.allocation_units table as a dictionary of (long, PSObject)
        where the key is the container_id and the value is each row transformed


    Copyright 2018 Andrew Stanton
#>
function Get-SqlAllocUnits
{
    [CmdletBinding()]
    Param(
        [string] $ConnectionString
    )


    $allocUnitsQuery = "select allocation_unit_id, type, type_desc, container_id from  sys.allocation_units  "
    $allocUnitsTableRows = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $allocUnitsQuery -OutputAs DataRows

    $returnValue = @{}

    foreach($row in $allocUnitsTableRows)
    {
        $props = @{AllocUnitId=$row["allocation_unit_id"];Type=$row["type"];TypeDesc=$row["type_desc"];ContainerId=$row["container_id"];}

        $newObj = (New-Object -TypeName PSObject -Property $props)

        if ($returnValue.ContainsKey($newObj.ContainerId))
        {
            $returnValue[$newObj.ContainerId] += $newObj
        }
        else
        {
            $allocList = @()
            $allocList += $newObj
            $returnValue.Add($newObj.ContainerId, $allocList)
        }
    }
    
    return $returnValue

}