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
    up to five times per page and waits one second between successful pages.
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
        Start-Sleep -Seconds 1
    }
}

function Get-MosyleUser {
    <#
    .SYNOPSIS
    Lists one page of users.
    .PARAMETER Options
    API options, such as types = @('ENDUSER') and name_like.
    .PARAMETER Raw
    Returns the full API envelope, including page metadata.
    .EXAMPLE
    Get-MosyleUser -Options @{ types = @('ENDUSER'); name_like = 'Alex' }
    #>
    [CmdletBinding()]
    param([hashtable]$Options = @{}, [switch]$Raw)
    Get-MosyleList -Endpoint users -Operation list_users -Property users -Options $Options -Raw:$Raw
}

function Get-MosyleUserGroup {
    <#
    .SYNOPSIS
    Lists one page of user groups, or group IDs when requested through Options.
    .PARAMETER Options
    API options, such as return_only_ids = $true.
    .PARAMETER Raw
    Returns the full API envelope, including page metadata.
    .EXAMPLE
    Get-MosyleUserGroup -Options @{ return_only_ids = $true }
    #>
    [CmdletBinding()]
    param([hashtable]$Options = @{}, [switch]$Raw)
    Get-MosyleList -Endpoint usergroups -Operation list_usergroup -Property usergroups -Options $Options -Raw:$Raw
}

function Get-MosyleDeviceGroup {
    <#
    .SYNOPSIS
    Lists device groups or retrieves a group's name and UDIDs.
    .PARAMETER Id
    Retrieves get_info for this device group instead of listing groups.
    .PARAMETER Options
    List options, such as os = 'mac'.
    .PARAMETER Raw
    Returns the full API envelope.
    .EXAMPLE
    Get-MosyleDeviceGroup -Options @{ os = 'mac' }
    .EXAMPLE
    Get-MosyleDeviceGroup -Id '154'
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Info')][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(ParameterSetName = 'List')][hashtable]$Options = @{},
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
        Get-MosyleList -Endpoint devicegroups -Operation list_devicegroup -Property devicegroups -Options $Options -Raw:$Raw
    }
}
