function Set-MosyleDevice {
    <#
    .SYNOPSIS
    Updates device tags by serial number. Returns the API response envelope.
    .DESCRIPTION
    Tags are sent as supplied. Verify tenant tag replacement behavior before use.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SerialNumber,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Tag
    )
    if ($PSCmdlet.ShouldProcess($SerialNumber, 'Update Mosyle device tags')) {
        Invoke-MosyleOperation devices update_device @{ serialnumber = $SerialNumber; tags = @($Tag) }
    }
}

function Set-MosyleDeviceUser {
    <#
    .SYNOPSIS
    Assigns a device to a Mosyle internal user ID.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SerialNumber,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserId
    )
    if ($PSCmdlet.ShouldProcess($SerialNumber, 'Assign Mosyle user')) {
        Invoke-MosyleOperation devices assign_device_user @{ assign = @(@{ serialnumber = $SerialNumber; iduser = $UserId }) }
    }
}

function Restart-MosyleDevice {
    <#
    .SYNOPSIS
    Sends a restart command to explicit device UDIDs or device group IDs.
    .DESCRIPTION
    Command acceptance is not evidence that the endpoint has restarted.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Device')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Device')][ValidateNotNullOrEmpty()][string[]]$DeviceUdid,
        [Parameter(Mandatory, ParameterSetName = 'Group')][ValidateNotNullOrEmpty()][string[]]$GroupId
    )
    $parameters = @{}
    if ($PSCmdlet.ParameterSetName -eq 'Device') { $parameters.devices = @($DeviceUdid) }
    else { $parameters.groups = @($GroupId) }
    if ($PSCmdlet.ShouldProcess(($parameters.Values | ForEach-Object { $_ }) -join ', ', 'Send Mosyle restart command')) {
        Invoke-MosyleOperation devices restart_devices $parameters
    }
}

function Stop-MosyleDevice {
    <#
    .SYNOPSIS
    Sends a shutdown command to explicit device group IDs.
    .DESCRIPTION
    Only the group-targeted shutdown payload is documented in the collection.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$GroupId)
    if ($PSCmdlet.ShouldProcess(($GroupId -join ', '), 'Send Mosyle shutdown command')) {
        Invoke-MosyleOperation devices shutdown_devices @{ groups = @($GroupId) }
    }
}

function New-MosyleUser {
    <#
    .SYNOPSIS
    Creates an ENDUSER using the external user_id and display name.
    .DESCRIPTION
    Creation is not an upsert. Check for an existing user before repeating.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )
    if ($PSCmdlet.ShouldProcess($UserId, 'Create Mosyle end user')) {
        Invoke-MosyleOperation users create_user @{ user_id = $UserId; name = $Name; type = 'ENDUSER' }
    }
}

function Set-MosyleUser {
    <#
    .SYNOPSIS
    Updates a user's display name by Mosyle internal iduser.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )
    if ($PSCmdlet.ShouldProcess($Id, 'Update Mosyle user name')) {
        Invoke-MosyleOperation users update_user @{ iduser = $Id; name = $Name }
    }
}

function New-MosyleUserGroup {
    <#
    .SYNOPSIS
    Creates a user group. Check for an existing group before repeating.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identifier
    )
    if ($PSCmdlet.ShouldProcess($Identifier, 'Create Mosyle user group')) {
        Invoke-MosyleOperation usergroups create_usergroup @{ name = $Name; identifier = $Identifier }
    }
}

function Set-MosyleUserGroup {
    <#
    .SYNOPSIS
    Updates a user group's display name.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )
    if ($PSCmdlet.ShouldProcess($Id, 'Update Mosyle user group name')) {
        Invoke-MosyleOperation usergroups update_usergroup @{ idusergroup = $Id; name = $Name }
    }
}

function Add-MosyleUserGroupMember {
    <#
    .SYNOPSIS
    Adds end users or administrators to a user group by internal IDs.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'EndUser')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory, ParameterSetName = 'EndUser')][ValidateNotNullOrEmpty()][string[]]$EndUserId,
        [Parameter(Mandatory, ParameterSetName = 'Admin')][ValidateNotNullOrEmpty()][string[]]$AdminId
    )
    $parameters = @{ idusergroup = $Id }
    if ($PSCmdlet.ParameterSetName -eq 'Admin') { $parameters.admins = @($AdminId) }
    else { $parameters.endusers = @($EndUserId) }
    if ($PSCmdlet.ShouldProcess($Id, 'Add Mosyle user group members')) {
        Invoke-MosyleOperation usergroups insert_users $parameters
    }
}

function Remove-MosyleUserGroupMember {
    <#
    .SYNOPSIS
    Removes end users from a user group by internal IDs.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$EndUserId
    )
    if ($PSCmdlet.ShouldProcess($Id, 'Remove Mosyle user group members')) {
        Invoke-MosyleOperation usergroups remove_users @{ idusergroup = $Id; endusers = @($EndUserId) }
    }
}

function Add-MosyleDeviceGroupMember {
    <#
    .SYNOPSIS
    Adds devices to a device group using the API's add array.
    .DESCRIPTION
    Confirm which device identifier your tenant expects in add before use;
    the supplied collection does not define the example identifier type.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$DeviceId
    )
    if ($PSCmdlet.ShouldProcess($Id, 'Add Mosyle device group members')) {
        Invoke-MosyleOperation devicegroups update_devices @{ iddevicegroup = $Id; add = @($DeviceId) }
    }
}

function Set-MosyleVariable {
    <#
    .SYNOPSIS
    Saves a custom variable by name.
    .DESCRIPTION
    The collection has no response example for this operation. Unexpected
    response shapes fail explicitly; verify saved state before retrying.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if ($PSCmdlet.ShouldProcess($Name, 'Save Mosyle custom variable')) {
        Invoke-MosyleOperation variables save @{ name = $Name; value = $Value }
    }
}
