function ConvertFrom-MosyleSecret {
    param([Parameter(Mandatory)][securestring]$Secret)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Write-MosyleLog {
    param([Parameter(Mandatory)][string]$Message)
    Write-Verbose $Message
    if ($script:Connection -and $script:Connection.LogPath) {
        $line = '{0} {1}' -f [datetime]::UtcNow.ToString('o'), $Message
        Add-Content -LiteralPath $script:Connection.LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
}

function Get-MosyleRetryDelay {
    param($Response, [int]$Attempt)
    $header = $null
    if ($Response -and $Response.PSObject.Properties['Headers'] -and $Response.Headers) {
        $headers = $Response.Headers
        if ($headers -is [System.Net.WebHeaderCollection] -or $headers -is [System.Collections.IDictionary]) {
            $header = @($headers['Retry-After']) -join ''
        }
        elseif ($headers.PSObject.Methods['TryGetValues']) {
            $values = $null
            if ($headers.TryGetValues('Retry-After', [ref]$values)) { $header = @($values) -join '' }
        }
    }
    $delay = [math]::Pow(2, $Attempt + 1)
    if (-not [string]::IsNullOrWhiteSpace($header)) {
        $seconds = 0L
        $date = [datetimeoffset]::MinValue
        if ([long]::TryParse($header, [ref]$seconds) -and $seconds -ge 0) {
            $delay = $seconds
        }
        elseif ([datetimeoffset]::TryParse($header, [cultureinfo]::InvariantCulture,
                [globalization.datetimestyles]::AssumeUniversal, [ref]$date)) {
            $delay = [math]::Max(0, [math]::Ceiling(($date - [datetimeoffset]::UtcNow).TotalSeconds))
        }
        else {
            Write-MosyleLog 'Rate limit Retry-After was invalid; using exponential backoff'
        }
    }
    if ($delay -gt 300) {
        throw 'Mosyle rate limit requires waiting more than 300 seconds. Retry later; no early retry was sent.'
    }
    [int]([math]::Max(1, $delay) * 1000 + (Get-Random -Minimum 0 -Maximum 1000))
}

function Send-MosyleHttp {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Body,
        [Parameter(Mandatory)][int]$TimeoutSec,
        [switch]$RetryRateLimit
    )
    $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress -ErrorAction Stop
    for ($attempt = 0; $attempt -le 5; $attempt++) {
        try {
            # A redirect must never forward credentials or an API token to another host.
            return Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -Body ([text.encoding]::UTF8.GetBytes($json)) `
                -ContentType 'application/json; charset=utf-8' -UseBasicParsing -MaximumRedirection 0 `
                -TimeoutSec $TimeoutSec -ErrorAction Stop -Verbose:$false -Debug:$false
        }
        catch {
            # Do not expose HTTP bodies, request headers, or the login password through error records.
            $status = $null
            $response = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $response = $_.Exception.Response
                if ($response.PSObject.Properties['StatusCode']) {
                    $status = [int]$response.StatusCode
                }
            }
            if ($RetryRateLimit -and $status -eq 429 -and $attempt -lt 5) {
                $delay = Get-MosyleRetryDelay -Response $response -Attempt $attempt
                Write-MosyleLog "Rate limited (HTTP 429); retry=$($attempt + 1)/5 delay_ms=$delay"
                Start-Sleep -Milliseconds $delay
                continue
            }
            $message = 'Mosyle HTTP request failed'
            if ($status) { $message += " (HTTP $status)" }
            if ($RetryRateLimit -and $status -eq 429) {
                $message += '. Rate-limit retry budget exhausted (5 retries).'
            }
            else {
                $message += '. Check connectivity, API permissions, credentials, and token validity. No automatic retry was made for this failure.'
            }
            throw [InvalidOperationException]::new($message)
        }
    }
}

function ConvertFrom-MosyleResponse {
    param([Parameter(Mandatory)]$Response, [string[]]$AllowedStatus = @())
    try {
        $result = ConvertFrom-Json -InputObject $Response.Content -ErrorAction Stop
    }
    catch {
        throw [InvalidOperationException]::new('Mosyle returned an invalid JSON response.')
    }
    if ($null -eq $result -or $result -is [array] -or $result -is [string] -or
        -not $result.PSObject.Properties['response']) {
        throw [InvalidOperationException]::new('Mosyle returned an error or an unexpected response envelope.')
    }
    Assert-MosyleStatus $result
    foreach ($entry in @($result.response)) { Assert-MosyleStatus $entry -AllowedStatus $AllowedStatus }
    $result
}

