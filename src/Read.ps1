function Get-MosyleDevice {
    <#
    .SYNOPSIS
    Lists devices using server-side filters, optionally traversing every page.
    .DESCRIPTION
    Requires OS, either directly or in Options. Filters are sent inside the
    API options object. Duplicate options are rejected, not silently overridden.
    User ID and hostname are return columns, not documented server-side filters.
    .PARAMETER OS
    Required operating system: ios, mac, tvos, or visionos.
    .PARAMETER DeviceUdid
    Device UDIDs to search for.
    .PARAMETER SerialNumber
    Serial numbers to search for.
    .PARAMETER Model
    Model identifiers to search for.
    .PARAMETER OSVersion
    Operating system versions to search for.
    .PARAMETER Tag
    Tags to search for.
    .PARAMETER EnrollDateStart
    Enrollment range start as a Unix timestamp in seconds.
    Must be accompanied by EnrollDateEnd.
    .PARAMETER EnrollDateEnd
    Enrollment range end as a Unix timestamp in seconds.
    .PARAMETER UpdateDateStart
    Update range start as a Unix timestamp in seconds.
    Must be accompanied by UpdateDateEnd.
    .PARAMETER UpdateDateEnd
    Update range end as a Unix timestamp in seconds.
    .PARAMETER Supervised
    Sends an explicit JSON boolean, including false when supplied.
    .PARAMETER OnlyDeviceUdid
    Requests only device UDIDs. Specify -OnlyDeviceUdid or -OnlyDeviceUdid:$false.
    .PARAMETER SpecificColumns
    Device attributes to return, such as serial_number, device_name, or userid.
    .PARAMETER Page
    One-based page number. The API default is 1.
    .PARAMETER PageSize
    Number of records requested per page. The API default is 50.
    .PARAMETER Options
    Alternative API-key-form options. Only documented device-list keys are accepted.
    .PARAMETER Raw
    Returns the full API envelope, including page metadata. With All, emits one envelope per request.
    .PARAMETER All
    Retrieves pages sequentially from page 1 until an empty response.
    Cannot be combined with Page, including page in Options. Retries HTTP 429
    up to five times per page, delaying only after a rate-limit response.
    .EXAMPLE
    Get-MosyleDevice -OS mac -SerialNumber 'SERIAL1', 'SERIAL2'
    .EXAMPLE
    Get-MosyleDevice -OS mac -SpecificColumns device_name,serial_number,userid,HostName -Page 2 -PageSize 50
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ios', 'mac', 'tvos', 'visionos')][string]$OS,
        [ValidateNotNullOrEmpty()][string[]]$DeviceUdid,
        [ValidateNotNullOrEmpty()][string[]]$SerialNumber,
        [ValidateNotNullOrEmpty()][string[]]$Model,
        [ValidateNotNullOrEmpty()][string[]]$OSVersion,
        [ValidateNotNullOrEmpty()][string[]]$Tag,
        [ValidateRange(0, [long]::MaxValue)][long]$EnrollDateStart,
        [ValidateRange(0, [long]::MaxValue)][long]$EnrollDateEnd,
        [ValidateRange(0, [long]::MaxValue)][long]$UpdateDateStart,
        [ValidateRange(0, [long]::MaxValue)][long]$UpdateDateEnd,
        [bool]$Supervised,
        [switch]$OnlyDeviceUdid,
        [ValidateNotNullOrEmpty()][string[]]$SpecificColumns,
        [ValidateRange(1, [int]::MaxValue)][int]$Page,
        [ValidateRange(1, [int]::MaxValue)][int]$PageSize,
        [hashtable]$Options = @{},
        [switch]$All,
        [switch]$Raw
    )
    $map = @{
        OS = 'os'; DeviceUdid = 'deviceudids'; SerialNumber = 'serial_numbers'
        Model = 'models'; OSVersion = 'osversions'; Tag = 'tags'
        EnrollDateStart = 'enrolldate_start'; EnrollDateEnd = 'enrolldate_end'
        UpdateDateStart = 'updatedate_start'; UpdateDateEnd = 'updatedate_end'
        Supervised = 'supervised'; OnlyDeviceUdid = 'only_deviceudid'
        SpecificColumns = 'specific_columns'; Page = 'page'; PageSize = 'page_size'
    }
    $requestOptions = @{}
    foreach ($key in $Options.Keys) {
        if ($key -notin $map.Values) { throw "Unsupported device-list option '$key'. User and hostname fields are return columns, not documented filters." }
        $requestOptions[$key] = $Options[$key]
    }
    foreach ($name in $map.Keys) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $key = $map[$name]
            if ($requestOptions.ContainsKey($key)) { throw "Specify '$key' through either its parameter or -Options, not both." }
            $requestOptions[$key] = $PSBoundParameters[$name]
        }
    }
    if (-not $requestOptions.ContainsKey('os') -or $requestOptions.os -notin @('ios', 'mac', 'tvos', 'visionos')) {
        throw 'A valid OS is required. Specify -OS or -Options @{ os = ... }.'
    }
    $requestOptions.os = $requestOptions.os.ToLowerInvariant()
    foreach ($key in @('deviceudids', 'serial_numbers', 'models', 'osversions', 'tags', 'specific_columns')) {
        if ($requestOptions.ContainsKey($key)) {
            $values = @($requestOptions[$key])
            if ($values.Count -eq 0) { throw "Device-list option '$key' cannot be empty." }
            foreach ($value in $values) {
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                    throw "Device-list option '$key' requires non-empty strings."
                }
            }
            $requestOptions[$key] = $values
        }
    }
    foreach ($key in @('supervised', 'only_deviceudid')) {
        if ($requestOptions.ContainsKey($key)) {
            $value = $requestOptions[$key]
            if ($value -is [System.Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
            if ($value -isnot [bool]) { throw "Device-list option '$key' requires a boolean, not a string." }
            $requestOptions[$key] = $value
        }
    }
    foreach ($key in @('page', 'page_size', 'enrolldate_start', 'enrolldate_end', 'updatedate_start', 'updatedate_end')) {
        if ($requestOptions.ContainsKey($key)) {
            $value = $requestOptions[$key]
            if ($value -isnot [int] -and $value -isnot [long]) { throw "Device-list option '$key' requires an integer." }
            $minimum = 0
            if ($key -in @('page', 'page_size')) { $minimum = 1 }
            if ($value -lt $minimum) { throw "Device-list option '$key' must be at least $minimum." }
        }
    }
    foreach ($prefix in @('enrolldate', 'updatedate')) {
        $start = $prefix + '_start'
        $end = $prefix + '_end'
        if ($requestOptions.ContainsKey($start) -ne $requestOptions.ContainsKey($end)) {
            throw "Device-list options '$start' and '$end' must be supplied together."
        }
        if ($requestOptions.ContainsKey($start) -and $requestOptions[$start] -gt $requestOptions[$end]) {
            throw "Device-list option '$start' must not exceed '$end'."
        }
    }
    if (-not $All) {
        return Get-MosyleList -Endpoint devices -Operation list -Property devices -Options $requestOptions -Raw:$Raw
    }
    if ($requestOptions.ContainsKey('page')) { throw '-All cannot be combined with an explicit page.' }
    $requestOptions.page = 1
    if (-not $requestOptions.ContainsKey('page_size')) { $requestOptions.page_size = 50 }
    while ($true) {
        $result = Invoke-MosyleOperation -Endpoint devices -Operation list `
            -Parameters @{ options = $requestOptions } -RetryRateLimit
        $entries = @($result.response)
        if ($entries.Count -ne 1) { throw 'Mosyle pagination expected exactly one response entry. Inventory may be incomplete.' }
        $entry = $entries[0]
        if ($entry.PSObject.Properties['status'] -and $entry.status -eq 'DEVICES_NOTFOUND') {
            if ($Raw) { $result }
            break
        }
        if (-not $entry.PSObject.Properties['devices'] -or $null -eq $entry.devices -or
            $entry.devices -isnot [array]) {
            throw 'Mosyle pagination response is missing a devices array. Inventory may be incomplete.'
        }
        if ($entry.devices.Count -eq 0) {
            if ($Raw) { $result }
            break
        }
        $returnedPage = 0L
        if (-not $entry.PSObject.Properties['page'] -or
            -not [long]::TryParse([string]$entry.page, [ref]$returnedPage) -or
            $returnedPage -ne $requestOptions.page) {
            throw 'Mosyle returned missing or mismatched page metadata. Inventory may be incomplete.'
        }
        if ($Raw) { $result } else { $entry.devices }
        if ($requestOptions.page -eq [int]::MaxValue) { throw 'Mosyle pagination exceeded the supported page range.' }
        $requestOptions.page++
    }
}

function Get-MosyleUser {
    <#
    .SYNOPSIS
    Lists users with optional server-side filters, optionally traversing every page.
    .DESCRIPTION
    Filters are sent inside the API options object. Duplicate options are rejected,
    not silently overridden.
    .PARAMETER IdUser
    Internal Mosyle user IDs to filter for.
    .PARAMETER Type
    User types to filter for: ADMIN, GROUP_ADMIN, or ENDUSER.
    .PARAMETER Identifier
    User identifiers to filter for.
    .PARAMETER IdUserGroup
    User groups to filter for; returns all users in those groups.
    .PARAMETER Name
    Users with this exact match name.
    .PARAMETER NameLike
    Users with name or identifier like the inputted string.
    .PARAMETER Email
    Email addresses to filter for.
    .PARAMETER ReturnOnlyIds
    Return only user IDs. Specify -ReturnOnlyIds or -ReturnOnlyIds:$false.
    .PARAMETER ReturnCount
    Return only the count of results. Specify -ReturnCount or -ReturnCount:$false.
    .PARAMETER GroupByTypes
    Return counts grouped by user type. Specify -GroupByTypes or -GroupByTypes:$false.
    .PARAMETER AssignedDevices
    Return all devices assigned to each user. Specify -AssignedDevices or -AssignedDevices:$false.
    .PARAMETER Page
    One-based page number. The API default is 1.
    .PARAMETER PageSize
    Number of records requested per page. The API default is 50.
    .PARAMETER Options
    Alternative API-key-form options. Only documented user-list keys are accepted.
    .PARAMETER Raw
    Returns the full API envelope, including page metadata. With All, emits one envelope per request.
    .PARAMETER All
    Retrieves pages sequentially from page 1 until an empty response.
    Cannot be combined with Page, including page in Options. Retries HTTP 429
    up to five times per page, delaying only after a rate-limit response.
    .EXAMPLE
    Get-MosyleUser -Type ENDUSER, ADMIN
    .EXAMPLE
    Get-MosyleUser -NameLike 'Alex' -Page 2 -PageSize 25
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()][int[]]$IdUser,
        [ValidateSet('ADMIN', 'GROUP_ADMIN', 'ENDUSER')][string[]]$Type,
        [ValidateNotNullOrEmpty()][string[]]$Identifier,
        [ValidateNotNullOrEmpty()][int[]]$IdUserGroup,
        [ValidateNotNullOrEmpty()][string[]]$Name,
        [ValidateNotNullOrEmpty()][string]$NameLike,
        [ValidateNotNullOrEmpty()][string[]]$Email,
        [bool]$ReturnOnlyIds,
        [bool]$ReturnCount,
        [bool]$GroupByTypes,
        [bool]$AssignedDevices,
        [ValidateRange(1, [int]::MaxValue)][int]$Page,
        [ValidateRange(1, [int]::MaxValue)][int]$PageSize,
        [hashtable]$Options = @{},
        [switch]$All,
        [switch]$Raw
    )
    $map = @{
        IdUser = 'idusers'; Type = 'types'; Identifier = 'identifiers'
        IdUserGroup = 'idusergroups'; Name = 'names'; NameLike = 'name_like'
        Email = 'emails'; ReturnOnlyIds = 'return_only_ids'; ReturnCount = 'return_count'
        GroupByTypes = 'group_by_types'; AssignedDevices = 'assigned_devices'
        Page = 'page'; PageSize = 'page_size'
    }
    $requestOptions = @{}
    foreach ($key in $Options.Keys) {
        if ($key -notin $map.Values) { throw "Unsupported user-list option '$key'." }
        $requestOptions[$key] = $Options[$key]
    }
    foreach ($parameterName in $map.Keys) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $key = $map[$parameterName]
            if ($requestOptions.ContainsKey($key)) { throw "Specify '$key' through either its parameter or -Options, not both." }
            $requestOptions[$key] = $PSBoundParameters[$parameterName]
        }
    }
    foreach ($key in @('idusers', 'types', 'identifiers', 'idusergroups', 'names', 'emails')) {
        if ($requestOptions.ContainsKey($key)) {
            $values = @($requestOptions[$key])
            if ($values.Count -eq 0) { throw "User-list option '$key' cannot be empty." }
            foreach ($value in $values) {
                if ($key -eq 'idusers' -or $key -eq 'idusergroups') {
                    if ($value -isnot [int]) { throw "User-list option '$key' requires integers." }
                } else {
                    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                        throw "User-list option '$key' requires non-empty strings."
                    }
                }
            }
            $requestOptions[$key] = $values
        }
    }
    foreach ($key in @('return_only_ids', 'return_count', 'group_by_types', 'assigned_devices')) {
        if ($requestOptions.ContainsKey($key)) {
            $value = $requestOptions[$key]
            if ($value -is [System.Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
            if ($value -isnot [bool]) { throw "User-list option '$key' requires a boolean, not a string." }
            $requestOptions[$key] = $value
        }
    }
    foreach ($key in @('page', 'page_size')) {
        if ($requestOptions.ContainsKey($key)) {
            $value = $requestOptions[$key]
            if ($value -isnot [int] -and $value -isnot [long]) { throw "User-list option '$key' requires an integer." }
            if ($value -lt 1) { throw "User-list option '$key' must be at least 1." }
        }
    }
    if (-not $All) {
        return Get-MosyleList -Endpoint users -Operation list_users -Property users -Options $requestOptions -Raw:$Raw
    }
    if ($requestOptions.ContainsKey('page')) { throw '-All cannot be combined with an explicit page.' }
    $requestOptions.page = 1
    if (-not $requestOptions.ContainsKey('page_size')) { $requestOptions.page_size = 50 }
    while ($true) {
        $result = Invoke-MosyleOperation -Endpoint users -Operation list_users `
            -Parameters @{ options = $requestOptions } -RetryRateLimit
        $entries = @($result.response)
        if ($entries.Count -ne 1) { throw 'Mosyle pagination expected exactly one response entry. Inventory may be incomplete.' }
        $entry = $entries[0]
        if ($entry.PSObject.Properties['status'] -and $entry.status -eq 'USERS_NOTFOUND') {
            if ($Raw) { $result }
            break
        }
        if (-not $entry.PSObject.Properties['users'] -or $null -eq $entry.users -or
            $entry.users -isnot [array]) {
            throw 'Mosyle pagination response is missing a users array. Inventory may be incomplete.'
        }
        if ($entry.users.Count -eq 0) {
            if ($Raw) { $result }
            break
        }
        $returnedPage = 0L
        if (-not $entry.PSObject.Properties['page'] -or
            -not [long]::TryParse([string]$entry.page, [ref]$returnedPage) -or
            $returnedPage -ne $requestOptions.page) {
            throw 'Mosyle returned missing or mismatched page metadata. Inventory may be incomplete.'
        }
        if ($Raw) { $result } else { $entry.users }
        if ($requestOptions.page -eq [int]::MaxValue) { throw 'Mosyle pagination exceeded the supported page range.' }
        $requestOptions.page++
    }
}

function Get-MosyleUserDevice {
    <#
    .SYNOPSIS
    Returns full device details for devices assigned to matching users.
    .DESCRIPTION
    Retrieves every matching user page with assigned_devices enabled, then looks
    up the unique assigned UDIDs through Get-MosyleDevice across every device page.
    At least one user filter is required. Without OS, searches all supported OSes.
    Returns unmodified device records, not user records or assignment summaries.
    Missing assignment fields or malformed responses terminate the lookup.
    .PARAMETER IdUser
    Internal Mosyle user IDs.
    .PARAMETER Type
    User types: ADMIN, GROUP_ADMIN, or ENDUSER.
    .PARAMETER Identifier
    Exact user identifiers.
    .PARAMETER IdUserGroup
    Returns devices assigned to users in these user groups.
    .PARAMETER Name
    Exact user names.
    .PARAMETER NameLike
    Partial user name or identifier.
    .PARAMETER Email
    Exact user email addresses.
    .PARAMETER OS
    Device operating systems: ios, mac, tvos, or visionos. Defaults to all four.
    .PARAMETER PageSize
    Records requested per user and device page. Defaults to 50.
    .EXAMPLE
    Get-MosyleUserDevice -Identifier 'example.admin' -OS mac
    .EXAMPLE
    Get-MosyleUserDevice -Type ADMIN -Email 'admin@example.invalid'
    .EXAMPLE
    Get-MosyleUserDevice -IdUserGroup 1000 -OS mac,ios
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()][int[]]$IdUser,
        [ValidateSet('ADMIN', 'GROUP_ADMIN', 'ENDUSER')][string[]]$Type,
        [ValidateNotNullOrEmpty()][string[]]$Identifier,
        [ValidateNotNullOrEmpty()][int[]]$IdUserGroup,
        [ValidateNotNullOrEmpty()][string[]]$Name,
        [ValidateNotNullOrEmpty()][string]$NameLike,
        [ValidateNotNullOrEmpty()][string[]]$Email,
        [ValidateNotNullOrEmpty()][ValidateSet('ios', 'mac', 'tvos', 'visionos')]
        [string[]]$OS = @('ios', 'mac', 'tvos', 'visionos'),
        [ValidateRange(1, [int]::MaxValue)][int]$PageSize = 50
    )
    $userParameters = @{}
    foreach ($parameterName in @('IdUser', 'Type', 'Identifier', 'IdUserGroup', 'Name', 'NameLike', 'Email')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $userParameters[$parameterName] = $PSBoundParameters[$parameterName]
        }
    }
    if ($userParameters.Count -eq 0) { throw 'Specify at least one user filter to retrieve assigned devices.' }
    $udids = [System.Collections.Generic.List[string]]::new()
    $seenAssignments = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Get-MosyleUser @userParameters -AssignedDevices $true -All -PageSize $PageSize | ForEach-Object {
        $user = $_
        if (-not $user.PSObject.Properties['assigned_devices'] -or $user.assigned_devices -isnot [array]) {
            throw 'Mosyle user response is missing an assigned_devices array. Assigned-device inventory may be incomplete.'
        }
        foreach ($assignment in $user.assigned_devices) {
            if ($null -eq $assignment -or -not $assignment.PSObject.Properties['deviceUdId'] -or
                $assignment.deviceUdId -isnot [string] -or [string]::IsNullOrWhiteSpace($assignment.deviceUdId)) {
                throw 'Mosyle assigned_devices entry is missing a valid deviceUdId. Assigned-device inventory may be incomplete.'
            }
            if ($seenAssignments.Add($assignment.deviceUdId)) { $udids.Add($assignment.deviceUdId) }
        }
    }
    if ($udids.Count -eq 0) { return }
    $seenDevices = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($deviceOS in ($OS | Select-Object -Unique)) {
        Get-MosyleDevice -OS $deviceOS -DeviceUdid $udids.ToArray() -All -PageSize $PageSize | ForEach-Object {
            $device = $_
            if (-not $device.PSObject.Properties['deviceudid'] -or $device.deviceudid -isnot [string] -or
                [string]::IsNullOrWhiteSpace($device.deviceudid)) {
                throw 'Mosyle device response is missing a valid deviceudid. Assigned-device inventory may be incomplete.'
            }
            if ($seenDevices.Add($device.deviceudid)) { $device }
        }
    }
}

