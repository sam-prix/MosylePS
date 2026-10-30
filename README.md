# MosylePS

PowerShell module for the **Mosyle Business v1 API**, based on the repository's
[Postman collection](../../docs/mosyle_API_documentation.json).
Requires Windows PowerShell 5.1 or PowerShell 7+. No runtime dependencies.
This is an initial implementation, not an official Mosyle SDK.

## Import

```powershell
Import-Module .\modules\MosylePS\MosylePS.psd1
Get-Command -Module MosylePS
Get-Help Connect-Mosyle -Full
```

For permanent installation, copy the complete `MosylePS` directory into a
directory on `$env:PSModulePath`, then use `Import-Module MosylePS`.
On macOS, use the equivalent native path to the manifest.

## Configure API access

In Mosyle, go to **Organization > Integrations > Activate New Integration >
Mosyle API Integration > Add new token**. Select Public or Restricted by Server IP
(prefer the latter when your automation has a stable outbound IP).
Grant only the required endpoints, then save the API access token securely.

Create a dedicated administrator limited to API access. It needs API **View**
permission and the relevant **Create** or **Update** permissions for write
operations. The integration token's allowed endpoints must also match the
commands you intend to run. The module does not change permissions.

The **integration API access token** and **JWT bearer token** are different:

| Integration | Authorization |
|---|---|
| Created on or after October 9, 2023 | JWT, obtained with administrator credentials through `/login` |
| Created before October 9, 2023 | Basic, containing base64-encoded administrator email and password |

Both modes send the integration token in the `accesstoken` header.
Login sends it as `accessToken` as shown in the collection; HTTP header names
are case-insensitive.

### JWT login (default)

```powershell
$apiToken = Read-Host 'Mosyle integration API token' -AsSecureString
$credential = Get-Credential -Message 'Mosyle API administrator email and password'
Connect-Mosyle -AccessToken $apiToken -Credential $credential
```

The module posts `email` and `password` to `/login` and reads the JWT from the
response **Authorization header**, not the JSON body. Both a bare token and a
`Bearer ` prefix are accepted.

### Legacy Basic authentication

```powershell
Connect-Mosyle -AccessToken $apiToken -Credential $credential -Authentication Basic
```

No login request is made. The username and password are UTF-8 encoded and sent
as `Authorization: Basic <base64>`. Base64 is not encryption; HTTPS is mandatory.

### Existing JWT

```powershell
$jwt = Read-Host 'JWT only, without the Bearer prefix' -AsSecureString
Connect-Mosyle -AccessToken $apiToken -BearerToken $jwt
```

Existing JWT and Basic connections are configured locally, not validated until
the first API request. `Get-MosyleConnection` reports only non-secret
configuration; it does not prove that the credentials are valid.

Only one connection exists per imported module instance. A reconnect replaces
it, and a failed reconnect clears it to avoid accidentally using the previous
tenant. `Disconnect-Mosyle` clears local state but does not revoke tokens.
JWT expiration is not refreshed automatically: reconnect when it expires.

Secrets are accepted as `SecureString`/`PSCredential` and retained only in
process memory. HTTP necessarily requires temporary plaintext strings;
`SecureString` is not a guarantee against process-memory inspection (and its
protection differs by OS). Never include real secrets in scripts, transcripts,
source control, or command history. For unattended operation, obtain secrets
from an approved vault under the executing identity; prompts are not suitable
for SYSTEM/root jobs. The module does not read `.env` files.

## Inventory

