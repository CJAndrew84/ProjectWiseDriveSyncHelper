[CmdletBinding()]
param(
    [string]$MetadataUrl = 'http://localhost:5000/metadata',
    [string]$ProjectStateFile = '',
    [switch]$OnlyNotSynced
)

$scriptPath = Join-Path $PSScriptRoot 'ATRL_PWDriveProjectSelector.ps1'
. $scriptPath

$projects = @(Get-ATRLConnectedCloudProjects -MetadataUrl $MetadataUrl -ProjectStateFile $ProjectStateFile)
if ($OnlyNotSynced) {
    $projects = @($projects | Where-Object { -not $_.IsSynced })
}

$projects | Sort-Object DisplayName | Select-Object ProjectId, Name, Number, DisplayName, IsSynced | Format-Table -AutoSize
