<#
    SYNOPSIS: Gets the contents of the sys.objects table as a dictionary of (long, PSObject)
        where the key is the object_id and the value is each row transformed

        
    Copyright 2018 Andrew Stanton
#>
function Get-SqlSysObjects
{
    [CmdletBinding()]
    Param(
        [string] $ConnectionString
    )


    $sysObjectsQuery = "SELECT name, object_id, schema_id, parent_object_id, type, type_desc FROM sys.objects"
    $sysObjectsTableRows = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $sysObjectsQuery -OutputAs DataRows

    $returnValue = @{}

    foreach($row in $sysObjectsTableRows)
    {

        $props = @{Name=$row["name"];ObjectId=[long]$row["object_id"];SchemaId=$row["schema_id"];ParentObjectId=$row["parent_object_id"];Type=$row["type"];TypeDesc=$row["type_desc"]}

        $newObj = (New-Object -TypeName PSObject -Property $props)

        $returnValue.Add($newObj.ObjectID, $newObj)

    }
    
    return $returnValue

}