```powershell
Get-MosyleDevice -Options @{
    os = 'mac'
    specific_columns = @('device_name', 'status')
}
Get-MosyleDevice -OS mac -SerialNumber 'SERIAL1', 'SERIAL2'
Get-MosyleDevice -OS ios -DeviceUdid 'UDID1' -Supervised $true
Get-MosyleDevice -OS mac -Model 'Mac14,7' -OSVersion '15.0' -Tag 'Engineering'
Get-MosyleDevice -OS mac -Page 2 -PageSize 100
Get-MosyleUser -Options @{ types = @('ENDUSER'); name_like = 'Alex' }
Get-MosyleUserGroup -Options @{ return_only_ids = $true }
Get-MosyleDeviceGroup -Options @{ os = 'mac' }
Get-MosyleDeviceGroup -Id '154'

# Keep the full envelope and pagination metadata:
$page = Get-MosyleDevice -Options @{ os = 'mac' } -Raw
$page.response
```

By default, list commands emit the records in **one server response**, not the entire
tenant inventory. When device OS is omitted, `Get-MosyleDevice` requests one page
per supported OS instead. `-Raw` returns the unmodified parsed envelope, including
`page`, `page_size`, `rows`, or `rows_count` where supplied.
The additional device-list documentation specifies `page` (default 1) and
`page_size` (default 50). Use `-Page` and `-PageSize` to request a particular
device page. Other list endpoints retain their original `-Options` behavior.

### Retrieve all devices

```powershell
Get-MosyleDevice -OS mac -All
Get-MosyleDevice -OS mac -All -Tag 'Engineering' -PageSize 100
Get-MosyleDevice -SerialNumber 'SERIAL1' -All

# Retrieve full details of devices assigned to matching users:
Get-MosyleUserDevice -Identifier 'jsmith' -OS mac
Get-MosyleUserDevice -Type ADMIN -Email 'admin@example.invalid'
Get-MosyleUserDevice -IdUserGroup 1000 -OS mac,ios
```

`Get-MosyleUserDevice` supports `-IdUser`, `-Type`, `-Identifier`, `-IdUserGroup`,
`-Name`, `-NameLike`, and `-Email`, with the same filtering semantics as
`Get-MosyleUser`. At least one user filter is required. It retrieves all matching
user pages with `assigned_devices = true`, then retrieves all device pages
filtered by those assignments' `deviceUdId` values. Without `-OS`, it searches
`ios`, `mac`, `tvos`, and `visionos`; one or more OS values can narrow the lookup.
`-PageSize` controls both user and device page sizes (default 50).
The command emits full, unmodified device records once per UDID, not user
records. No matching users or empty assignment arrays produce no output and no
device requests. Missing or malformed assignment data raises an error rather
than silently returning incomplete results. If a later device request fails,
previously emitted records may already have been consumed.

`-All` starts at page 1 and preserves the same filters and columns for every
request. It cannot be combined with `-Page` or `page` in `-Options`.
Requests are sequential, with delays only in response to HTTP **429** rate limits.
Traversal stops on an empty devices array or `DEVICES_NOTFOUND`, not on `rows`
or a short page: the documentation does not establish total-count semantics.
This normally requires one final empty-page request.
Non-empty pages must report the requested page number; missing or mismatched
page metadata terminates the operation rather than risking a loop.

`-All` device and user reads (including `Get-MosyleUserDevice`) retry HTTP **429**:
at most **five retries per page**
(six attempts). `Retry-After` seconds and HTTP-date values are honored; absent
or invalid headers use exponential waits of 2, 4, 8, 16, and 32 seconds.
A minimum one-second wait and up to 999 milliseconds of positive jitter avoid
immediate/synchronized retries. Invalid headers are noted in verbose/file logs.
If the server requests a wait longer than 300 seconds, the command terminates
instead of retrying early. This is a conservative client policy, not a claim
about Mosyle's quota; other clients sharing your token/IP can still cause 429s.
Authentication failures, timeouts, other HTTP errors, and API errors are not retried.

`-All -Raw` streams one original envelope per successful page request, including
the terminal empty/not-found envelope. Without `-Raw`, device records stream
as pages arrive. If a later page fails, earlier pipeline records may already
have been consumed; the terminating error means the inventory is incomplete.
Pagination is not a point-in-time snapshot: concurrent device changes may
cause omissions or duplicates.

