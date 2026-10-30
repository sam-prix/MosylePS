function Connect-Mosyle {
    <#
    .SYNOPSIS
    Configures JWT or legacy Basic authentication for the Mosyle Business API.
    .DESCRIPTION
    JWT is the default for integrations created on or after October 9, 2023.
    Supply a credential to obtain a JWT from /login, or supply an existing bearer
    token. Basic authentication requires a credential and does not call /login.
    Secrets remain in process memory; connection output never contains them.
    .PARAMETER AccessToken
    The integration API access token, not the JWT.
    .PARAMETER Credential
    Credentials of an administrator with the required API permissions.
    .PARAMETER Authentication
    JWT (default) or Basic for integrations created before October 9, 2023.
    .PARAMETER BearerToken
    An existing JWT. No login request is made in this parameter set.
    .PARAMETER BaseUri
    HTTPS API base URI. Defaults to the documented Mosyle Business v1 endpoint.
    .PARAMETER LogPath
    Optional existing-directory log file path. Only operation names and outcomes
    are logged. No credentials, device IDs, user IDs, or payloads are logged.
    .EXAMPLE
    Connect-Mosyle -AccessToken (Read-Host 'API token' -AsSecureString) -Credential (Get-Credential)
    .EXAMPLE
    Connect-Mosyle -AccessToken $apiToken -Credential $credential -Authentication Basic
    .EXAMPLE
    Connect-Mosyle -AccessToken $apiToken -BearerToken $jwt
    #>
    [CmdletBinding(DefaultParameterSetName = 'Credential')]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][securestring]$AccessToken,
        [Parameter(Mandatory, ParameterSetName = 'Credential')][pscredential]$Credential,
        [Parameter(ParameterSetName = 'Credential')][ValidateSet('JWT', 'Basic')][string]$Authentication = 'JWT',
        [Parameter(Mandatory, ParameterSetName = 'Bearer')][ValidateNotNull()][securestring]$BearerToken,
        [ValidateNotNull()][uri]$BaseUri = 'https://businessapi.mosyle.com/v1',
        [ValidateRange(1, 600)][int]$TimeoutSec = 60,
        [string]$LogPath
    )
    # A failed reconnection must not leave the caller operating on a previous tenant.
    $script:Connection = $null
    if (-not $BaseUri.IsAbsoluteUri -or $BaseUri.Scheme -ne 'https' -or
        $BaseUri.UserInfo -or $BaseUri.Query -or $BaseUri.Fragment) {
        throw 'BaseUri must be an absolute HTTPS URI without credentials, query, or fragment.'
    }
    if ($AccessToken.Length -eq 0) { throw 'AccessToken cannot be empty.' }
    if ($LogPath) {
        $LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
        if (-not (Test-Path -LiteralPath (Split-Path $LogPath -Parent) -PathType Container)) {
            throw 'The log directory must already exist and be writable by the current identity.'
        }
    }
    $headers = @{}
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Bearer') {
            $Authentication = 'JWT'
            if ($BearerToken.Length -eq 0) { throw 'BearerToken cannot be empty.' }
            $authorization = $BearerToken.Copy()
        }
        elseif ($Authentication -eq 'Basic') {
            if ($Credential.UserName.Contains(':')) { throw 'Basic authentication usernames cannot contain a colon.' }
            $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
            $encoded = [Convert]::ToBase64String([text.encoding]::UTF8.GetBytes($pair))
            $authorization = ConvertTo-SecureString $encoded -AsPlainText -Force
        }
        else {
            $headers.accessToken = ConvertFrom-MosyleSecret $AccessToken
            $body = @{ email = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
            $response = Send-MosyleHttp -Uri ($BaseUri.AbsoluteUri.TrimEnd('/') + '/login') `
                -Headers $headers -Body $body -TimeoutSec $TimeoutSec
            $token = (@($response.Headers['Authorization']) -join '').Trim()
            $token = $token -replace '^(?i)Bearer\s+', ''
            if ([string]::IsNullOrWhiteSpace($token) -or $token -match '[\r\n]') {
                throw 'Mosyle login did not return a valid Authorization header.'
            }
            $authorization = ConvertTo-SecureString $token -AsPlainText -Force
        }
        $script:Connection = @{
            BaseUri = $BaseUri.AbsoluteUri.TrimEnd('/')
            Authentication = $Authentication
            AccessToken = $AccessToken.Copy()
            Authorization = $authorization
            TimeoutSec = $TimeoutSec
            LogPath = $LogPath
        }
        Write-MosyleLog "Connected authentication=$Authentication"
        Get-MosyleConnection
    }
    catch {
        $script:Connection = $null
        throw
    }
    finally {
        $headers.Clear()
        $body = $null
        $pair = $null
        $encoded = $null
        $token = $null
    }
}

function Disconnect-Mosyle {
    <#
    .SYNOPSIS
    Clears the local connection. Does not revoke tokens at Mosyle.
    #>
    [CmdletBinding()]
    param()
    try { Write-MosyleLog 'Disconnected' }
    finally { $script:Connection = $null }
}

function Get-MosyleConnection {
    <#
    .SYNOPSIS
    Returns non-secret connection configuration, or nothing when disconnected.
    #>
    [CmdletBinding()]
    param()
    if ($script:Connection) {
        [pscustomobject]@{
            PSTypeName = 'MosylePS.Connection'
            BaseUri = $script:Connection.BaseUri
            Authentication = $script:Connection.Authentication
            TimeoutSec = $script:Connection.TimeoutSec
            LogPath = $script:Connection.LogPath
        }
    }
}
