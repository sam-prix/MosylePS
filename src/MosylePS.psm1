Set-StrictMode -Version Latest
$script:Connection = $null

foreach ($file in @('Private.ps1', 'Authentication.ps1', 'Read.ps1', 'Write.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}

$ExecutionContext.SessionState.Module.OnRemove = {
    $script:Connection = $null
}
