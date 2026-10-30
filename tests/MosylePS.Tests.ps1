$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\MosylePS.psd1'
Import-Module $modulePath -Force

Describe 'MosylePS manifest and public surface' {
    It 'imports a valid PowerShell 5.1 manifest with only the intended commands' {
        $manifest = Test-ModuleManifest $modulePath
        $manifest.PowerShellVersion.ToString() | Should Be '5.1'
        @(Get-Command -Module MosylePS).Count | Should Be 19
        @(Get-Command -Module MosylePS -Name Send-MosyleHttp -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'provides synopsis help for every exported command' {
        foreach ($command in Get-Command -Module MosylePS) {
            $help = Get-Help $command.Name
            [string]::IsNullOrWhiteSpace($help.Synopsis) | Should Be $false
            $help.Synopsis.Trim() | Should Not Be $command.Name
        }
    }

    It 'exposes ShouldProcess on every write and high-impact confirmation on device commands' {
        foreach ($command in Get-Command -Module MosylePS | Where-Object Verb -in @('Set', 'New', 'Add', 'Remove', 'Restart', 'Stop')) {
            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }
        foreach ($name in @('Restart-MosyleDevice', 'Stop-MosyleDevice')) {
            $binding = (Get-Command $name).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $binding.ConfirmImpact.ToString() | Should Be 'High'
        }
    }
}

InModuleScope MosylePS {
    # Pester 3's Should Throw does not execute scriptblocks correctly on PowerShell 7.
    function Test-MosyleFailure {
        param([scriptblock]$Action)
        try {
            & $Action | Out-Null
            $false
        }
        catch { $true }
    }

    Describe 'Mosyle authentication and HTTP transport' {
        BeforeEach {
            $script:Connection = $null
            $script:LastHttp = $null
            $script:TestHeaders = @{ Authorization = 'Bearer fake.jwt.token' }
            $script:TestContent = '{"UserID":"1234","email":"fake@example.invalid"}'
            $script:ApiToken = ConvertTo-SecureString 'fake-api-token' -AsPlainText -Force
            $script:Jwt = ConvertTo-SecureString 'fake.jwt.token' -AsPlainText -Force
            $script:Credential = New-Object pscredential ('fake@example.invalid', (ConvertTo-SecureString 'fake-password' -AsPlainText -Force))
            Mock Invoke-WebRequest {
                $script:LastHttp = @{
                    Uri = [string]$Uri; Headers = $Headers.Clone()
                    Body = [text.encoding]::UTF8.GetString($Body) | ConvertFrom-Json
                    Method = $Method; MaximumRedirection = $MaximumRedirection; TimeoutSec = $TimeoutSec
                    ContentType = $ContentType
                }
                [pscustomobject]@{ Headers = $script:TestHeaders; Content = $script:TestContent }
            }
        }

        It 'logs in with API token and credential, then reads JWT from the response header' {
            $connection = Connect-Mosyle -AccessToken $script:ApiToken -Credential $script:Credential
            $script:LastHttp.Uri | Should Be 'https://businessapi.mosyle.com/v1/login'
            $script:LastHttp.Headers.accessToken | Should Be 'fake-api-token'
            $script:LastHttp.Headers.ContainsKey('Authorization') | Should Be $false
            $script:LastHttp.Body.email | Should Be 'fake@example.invalid'
            $script:LastHttp.Body.password | Should Be 'fake-password'
            $script:LastHttp.MaximumRedirection | Should Be 0
            $script:LastHttp.Method | Should Be 'Post'
            $connection.Authentication | Should Be 'JWT'
            (ConvertFrom-MosyleSecret $script:Connection.Authorization) | Should Be 'fake.jwt.token'
            ($connection | ConvertTo-Json) | Should Not Match 'fake-api-token|fake-password|fake.jwt.token'
        }

        It 'accepts a bare JWT response header as well as a Bearer prefix' {
            $script:TestHeaders.Authorization = @('fake.jwt.token')
            Connect-Mosyle -AccessToken $script:ApiToken -Credential $script:Credential | Out-Null
            (ConvertFrom-MosyleSecret $script:Connection.Authorization) | Should Be 'fake.jwt.token'
        }

        It 'does not use login for an existing bearer token' {
            Connect-Mosyle -AccessToken $script:ApiToken -BearerToken $script:Jwt | Out-Null
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }

        It 'encodes Basic credentials correctly and sends both authentication headers' {
            Connect-Mosyle -AccessToken $script:ApiToken -Credential $script:Credential -Authentication Basic | Out-Null
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
            $script:TestContent = '{"status":"OK","response":[{"users":[]}]}'
            Get-MosyleUser
            $expected = [Convert]::ToBase64String([text.encoding]::UTF8.GetBytes('fake@example.invalid:fake-password'))
            $script:LastHttp.Headers.Authorization | Should Be "Basic $expected"
            $script:LastHttp.Headers.accesstoken | Should Be 'fake-api-token'
        }

        It 'sends JWT and integration token on API calls and honors connection configuration' {
            Connect-Mosyle -AccessToken $script:ApiToken -BearerToken $script:Jwt `
                -BaseUri 'https://example.invalid/custom/' -TimeoutSec 12 | Out-Null
            $script:TestContent = '{"status":"OK","response":[{"users":[]}]}'
            Get-MosyleUser
            $script:LastHttp.Headers.Authorization | Should Be 'Bearer fake.jwt.token'
            $script:LastHttp.Uri | Should Be 'https://example.invalid/custom/users'
            $script:LastHttp.TimeoutSec | Should Be 12
            $script:LastHttp.ContentType | Should Be 'application/json; charset=utf-8'
        }

        It 'clears a previous connection if reconnection fails' {
            Connect-Mosyle -AccessToken $script:ApiToken -BearerToken $script:Jwt | Out-Null
            $script:TestHeaders = @{}
            (Test-MosyleFailure { Connect-Mosyle -AccessToken $script:ApiToken -Credential $script:Credential }) | Should Be $true
            $script:Connection | Should Be $null
        }

        It 'rejects insecure or ambiguous base URIs before sending credentials' {
            foreach ($uri in @('http://example.invalid/v1', 'https://user:pass@example.invalid/v1', 'https://example.invalid/v1?query=1', 'https://example.invalid/v1#fragment')) {
                (Test-MosyleFailure { Connect-Mosyle -AccessToken $script:ApiToken -BearerToken $script:Jwt -BaseUri $uri }) | Should Be $true
            }
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }

        It 'rejects empty tokens and Basic usernames containing a colon' {
            $empty = New-Object securestring
            (Test-MosyleFailure { Connect-Mosyle -AccessToken $empty -BearerToken $script:Jwt }) | Should Be $true
            (Test-MosyleFailure { Connect-Mosyle -AccessToken $script:ApiToken -BearerToken $empty }) | Should Be $true
            $badCredential = New-Object pscredential ('bad:name', $script:ApiToken)
            (Test-MosyleFailure { Connect-Mosyle -AccessToken $script:ApiToken -Credential $badCredential -Authentication Basic }) | Should Be $true
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }

        It 'sanitizes transport failures and never retries a request' {
            Mock Invoke-WebRequest { throw 'sensitive body fake-password fake-api-token' }
            $message = ''
            try { Connect-Mosyle -AccessToken $script:ApiToken -Credential $script:Credential }
            catch { $message = $_.Exception.Message }
            $message | Should Match 'Mosyle HTTP request failed'
            $message | Should Not Match 'sensitive|fake-password|fake-api-token'
            Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It
        }

        It 'includes HTTP status without retaining the original exception or body' {
            Mock Invoke-WebRequest {
                $exception = New-Object InvalidOperationException 'sensitive-response'
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 })
                throw $exception
            }
            $failure = $null
            try { Connect-Mosyle -AccessToken $script:ApiToken -Credential $script:Credential }
            catch { $failure = $_ }
            $failure.Exception.Message | Should Match 'HTTP 401'
            $failure.Exception.Message | Should Not Match 'sensitive-response'
            $failure.Exception.InnerException | Should Be $null
            Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It
        }

        It 'disconnects locally and rejects subsequent API calls' {
            Connect-Mosyle -AccessToken $script:ApiToken -BearerToken $script:Jwt | Out-Null
            Disconnect-Mosyle
            @(Get-MosyleConnection).Count | Should Be 0
            (Test-MosyleFailure { Get-MosyleDevice -OS mac }) | Should Be $true
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Mosyle all-device pagination and rate limiting' {
        BeforeEach {
            $token = ConvertTo-SecureString 'fake' -AsPlainText -Force
            Connect-Mosyle -AccessToken $token -BearerToken $token | Out-Null
            $script:Pages = @()
            $script:Calls = 0
            $script:ThrottleCount = 0
            $script:FailureStatus = 429
            $script:RetryAfter = '3'
            Mock Start-Sleep {}
            Mock Get-Random { 0 }
            Mock Invoke-WebRequest {
                $script:Calls++
                if ($script:Calls -le $script:ThrottleCount) {
                    $exception = New-Object InvalidOperationException 'secret-http-body'
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{
                        StatusCode = $script:FailureStatus
                        Headers = @{ 'Retry-After' = $script:RetryAfter }
                    })
                    throw $exception
                }
                $request = [text.encoding]::UTF8.GetString($Body) | ConvertFrom-Json
                $script:Pages += $request.options
                $page = $request.options.page
                $devices = @()
                if ($page -le 2) { $devices = @(@{ deviceudid = "UDID$page" }) }
                $content = @{ status = 'OK'; response = @(@{
                    devices = $devices; page = $page; page_size = 50; rows = $devices.Count
                }) } | ConvertTo-Json -Depth 10
                [pscustomobject]@{ Content = $content; Headers = @{} }
            }
        }

        It 'walks all pages including short pages until empty and preserves filters' {
            $options = @{ os = 'mac'; tags = @('Engineering') }
            $devices = @(Get-MosyleDevice -Options $options -All -PageSize 100)
            $devices.Count | Should Be 2
            $devices[0].deviceudid | Should Be 'UDID1'
            $devices[1].deviceudid | Should Be 'UDID2'
            ($script:Pages.page -join ',') | Should Be '1,2,3'
            foreach ($page in $script:Pages) {
                $page.os | Should Be 'mac'
                $page.tags[0] | Should Be 'Engineering'
                $page.page_size | Should Be 100
            }
            $options.ContainsKey('page') | Should Be $false
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        }

        It 'emits an envelope for each request with Raw including the empty terminal page' {
            $envelopes = @(Get-MosyleDevice -OS mac -All -Raw)
            $envelopes.Count | Should Be 3
            $envelopes[0].response[0].page | Should Be 1
            $envelopes[2].response[0].devices.Count | Should Be 0
        }

        It 'handles UDID-only arrays and DEVICES_NOTFOUND termination' {
            Mock Invoke-WebRequest {
                $request = [text.encoding]::UTF8.GetString($Body) | ConvertFrom-Json
                $script:OnlyUdidRequested = $request.options.only_deviceudid
                if ($request.options.page -eq 1) {
                    $content = '{"status":"OK","response":[{"devices":["UDID1"],"page":1}]}'
                }
                else {
                    $content = '{"status":"OK","response":[{"status":"DEVICES_NOTFOUND"}]}'
                }
                [pscustomobject]@{ Content = $content; Headers = @{} }
            }
            $devices = @(Get-MosyleDevice -OS mac -OnlyDeviceUdid -All)
            $devices.Count | Should Be 1
            $devices[0] | Should Be 'UDID1'
            $script:OnlyUdidRequested | Should Be $true
            Assert-MockCalled Invoke-WebRequest -Times 2 -Exactly -Scope It
        }

        It 'rejects explicit start pages and mismatched or missing pagination metadata' {
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -All -Page 1 }) | Should Be $true
            (Test-MosyleFailure { Get-MosyleDevice -Options @{ os = 'mac'; page = 2 } -All }) | Should Be $true
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
            foreach ($content in @(
                '{"status":"OK","response":[{"devices":[{}],"page":2}]}',
                '{"status":"OK","response":[{"devices":[{}]}]}',
                '{"status":"OK","response":[]}',
                '{"status":"OK","response":[{}]}'
            )) {
                $script:BadContent = $content
                Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:BadContent; Headers = @{} } }
                (Test-MosyleFailure { Get-MosyleDevice -OS mac -All }) | Should Be $true
            }
        }

        It 'retries the same page after HTTP 429 using Retry-After seconds' {
            $script:ThrottleCount = 1
            @(Get-MosyleDevice -OS mac -All).Count | Should Be 2
            $script:Calls | Should Be 4
            ($script:Pages.page -join ',') | Should Be '1,2,3'
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Milliseconds -eq 3000 }
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
        }

        It 'parses HTTP-date Retry-After for both Windows and Core HTTP header types' {
            $date = [datetimeoffset]::UtcNow.AddSeconds(60).ToString('r')
            $windowsHeaders = New-Object System.Net.WebHeaderCollection
            $windowsHeaders.Add('Retry-After', $date)
            $delay = Get-MosyleRetryDelay -Response ([pscustomobject]@{ Headers = $windowsHeaders }) -Attempt 0
            ($delay -ge 59000 -and $delay -le 61000) | Should Be $true
            Add-Type -AssemblyName System.Net.Http
            $httpResponse = New-Object System.Net.Http.HttpResponseMessage
            try {
                $httpResponse.Headers.TryAddWithoutValidation('Retry-After', '7') | Out-Null
                (Get-MosyleRetryDelay -Response $httpResponse -Attempt 0) | Should Be 7000
            }
            finally { $httpResponse.Dispose() }
        }

        It 'retries a throttled later page without repeating records from earlier pages' {
            $script:AttemptedPages = @()
            $script:ThrottledSecondPage = $false
            Mock Invoke-WebRequest {
                $request = [text.encoding]::UTF8.GetString($Body) | ConvertFrom-Json
                $page = $request.options.page
                $script:AttemptedPages += $page
                if ($page -eq 2 -and -not $script:ThrottledSecondPage) {
                    $script:ThrottledSecondPage = $true
                    $exception = New-Object InvalidOperationException 'secret-http-body'
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{
                        StatusCode = 429; Headers = @{ 'Retry-After' = '2' }
                    })
                    throw $exception
                }
                $devices = @()
                if ($page -le 2) { $devices = @(@{ deviceudid = "UDID$page" }) }
                [pscustomobject]@{
                    Content = (@{ status = 'OK'; response = @(@{ devices = $devices; page = $page }) } |
                        ConvertTo-Json -Depth 10)
                    Headers = @{}
                }
            }
            $devices = @(Get-MosyleDevice -OS mac -All)
            ($devices.deviceudid -join ',') | Should Be 'UDID1,UDID2'
            ($script:AttemptedPages -join ',') | Should Be '1,2,2,3'
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Milliseconds -eq 2000 }
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
        }

        It 'uses exponential backoff and stops after five retries without exposing HTTP data' {
            $script:ThrottleCount = 100
            $script:RetryAfter = 'invalid'
            $failure = $null
            try { Get-MosyleDevice -OS mac -All } catch { $failure = $_ }
            $failure.Exception.Message | Should Match 'retry budget exhausted'
            $failure.Exception.Message | Should Not Match 'secret-http-body'
            $script:Calls | Should Be 6
            foreach ($expectedDelay in @(2000, 4000, 8000, 16000, 32000)) {
                Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Milliseconds -eq $expectedDelay }
            }
        }

        It 'uses fallback for missing headers and adds bounded positive jitter' {
            $script:RetryAfter = $null
            Mock Get-Random { 999 }
            (Get-MosyleRetryDelay -Response ([pscustomobject]@{ Headers = @{} }) -Attempt 0) | Should Be 2999
            (Get-MosyleRetryDelay -Response ([pscustomobject]@{ Headers = @{ 'Retry-After' = '0' } }) -Attempt 0) | Should Be 1999
        }

        It 'fails rather than retrying before a Retry-After beyond the wait budget' {
            $script:ThrottleCount = 100
            $script:RetryAfter = '301'
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -All }) | Should Be $true
            $script:Calls | Should Be 1
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        }

        It 'does not retry HTTP 401, HTTP 503 or timeouts during All' {
            $script:ThrottleCount = 100
            foreach ($status in @(401, 503)) {
                $script:Calls = 0
                $script:FailureStatus = $status
                (Test-MosyleFailure { Get-MosyleDevice -OS mac -All }) | Should Be $true
                $script:Calls | Should Be 1
            }
            Mock Invoke-WebRequest { throw 'Timeout' }
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -All }) | Should Be $true
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        }

        It 'does not retry single-page reads, writes or authentication on 429' {
            $script:ThrottleCount = 100
            (Test-MosyleFailure { Get-MosyleDevice -OS mac }) | Should Be $true
            (Test-MosyleFailure { Set-MosyleDevice -SerialNumber 'SERIAL' -Tag 'Tag' -Confirm:$false }) | Should Be $true
            $credential = New-Object pscredential ('fake@example.invalid', (ConvertTo-SecureString 'fake' -AsPlainText -Force))
            $token = ConvertTo-SecureString 'fake' -AsPlainText -Force
            (Test-MosyleFailure { Connect-Mosyle -AccessToken $token -Credential $credential }) | Should Be $true
            $script:Calls | Should Be 3
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Mosyle response contracts and safe write operations' {
        BeforeEach {
            $script:Connection = $null
            $apiToken = ConvertTo-SecureString 'fake-api-token' -AsPlainText -Force
            $jwt = ConvertTo-SecureString 'fake.jwt.token' -AsPlainText -Force
            Connect-Mosyle -AccessToken $apiToken -BearerToken $jwt | Out-Null
            $script:LastBody = $null
            $script:LastUri = $null
            $script:TestContent = '{"status":"OK","response":[{"status":"OK"}]}'
            Mock Invoke-WebRequest {
                $script:LastBody = [text.encoding]::UTF8.GetString($Body) | ConvertFrom-Json
                $script:LastUri = [string]$Uri
                [pscustomobject]@{ Headers = @{}; Content = $script:TestContent }
            }
        }

        It 'extracts devices and preserves options without modifying caller data' {
            $script:TestContent = '{"status":"OK","response":[{"devices":[{"device_name":"Mac"}],"rows":1,"page_size":50,"page":1}]}'
            $options = @{ os = 'mac'; specific_columns = @('device_name', 'status') }
            $devices = @(Get-MosyleDevice -Options $options)
            $devices.Count | Should Be 1
            $devices[0].device_name | Should Be 'Mac'
            $script:LastBody.operation | Should Be 'list'
            $script:LastBody.options.os | Should Be 'mac'
            $script:LastBody.options.specific_columns.Count | Should Be 2
            $options.Count | Should Be 2
            (Get-MosyleDevice -OS mac -Raw).response[0].page_size | Should Be 50
        }

        It 'supports users, group IDs and the object-shaped device-group envelope' {
            $script:TestContent = '{"status":"OK","response":[{"users":[{"iduser":"1111"}]}]}'
            (Get-MosyleUser).iduser | Should Be '1111'
            $script:LastBody.operation | Should Be 'list_users'
            $script:TestContent = '{"status":"OK","response":[{"usergroups":[1000,1001]}]}'
            @(Get-MosyleUserGroup -Options @{ return_only_ids = $true }).Count | Should Be 2
            $script:LastBody.operation | Should Be 'list_usergroup'
            $script:TestContent = '{"status":"OK","response":{"devicegroups":[{"id":"dgroup.01"}],"rows_count":1,"page":1}}'
            (Get-MosyleDeviceGroup).id | Should Be 'dgroup.01'
            $script:LastBody.operation | Should Be 'list_devicegroup'
        }

        It 'retrieves device group details with the documented nested options' {
            $script:TestContent = '{"status":"OK","response":{"devicegroup":{"name":"Lab","udids":["UDID1"]}}}'
            (Get-MosyleDeviceGroup -Id '154').name | Should Be 'Lab'
            $script:LastBody.operation | Should Be 'get_info'
            $script:LastBody.options.iddevicegroup | Should Be '154'
            (Get-MosyleDeviceGroup -Id '154' -Raw).status | Should Be 'OK'
        }

        It 'returns an empty result for a valid empty collection' {
            $script:TestContent = '{"status":"OK","response":[{"devices":[]}]}'
            @(Get-MosyleDevice -OS mac).Count | Should Be 0
        }

        It 'rejects malformed, unauthorized, missing and partial-failure envelopes' {
            foreach ($content in @(
                'not json', 'null', '[]', '{"error":"Unauthorized"}',
                '{"status":"ERROR","response":[]}',
                '{"status":"OK","response":[{"status":"COMMAND_SENT"},{"status":"ERROR","info":"sensitive"}]}',
                '{"status":"OK","response":[{"error":"sensitive"}]}',
                '{"status":"OK","response":[null]}',
                '{"status":"OK","response":[{}]}'
            )) {
                $script:TestContent = $content
                (Test-MosyleFailure { Get-MosyleDevice -OS mac }) | Should Be $true
            }
        }

        It 'maps every typed device filter to the documented options and preserves JSON types' {
            $script:TestContent = '{"status":"OK","response":[{"devices":[]}]}'
            Get-MosyleDevice -OS mac -DeviceUdid 'UDID1' -SerialNumber 'SERIAL1', 'SERIAL2' `
                -Model 'Mac14,7' -OSVersion '15.0' -Tag 'Engineering' `
                -EnrollDateStart 0 -EnrollDateEnd 100 -UpdateDateStart 200 -UpdateDateEnd 300 `
                -Supervised $false -OnlyDeviceUdid:$false -SpecificColumns device_name,userid,HostName `
                -Page 2 -PageSize 100
            $script:LastUri | Should Match '/devices$'
            $script:LastBody.operation | Should Be 'list'
            $options = $script:LastBody.options
            $options.os | Should Be 'mac'
            $options.deviceudids[0] | Should Be 'UDID1'
            ($options.deviceudids -is [array]) | Should Be $true
            $options.serial_numbers.Count | Should Be 2
            $options.serial_numbers[1] | Should Be 'SERIAL2'
            $options.models[0] | Should Be 'Mac14,7'
            $options.osversions[0] | Should Be '15.0'
            $options.tags[0] | Should Be 'Engineering'
            $options.enrolldate_start | Should Be 0
            $options.enrolldate_end | Should Be 100
            $options.updatedate_start | Should Be 200
            $options.updatedate_end | Should Be 300
            ($options.supervised -is [bool]) | Should Be $true
            $options.supervised | Should Be $false
            ($options.only_deviceudid -is [bool]) | Should Be $true
            $options.only_deviceudid | Should Be $false
            $options.specific_columns.Count | Should Be 3
            $options.page | Should Be 2
            $options.page_size | Should Be 100
        }

        It 'omits unspecified options and accepts all documented operating systems' {
            $script:TestContent = '{"status":"OK","response":[{"devices":[]}]}'
            foreach ($os in @('ios', 'mac', 'tvos', 'visionos')) {
                Get-MosyleDevice -OS $os
                $script:LastBody.options.os | Should Be $os
                @($script:LastBody.options.PSObject.Properties).Count | Should Be 1
            }
            Get-MosyleDevice -OS mac -OnlyDeviceUdid -Supervised $true
            $script:LastBody.options.only_deviceudid | Should Be $true
            $script:LastBody.options.supervised | Should Be $true
        }

        It 'combines distinct Options with typed parameters without mutating caller data' {
            $script:TestContent = '{"status":"OK","response":[{"devices":[]}]}'
            $options = @{ os = 'mac'; serial_numbers = 'SERIAL'; supervised = $false }
            Get-MosyleDevice -Options $options -Page 3
            $script:LastBody.options.serial_numbers[0] | Should Be 'SERIAL'
            ($script:LastBody.options.serial_numbers -is [array]) | Should Be $true
            $script:LastBody.options.page | Should Be 3
            ($options.serial_numbers -is [string]) | Should Be $true
            $options.Count | Should Be 3
        }

        It 'rejects missing OS, unsupported filters, duplicate keys and invalid option types before HTTP' {
            $invalidOptions = @(
                @{}, @{ os = 'windows' }, @{ os = 'mac'; userid = 'sprice' },
                @{ os = 'mac'; HostName = 'Mac' }, @{ os = 'mac'; serial_numbers = @() },
                @{ os = 'mac'; tags = @('valid', ' ') }, @{ os = 'mac'; supervised = 'false' },
                @{ os = 'mac'; only_deviceudid = 1 }, @{ os = 'mac'; page = 0 },
                @{ os = 'mac'; page_size = 1.5 }, @{ os = 'mac'; page = '2' },
                @{ os = 'mac'; enrolldate_start = 100 },
                @{ os = 'mac'; enrolldate_end = 200 },
                @{ os = 'mac'; updatedate_start = 300; updatedate_end = 200 },
                @{ os = 'mac'; enrolldate_start = -1; enrolldate_end = 200 },
                @{ os = 'mac'; updatedate_start = '100'; updatedate_end = 200 }
            )
            foreach ($options in $invalidOptions) {
                (Test-MosyleFailure { Get-MosyleDevice -Options $options }) | Should Be $true
            }
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -Options @{ os = 'mac' } }) | Should Be $true
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -Page 0 }) | Should Be $true
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -EnrollDateStart 100 }) | Should Be $true
            (Test-MosyleFailure { Get-MosyleDevice -OS mac -UpdateDateStart 300 -UpdateDateEnd 200 }) | Should Be $true
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }

        It 'treats DEVICES_NOTFOUND as empty only for device list and preserves it with Raw' {
            $script:TestContent = '{"status":"OK","response":[{"status":"DEVICES_NOTFOUND","info":"No devices found"}]}'
            @(Get-MosyleDevice -OS mac -SerialNumber 'MISSING').Count | Should Be 0
            (Get-MosyleDevice -OS mac -Raw).response[0].status | Should Be 'DEVICES_NOTFOUND'
            (Test-MosyleFailure { Get-MosyleUser }) | Should Be $true
            (Test-MosyleFailure { Set-MosyleDevice -SerialNumber 'SERIAL' -Tag 'Tag' -Confirm:$false }) | Should Be $true
        }

        It 'keeps documented device-list failure statuses as terminating errors' {
            foreach ($status in @('MISSING_DATA', 'UNKNOWN_COLUMNS')) {
                $script:TestContent = '{"status":"OK","response":[{"status":"' + $status + '"}]}'
                (Test-MosyleFailure { Get-MosyleDevice -OS mac }) | Should Be $true
            }
            Assert-MockCalled Invoke-WebRequest -Times 2 -Exactly -Scope It
        }

        It 'sends the documented tag and assignment payloads as JSON arrays' {
            Set-MosyleDevice -SerialNumber 'SERIAL' -Tag 'Tag1' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'update_device'
            $script:LastBody.serialnumber | Should Be 'SERIAL'
            ($script:LastBody.tags -is [array]) | Should Be $true
            $script:LastBody.tags[0] | Should Be 'Tag1'
            Set-MosyleDeviceUser -SerialNumber 'SERIAL' -UserId '1530' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'assign_device_user'
            ($script:LastBody.assign -is [array]) | Should Be $true
            $script:LastBody.assign[0].iduser | Should Be '1530'
        }

        It 'requires explicit mutually exclusive restart targets and group shutdown targets' {
            Restart-MosyleDevice -DeviceUdid 'UDID1' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'restart_devices'
            $script:LastBody.devices[0] | Should Be 'UDID1'
            Restart-MosyleDevice -GroupId '122' -Confirm:$false | Out-Null
            $script:LastBody.groups[0] | Should Be '122'
            Stop-MosyleDevice -GroupId '122' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'shutdown_devices'
            $script:LastBody.groups[0] | Should Be '122'
            (Test-MosyleFailure { Restart-MosyleDevice -DeviceUdid 'UDID1' -GroupId '122' -Confirm:$false }) | Should Be $true
        }

        It 'distinguishes external user_id for creation from internal iduser for update' {
            New-MosyleUser -UserId 'new.user' -Name 'New User' -Confirm:$false | Out-Null
            $script:LastUri | Should Match '/users$'
            $script:LastBody.operation | Should Be 'create_user'
            $script:LastBody.user_id | Should Be 'new.user'
            $script:LastBody.type | Should Be 'ENDUSER'
            Set-MosyleUser -Id '1566' -Name 'Changed' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'update_user'
            $script:LastBody.iduser | Should Be '1566'
        }

        It 'sends user-group creation, update, and membership contracts' {
            New-MosyleUserGroup -Name 'Group' -Identifier 'group.id' -Confirm:$false | Out-Null
            $script:LastUri | Should Match '/usergroups$'
            $script:LastBody.operation | Should Be 'create_usergroup'
            $script:LastBody.identifier | Should Be 'group.id'
            Set-MosyleUserGroup -Id '3300' -Name 'Changed' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'update_usergroup'
            $script:LastBody.idusergroup | Should Be '3300'
            Add-MosyleUserGroupMember -Id '3300' -EndUserId '1535' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'insert_users'
            $script:LastBody.endusers[0] | Should Be '1535'
            Add-MosyleUserGroupMember -Id '3300' -AdminId '1530' -Confirm:$false | Out-Null
            $script:LastBody.admins[0] | Should Be '1530'
            Remove-MosyleUserGroupMember -Id '3300' -EndUserId '1535' -Confirm:$false | Out-Null
            $script:LastBody.operation | Should Be 'remove_users'
            $script:LastBody.endusers[0] | Should Be '1535'
        }

        It 'sends device-group add and custom-variable contracts' {
            Add-MosyleDeviceGroupMember -Id '154' -DeviceId 'AAAAAAAAAA' -Confirm:$false | Out-Null
            $script:LastUri | Should Match '/devicegroups$'
            $script:LastBody.operation | Should Be 'update_devices'
            $script:LastBody.add[0] | Should Be 'AAAAAAAAAA'
            Set-MosyleVariable -Name 'color' -Value 'red' -Confirm:$false | Out-Null
            $script:LastUri | Should Match '/variables$'
            $script:LastBody.operation | Should Be 'save'
            $script:LastBody.name | Should Be 'color'
            $script:LastBody.value | Should Be 'red'
        }

        It 'does not send any write requests under WhatIf' {
            Set-MosyleDevice -SerialNumber 'SERIAL' -Tag 'Tag1' -WhatIf
            Set-MosyleDeviceUser -SerialNumber 'SERIAL' -UserId '1530' -WhatIf
            Restart-MosyleDevice -DeviceUdid 'UDID1' -WhatIf
            Stop-MosyleDevice -GroupId '122' -WhatIf
            New-MosyleUser -UserId 'user' -Name 'Name' -WhatIf
            Set-MosyleUser -Id '1' -Name 'Name' -WhatIf
            New-MosyleUserGroup -Name 'Group' -Identifier 'group' -WhatIf
            Set-MosyleUserGroup -Id '1' -Name 'Group' -WhatIf
            Add-MosyleUserGroupMember -Id '1' -EndUserId '2' -WhatIf
            Remove-MosyleUserGroupMember -Id '1' -EndUserId '2' -WhatIf
            Add-MosyleDeviceGroupMember -Id '1' -DeviceId '2' -WhatIf
            Set-MosyleVariable -Name 'color' -Value 'red' -WhatIf
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }

        It 'logs only operation metadata and keeps secrets and payloads out of logs' {
            $logPath = Join-Path $TestDrive 'mosyle.log'
            Connect-Mosyle -AccessToken (ConvertTo-SecureString 'secret-api' -AsPlainText -Force) `
                -BearerToken (ConvertTo-SecureString 'secret-jwt' -AsPlainText -Force) -LogPath $logPath | Out-Null
            Set-MosyleVariable -Name 'private-name' -Value 'private-value' -Confirm:$false | Out-Null
            Disconnect-Mosyle
            $log = Get-Content -LiteralPath $logPath -Raw
            $log | Should Match 'Connected authentication=JWT'
            $log | Should Match 'Success endpoint=variables operation=save'
            $log | Should Match 'Disconnected'
            $log | Should Not Match 'secret-api|secret-jwt|private-name|private-value'
        }

        It 'fails before an API call when the configured log cannot be written' {
            Mock Add-Content { throw 'Log destination is not writable.' }
            (Test-MosyleFailure {
                Connect-Mosyle -AccessToken (ConvertTo-SecureString 'api' -AsPlainText -Force) `
                    -BearerToken (ConvertTo-SecureString 'jwt' -AsPlainText -Force) `
                    -LogPath (Join-Path $TestDrive 'blocked.log')
            }) | Should Be $true
            $script:Connection | Should Be $null
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        }
    }
}