### Device filters

Device OS is optional: specify `-OS ios|mac|tvos|visionos` or the `os` option
to search one OS. When neither is supplied, the command searches `ios`, `mac`,
`tvos`, and `visionos` sequentially with the same filters. An explicitly invalid
OS is still rejected. `-Page` and `-PageSize` apply to each OS; `-All` traverses
every page independently for each OS. `-Raw` emits each original response
envelope, including empty/not-found responses. A failure stops the search;
records already emitted may represent incomplete results.

| Parameter | API option |
|---|---|
| `-DeviceUdid` | `deviceudids` |
| `-SerialNumber` | `serial_numbers` |
| `-Model` | `models` |
| `-OSVersion` | `osversions` |
| `-Tag` | `tags` |
| `-EnrollDateStart`, `-EnrollDateEnd` | `enrolldate_start`, `enrolldate_end` |
| `-UpdateDateStart`, `-UpdateDateEnd` | `updatedate_start`, `updatedate_end` |
| `-Supervised $true` or `-Supervised $false` | `supervised` |
| `-OnlyDeviceUdid` | `only_deviceudid` |
| `-SpecificColumns` | `specific_columns` |
| `-Page`, `-PageSize` | `page`, `page_size` |

Identifier, model, version, tag, and column parameters accept arrays. Dates are
Unix timestamps in seconds; each start/end pair must be provided together,
with start no later than end. For example:

```powershell
Get-MosyleDevice -OS mac -EnrollDateStart 1704067200 -EnrollDateEnd 1735689600
```

`-Options` remains supported with the documented keys above plus `os`. It can
be combined with distinct typed parameters, but duplicate keys are rejected.
Unknown keys (including `userid` and `HostName`) now fail locally instead of
silently sending unsupported filters. Booleans must be actual `$true`/`$false`,
not quoted strings. Unknown return column names are still validated by Mosyle
and produce a terminating `UNKNOWN_COLUMNS` error.

The documented `DEVICES_NOTFOUND` response produces no records (not an error).
Use `-Raw` to retain that response envelope.

**Assigned user and hostname are return fields, not documented server-side
filters.** Retrieve them using `-SpecificColumns`, then filter the page locally:

```powershell
$devices = @(Get-MosyleDevice -OS mac -SpecificColumns @(
    'device_name', 'serial_number', 'userid', 'HostName', 'LocalHostName'
))
$devices | Where-Object { $_.userid -eq 'jsmith' }
$devices | Where-Object { $_.HostName -eq 'example-mac' }
```

`userid` is the inventory attribute, not necessarily the internal `iduser` used
for assignment. These local searches cover only the requested page. A missing
match does not prove that the user or hostname has no devices in the tenant.

## Write operations

All writes support `-WhatIf` and `-Confirm`. Restart and shutdown have high
confirmation impact and prompt by default. Write commands return the parsed
API envelope so you can examine individual outcomes.

```powershell
Set-MosyleDevice -SerialNumber 'SERIAL' -Tag @('Engineering', 'Mac') -WhatIf
Set-MosyleDeviceUser -SerialNumber 'SERIAL' -UserId '1530' -WhatIf

New-MosyleUser -UserId 'alex.example' -Name 'Alex Example' -WhatIf
Set-MosyleUser -Id '1566' -Name 'Alex Example' -WhatIf
New-MosyleUserGroup -Name 'Engineering' -Identifier 'engineering' -WhatIf
Set-MosyleUserGroup -Id '3300' -Name 'Engineering' -WhatIf
Add-MosyleUserGroupMember -Id '3300' -EndUserId @('1535', '705') -WhatIf
Add-MosyleUserGroupMember -Id '3300' -AdminId '1530' -WhatIf
Remove-MosyleUserGroupMember -Id '3300' -EndUserId '1535' -WhatIf
Add-MosyleDeviceGroupMember -Id '154' -DeviceId 'API-DEVICE-IDENTIFIER' -WhatIf
Set-MosyleVariable -Name 'color' -Value 'red' -WhatIf

Restart-MosyleDevice -DeviceUdid @('UDID1', 'UDID2') -WhatIf
Restart-MosyleDevice -GroupId '122' -WhatIf
Stop-MosyleDevice -GroupId '122' -WhatIf
```