function Get-MosyleUserGroup {
    <#
    .SYNOPSIS
    Lists user groups with optional server-side filters, optionally traversing every page.
    .DESCRIPTION
    Filters are sent inside the API options object. Duplicate options are rejected,
    not silently overridden.
    .PARAMETER IdUserGroup
    Internal Mosyle user group IDs to filter for.
    .PARAMETER IdUserGroupParent
    Parent user group IDs to filter for; returns all children of these groups.
    .PARAMETER Identifier
    User group identifiers to filter for.
    .PARAMETER NameLike
    User groups with name like the inputted string.
    .PARAMETER ReturnOnlyIds
    Return only user group IDs. Specify -ReturnOnlyIds or -ReturnOnlyIds:$false.
    .PARAMETER ReturnCount
    Return only the count of results. Specify -ReturnCount or -ReturnCount:$false.
    .PARAMETER Page
    One-based page number. The API default is 1.
    .PARAMETER PageSize
    Number of records requested per page. The API default is 50.
    .PARAMETER Options
    Alternative API-key-form options. Only documented user-group-list keys are accepted.
    .PARAMETER Raw
    Returns the full API envelope, including page metadata. With All, emits one envelope per request.
    .PARAMETER All
    Retrieves pages sequentially from page 1 until an empty response.
    Cannot be combined with Page, including page in Options. Retries HTTP 429
    up to five times per page, delaying only after a rate-limit response.
    .EXAMPLE
    Get-MosyleUserGroup -ReturnOnlyIds
    .EXAMPLE
    Get-MosyleUserGroup -NameLike 'Sales' -Page 2
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()][int[]]$IdUserGroup,
        [ValidateNotNullOrEmpty()][int[]]$IdUserGroupParent,
        [ValidateNotNullOrEmpty()][string[]]$Identifier,
        [ValidateNotNullOrEmpty()][string]$NameLike,
        [bool]$ReturnOnlyIds,
        [bool]$ReturnCount,
        [ValidateRange(1, [int]::MaxValue)][int]$Page,
        [ValidateRange(1, [int]::MaxValue)][int]$PageSize,
        [hashtable]$Options = @{},
        [switch]$All,
        [switch]$Raw
    )
    $map = @{
        IdUserGroup = 'idusergroups'; IdUserGroupParent = 'idusergroups_parent'
        Identifier = 'identifiers'; NameLike = 'name_like'
        ReturnOnlyIds = 'return_only_ids'; ReturnCount = 'return_count'
        Page = 'page'; PageSize = 'page_size'
    }
    $requestOptions = @{}
    foreach ($key in $Options.Keys) {
        if ($key -notin $map.Values) { throw "Unsupported user-group-list option '$key'." }
        $requestOptions[$key] = $Options[$key]
    }
    foreach ($name in $map.Keys) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $key = $map[$name]
            if ($requestOptions.ContainsKey($key)) { throw "Specify '$key' through either its parameter or -Options, not both." }
            $requestOptions[$key] = $PSBoundParameters[$name]
        }
    }
    foreach ($key in @('idusergroups', 'idusergroups_parent', 'identifiers')) {
        if ($requestOptions.ContainsKey($key)) {
            $values = @($requestOptions[$key])
            if ($values.Count -eq 0) { throw "User-group-list option '$key' cannot be empty." }
            foreach ($value in $values) {
                if ($key -in @('idusergroups', 'idusergroups_parent')) {
                    if ($value -isnot [int]) { throw "User-group-list option '$key' requires integers." }
                } else {
                    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                        throw "User-group-list option '$key' requires non-empty strings."
                    }
                }
            }
            $requestOptions[$key] = $values
        }
    }
    foreach ($key in @('return_only_ids', 'return_count')) {
        if ($requestOptions.ContainsKey($key)) {
            $value = $requestOptions[$key]
            if ($value -is [System.Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
            if ($value -isnot [bool]) { throw "User-group-list option '$key' requires a boolean, not a string." }
            $requestOptions[$key] = $value
        }
    }
    foreach ($key in @('page', 'page_size')) {
        if ($requestOptions.ContainsKey($key)) {
            $value = $requestOptions[$key]
            if ($value -isnot [int] -and $value -isnot [long]) { throw "User-group-list option '$key' requires an integer." }
            if ($value -lt 1) { throw "User-group-list option '$key' must be at least 1." }
        }
    }
    if (-not $All) {
        return Get-MosyleList -Endpoint usergroups -Operation list_usergroup -Property usergroups -Options $requestOptions -Raw:$Raw
    }
    if ($requestOptions.ContainsKey('page')) { throw '-All cannot be combined with an explicit page.' }
    $requestOptions.page = 1
    if (-not $requestOptions.ContainsKey('page_size')) { $requestOptions.page_size = 50 }
    while ($true) {
        $result = Invoke-MosyleOperation -Endpoint usergroups -Operation list_usergroup `
            -Parameters @{ options = $requestOptions } -RetryRateLimit
        $entries = @($result.response)
        if ($entries.Count -ne 1) { throw 'Mosyle pagination expected exactly one response entry. Inventory may be incomplete.' }
        $entry = $entries[0]
        if ($entry.PSObject.Properties['status'] -and $entry.status -eq 'USERGROUP_NOTFOUND') {
            if ($Raw) { $result }
            break
        }
        if (-not $entry.PSObject.Properties['usergroups'] -or $null -eq $entry.usergroups -or
            $entry.usergroups -isnot [array]) {
            throw 'Mosyle pagination response is missing a usergroups array. Inventory may be incomplete.'
        }
        if ($entry.usergroups.Count -eq 0) {
            if ($Raw) { $result }
            break
        }
        $returnedPage = 0L
        if (-not $entry.PSObject.Properties['page'] -or
            -not [long]::TryParse([string]$entry.page, [ref]$returnedPage) -or
            $returnedPage -ne $requestOptions.page) {
            throw 'Mosyle returned missing or mismatched page metadata. Inventory may be incomplete.'
        }
        if ($Raw) { $result } else { $entry.usergroups }
        if ($requestOptions.page -eq [int]::MaxValue) { throw 'Mosyle pagination exceeded the supported page range.' }
        $requestOptions.page++
    }
}

function Get-MosyleDeviceGroup {
    <#
    .SYNOPSIS
    Lists device groups with optional server-side filters, or retrieves a group's name and UDIDs.
    .DESCRIPTION
    When listing device groups, filters are sent inside the API options object.
    Duplicate options are rejected, not silently overridden. The OS parameter is required
    when listing device groups. When retrieving group info by ID, no filters apply.
    .PARAMETER Id
    Retrieves get_info for this device group instead of listing groups.
    .PARAMETER OS
    Required operating system: ios, mac, tvos, or visionos.
    .PARAMETER Page
    One-based page number. The API default is 1.
    .PARAMETER IsSecurityGroup
    Include security groups in results. 0 (default) lists only non-security groups;
    1 lists all device groups including security groups.
    .PARAMETER SecurityComplianceStatus
    Filter by security compliance status: 'noncompliant' or 'compliant'.
    .PARAMETER PageSize
    Number of records requested per page. The API default is 50.
    .PARAMETER SerialNumber
    Serial numbers to filter for.
    .PARAMETER Model
    Model identifiers to filter for.
    .PARAMETER OSVersion
    Operating system versions to filter for.
    .PARAMETER Tag
    Tags to filter for.
    .PARAMETER EnrollDateStart
    Enrollment range start as a Unix timestamp in seconds.
    Must be accompanied by EnrollDateEnd.
    .PARAMETER EnrollDateEnd
    Enrollment range end as a Unix timestamp in seconds.
    .PARAMETER UpdateDateStart
    Update range start as a Unix timestamp in seconds.
    Must be accompanied by UpdateDateEnd.
    .PARAMETER UpdateDateEnd
    Update range end as a Unix timestamp in seconds.
    .PARAMETER Supervised
    Only supervised devices. Specify -Supervised or -Supervised:$false.
    .PARAMETER OnlyDeviceUdid
    Requests only device UDIDs. Specify -OnlyDeviceUdid or -OnlyDeviceUdid:$false.
    .PARAMETER SpecificColumns
    Device attributes to return, such as serial_number, device_name, or userid.
    .PARAMETER Options
    Alternative API-key-form options. Only documented device-group-list keys are accepted.
    .PARAMETER Raw
    Returns the full API envelope, including page metadata. With All, emits one envelope per request.
    .PARAMETER All
    Retrieves pages sequentially from page 1 until an empty response.
    Cannot be combined with Page, including page in Options. Retries HTTP 429
    up to five times per page, delaying only after a rate-limit response.
    .EXAMPLE
    Get-MosyleDeviceGroup -OS mac
    .EXAMPLE
    Get-MosyleDeviceGroup -OS ios -IsSecurityGroup 1 -SecurityComplianceStatus compliant
    .EXAMPLE
    Get-MosyleDeviceGroup -Id '154'
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Info')][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(ParameterSetName = 'List')][ValidateSet('ios', 'mac', 'tvos', 'visionos')][string]$OS,
        [Parameter(ParameterSetName = 'List')][ValidateRange(0, [int]::MaxValue)][int]$IsSecurityGroup,
        [Parameter(ParameterSetName = 'List')][ValidateSet('noncompliant', 'compliant')][string]$SecurityComplianceStatus,
        [Parameter(ParameterSetName = 'List')][ValidateRange(1, [int]::MaxValue)][int]$Page,
        [Parameter(ParameterSetName = 'List')][ValidateRange(1, [int]::MaxValue)][int]$PageSize,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$SerialNumber,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$Model,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$OSVersion,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$Tag,
        [Parameter(ParameterSetName = 'List')][ValidateRange(0, [long]::MaxValue)][long]$EnrollDateStart,
        [Parameter(ParameterSetName = 'List')][ValidateRange(0, [long]::MaxValue)][long]$EnrollDateEnd,
        [Parameter(ParameterSetName = 'List')][ValidateRange(0, [long]::MaxValue)][long]$UpdateDateStart,
        [Parameter(ParameterSetName = 'List')][ValidateRange(0, [long]::MaxValue)][long]$UpdateDateEnd,
        [Parameter(ParameterSetName = 'List')][bool]$Supervised,
        [Parameter(ParameterSetName = 'List')][switch]$OnlyDeviceUdid,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$SpecificColumns,
        [Parameter(ParameterSetName = 'List')][hashtable]$Options = @{},
        [switch]$All,
        [switch]$Raw
    )
    if ($PSCmdlet.ParameterSetName -eq 'Info') {
        $result = Invoke-MosyleOperation -Endpoint devicegroups -Operation get_info -Parameters @{ options = @{ iddevicegroup = $Id } }
        if ($Raw) { return $result }
        foreach ($entry in @($result.response)) {
            if (-not $entry.PSObject.Properties['devicegroup']) { throw 'Mosyle response is missing devicegroup.' }
            $entry.devicegroup
        }
    }
    else {
        $map = @{
            OS = 'os'; IsSecurityGroup = 'is_security_group'; SecurityComplianceStatus = 'security_compliance_status'
            Page = 'page'; PageSize = 'page_size'; SerialNumber = 'serial_numbers'
            Model = 'models'; OSVersion = 'osversions'; Tag = 'tags'
            EnrollDateStart = 'enrolldate_start'; EnrollDateEnd = 'enrolldate_end'
            UpdateDateStart = 'updatedate_start'; UpdateDateEnd = 'updatedate_end'
            Supervised = 'supervised'; OnlyDeviceUdid = 'only_deviceudid'
            SpecificColumns = 'specific_columns'
        }
        $requestOptions = @{}
        foreach ($key in $Options.Keys) {
            if ($key -notin $map.Values) { throw "Unsupported device-group-list option '$key'." }
            $requestOptions[$key] = $Options[$key]
        }
        foreach ($name in $map.Keys) {
            if ($PSBoundParameters.ContainsKey($name)) {
                $key = $map[$name]
                if ($requestOptions.ContainsKey($key)) { throw "Specify '$key' through either its parameter or -Options, not both." }
                $requestOptions[$key] = $PSBoundParameters[$name]
            }
        }
        if (-not $requestOptions.ContainsKey('os') -or $requestOptions.os -notin @('ios', 'mac', 'tvos', 'visionos')) {
            throw 'A valid OS is required. Specify -OS or -Options @{ os = ... }.'
        }
        $requestOptions.os = $requestOptions.os.ToLowerInvariant()
        foreach ($key in @('serial_numbers', 'models', 'osversions', 'tags', 'specific_columns')) {
            if ($requestOptions.ContainsKey($key)) {
                $values = @($requestOptions[$key])
                if ($values.Count -eq 0) { throw "Device-group-list option '$key' cannot be empty." }
                foreach ($value in $values) {
                    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                        throw "Device-group-list option '$key' requires non-empty strings."
                    }
                }
                $requestOptions[$key] = $values
            }
        }
        foreach ($key in @('is_security_group', 'supervised', 'only_deviceudid')) {
            if ($requestOptions.ContainsKey($key)) {
                $value = $requestOptions[$key]
                if ($value -is [System.Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
                if ($value -isnot [bool]) { throw "Device-group-list option '$key' requires a boolean, not a string." }
                $requestOptions[$key] = $value
            }
        }
        foreach ($key in @('page', 'page_size', 'enrolldate_start', 'enrolldate_end', 'updatedate_start', 'updatedate_end')) {
            if ($requestOptions.ContainsKey($key)) {
                $value = $requestOptions[$key]
                if ($value -isnot [int] -and $value -isnot [long]) { throw "Device-group-list option '$key' requires an integer." }
                $minimum = 0
                if ($key -in @('page', 'page_size')) { $minimum = 1 }
                if ($value -lt $minimum) { throw "Device-group-list option '$key' must be at least $minimum." }
            }
        }
        foreach ($prefix in @('enrolldate', 'updatedate')) {
            $start = $prefix + '_start'
            $end = $prefix + '_end'
            if ($requestOptions.ContainsKey($start) -ne $requestOptions.ContainsKey($end)) {
                throw "Device-group-list options '$start' and '$end' must be supplied together."
            }
            if ($requestOptions.ContainsKey($start) -and $requestOptions[$start] -gt $requestOptions[$end]) {
                throw "Device-group-list option '$start' must not exceed '$end'."
            }
        }
        if (-not $All) {
            return Get-MosyleList -Endpoint devicegroups -Operation list_devicegroup -Property devicegroups -Options $requestOptions -Raw:$Raw
        }
        if ($requestOptions.ContainsKey('page')) { throw '-All cannot be combined with an explicit page.' }
        $requestOptions.page = 1
        if (-not $requestOptions.ContainsKey('page_size')) { $requestOptions.page_size = 50 }
        while ($true) {
            $result = Invoke-MosyleOperation -Endpoint devicegroups -Operation list_devicegroup `
                -Parameters @{ options = $requestOptions } -RetryRateLimit
            $entries = @($result.response)
            if ($entries.Count -ne 1) { throw 'Mosyle pagination expected exactly one response entry. Inventory may be incomplete.' }
            $entry = $entries[0]
            if ($entry.PSObject.Properties['status'] -and $entry.status -eq 'DEVICEGROUPS_NOTFOUND') {
                if ($Raw) { $result }
                break
            }
            if (-not $entry.PSObject.Properties['devicegroups'] -or $null -eq $entry.devicegroups -or
                $entry.devicegroups -isnot [array]) {
                throw 'Mosyle pagination response is missing a devicegroups array. Inventory may be incomplete.'
            }
            if ($entry.devicegroups.Count -eq 0) {
                if ($Raw) { $result }
                break
            }
            $returnedPage = 0L
            if (-not $entry.PSObject.Properties['page'] -or
                -not [long]::TryParse([string]$entry.page, [ref]$returnedPage) -or
                $returnedPage -ne $requestOptions.page) {
                throw 'Mosyle returned missing or mismatched page metadata. Inventory may be incomplete.'
            }
            if ($Raw) { $result } else { $entry.devicegroups }
            if ($requestOptions.page -eq [int]::MaxValue) { throw 'Mosyle pagination exceeded the supported page range.' }
            $requestOptions.page++
        }
    }
}
