@{
    RootModule = 'MosylePS.psm1'
    ModuleVersion = '0.1.0'
    GUID = '7ca89e02-dcf8-476b-adc4-96df4cc75c68'
    Author = 'Sam Price'
    Description = 'PowerShell commands for the Mosyle Business API.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Connect-Mosyle', 'Disconnect-Mosyle', 'Get-MosyleConnection',
        'Get-MosyleDevice', 'Get-MosyleUser', 'Get-MosyleUserGroup', 'Get-MosyleDeviceGroup',
        'Set-MosyleDevice', 'Set-MosyleDeviceUser', 'Restart-MosyleDevice', 'Stop-MosyleDevice',
        'New-MosyleUser', 'Set-MosyleUser', 'New-MosyleUserGroup', 'Set-MosyleUserGroup',
        'Add-MosyleUserGroupMember', 'Remove-MosyleUserGroupMember',
        'Add-MosyleDeviceGroupMember', 'Set-MosyleVariable'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Mosyle', 'MDM', 'macOS', 'Endpoint')
        }
    }
}