`New-MosyleUser -UserId` is the external `user_id` used during creation.
`Set-MosyleUser -Id` and assignment/group membership user IDs are Mosyle's
internal `iduser` values. Device restart uses **UDIDs**, while device update
and assignment use **serial numbers**.

Do not treat these commands as universally idempotent. Creation is not an
upsert; command dispatch can repeat a restart/shutdown. Read current state
and compare before creating or changing resources. The collection does not
specify tag merge/replacement semantics or the identifier type in device-group
`add`; confirm both in your tenant before making changes.
User-group administrator and end-user additions use separate calls.

## Transport, errors, and logging

- HTTPS and normal certificate validation are required. No certificate bypass.
- Redirects are disabled so credentials cannot be forwarded to another host.
- `-BaseUri` supports another explicitly trusted HTTPS endpoint; the default is
  `https://businessapi.mosyle.com/v1`.
- Requests have a configurable `-TimeoutSec` (default 60, range 1-600).
- No automatic retries except HTTP 429 during `Get-MosyleDevice -All` as
  described above. No automatic token refresh. A timed-out POST
  might already have succeeded; verify state before retrying.
- HTTP errors are sanitized to avoid exposing response bodies or credentials.
  HTTP status is included when available.
- Malformed JSON, unexpected envelopes, API errors, and unknown operation
  statuses are terminating errors. A batch can partially succeed before an
  error; there is no rollback.
- `COMMAND_SENT` means command acceptance, not endpoint execution/completion.
- `-Verbose` emits only operation names and outcomes. Optional `-LogPath`
  appends the same sanitized metadata with UTC timestamps. The directory must
  already exist and be writable; log failures terminate rather than silently
  dropping audit records. A post-request log failure can occur after a change
  succeeded. Rotation/retention is the caller's responsibility.

For Windows automation, provision a suitable restricted directory beneath
`$env:ProgramData` and supply, for example:

```powershell
$logPath = Join-Path $env:ProgramData 'MosylePS\MosylePS.log'
# Provision the parent directory using your deployment process first.
Connect-Mosyle -AccessToken $apiToken -Credential $credential -LogPath $logPath
```

On macOS, use an appropriately permissioned application log directory.
The module never weakens permissions or requires elevation simply to import.

## Deliberate scope limits

This version covers the documented core devices, users, user groups, device
groups, and variable-save operations. It does not expose a generic arbitrary
write endpoint.

Lock, activation lock, and lost-mode operations are not included. In particular,
the collection's `lock_device` request targets `/variables`, an inconsistency
that should be resolved against current Mosyle documentation before adding a
security-sensitive wrapper. Cisco ISE, action logs, deletion, and other
operations without request examples in the supplied collection are not
implemented. Variable save has no response example: an undocumented response
shape fails explicitly instead of being treated as success.

## Offline validation

From the repository root, using Pester 3.4.0 (the installed development tooling,
tested on both Windows PowerShell 5.1 and PowerShell 7):

```powershell
Import-Module Pester -RequiredVersion 3.4.0
$result = Invoke-Pester -Script .\tests\MosylePS.Tests.ps1 -PassThru
if ($result.FailedCount -gt 0) { throw 'MosylePS tests failed.' }
```

Tests mock every HTTP request. They check authentication, request contracts,
response extraction, errors, secret-safe logs, exports, help, and `-WhatIf`.
No tenant credentials are needed. Test a read-only request against a
non-production integration before relying on live behavior; this module has
not been live-validated against your tenant.