function Assert-MosyleStatus {
    param($Value, [string[]]$AllowedStatus = @())
    if ($null -eq $Value) {
        throw [InvalidOperationException]::new('Mosyle returned an empty response entry.')
    }
    $success = @(
        'OK', 'DEVICE_UPDATED', 'COMMAND_SENT', 'DEVICE_ASSIGNED', 'USER_CREATED',
        'USER_UPDATED', 'USERGROUP_CREATED', 'USERGROUP_UPDATED', 'USERS_ADDED', 'USERS_REMOVED'
    )
    if (($Value.PSObject.Properties['error'] -and $Value.error) -or
        ($Value.PSObject.Properties['status'] -and $Value.status -notin ($success + $AllowedStatus))) {
        throw [InvalidOperationException]::new('Mosyle reported an API error or an unrecognized status. The operation may have partially completed; verify state before retrying.')
    }
}

function Invoke-MosyleOperation {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Parameters = @{},
        [switch]$RetryRateLimit
    )
    $isDeviceList = $Endpoint -eq 'devices' -and $Operation -eq 'list'
    $isUserList = $Endpoint -eq 'users' -and $Operation -eq 'list_users'
    if ($RetryRateLimit -and -not ($isDeviceList -or $isUserList)) {
        throw 'Rate-limit retries are supported only for device-list and user-list reads.'
    }
    if (-not $script:Connection) { throw 'Not connected. Run Connect-Mosyle first.' }
    $headers = @{ accesstoken = ConvertFrom-MosyleSecret $script:Connection.AccessToken }
    if ($script:Connection.Authentication -eq 'Basic') {
        $headers.Authorization = 'Basic ' + (ConvertFrom-MosyleSecret $script:Connection.Authorization)
    }
    else {
        $headers.Authorization = 'Bearer ' + (ConvertFrom-MosyleSecret $script:Connection.Authorization)
    }
    $body = @{ operation = $Operation }
    foreach ($key in $Parameters.Keys) {
        if ($key -eq 'operation') { throw 'The operation field cannot be overridden.' }
        $body[$key] = $Parameters[$key]
    }
    Write-MosyleLog "Request endpoint=$Endpoint operation=$Operation"
    try {
        $response = Send-MosyleHttp -Uri ($script:Connection.BaseUri + '/' + $Endpoint) `
            -Headers $headers -Body $body -TimeoutSec $script:Connection.TimeoutSec -RetryRateLimit:$RetryRateLimit
        $allowedStatus = @()
        if ($isDeviceList) { $allowedStatus = @('DEVICES_NOTFOUND') }
        if ($isUserList) { $allowedStatus = @('USERS_NOTFOUND') }
        $result = ConvertFrom-MosyleResponse $response -AllowedStatus $allowedStatus
        Write-MosyleLog "Success endpoint=$Endpoint operation=$Operation"
        $result
    }
    catch {
        Write-MosyleLog "Failure endpoint=$Endpoint operation=$Operation; verify state before retrying"
        throw
    }
    finally {
        $headers.Clear()
    }
}

function Get-MosyleList {
    param(
        [string]$Endpoint, [string]$Operation, [string]$Property,
        [hashtable]$Options, [switch]$Raw
    )
    $parameters = @{}
    if ($Options -and $Options.Count) { $parameters.options = $Options }
    $result = Invoke-MosyleOperation -Endpoint $Endpoint -Operation $Operation -Parameters $parameters
    if ($Raw) { return $result }
    foreach ($page in @($result.response)) {
        if ($Endpoint -eq 'devices' -and $Operation -eq 'list' -and
            $page.PSObject.Properties['status'] -and $page.status -eq 'DEVICES_NOTFOUND') {
            continue
        }
        if ($Endpoint -eq 'users' -and $Operation -eq 'list_users' -and
            $page.PSObject.Properties['status'] -and $page.status -eq 'USERS_NOTFOUND') {
            continue
        }
        if (-not $page.PSObject.Properties[$Property]) {
            throw "Mosyle response is missing the expected '$Property' collection. Use -Raw to inspect the response."
        }
        $page.$Property
    }
}
