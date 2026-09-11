[CmdletBinding()]
param(
    [string]$MetadataUrl = 'http://localhost:5000/metadata',
    [string]$ProjectStateFile = '',
    [switch]$ShowWindow
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

function Get-ATRLProjectStateFilePath {
    param([string]$ProjectStateFile)

    if ([string]::IsNullOrWhiteSpace($ProjectStateFile)) {
        return Join-Path $PSScriptRoot 'backupPWDProjects.json'
    }

    return $ProjectStateFile
}

function Test-ATRLDriveEnabled {
    param(
        [Parameter(Mandatory = $false)] $ConnectionInfo
    )

    if ($null -eq $ConnectionInfo) {
        return $false
    }

    $candidateObjects = @()
    if ($ConnectionInfo -is [System.Array]) {
        $candidateObjects = @($ConnectionInfo)
    } else {
        $candidateObjects = @($ConnectionInfo)
    }

    foreach ($candidate in $candidateObjects) {
        if ($null -eq $candidate) {
            continue
        }

        if ($candidate -is [System.Collections.IEnumerable] -and -not ($candidate -is [string])) {
            foreach ($nested in @($candidate)) {
                if (Test-ATRLDriveEnabled -ConnectionInfo $nested) {
                    return $true
                }
            }
            continue
        }

        if ($candidate.PSObject.Properties.Name -contains 'items') {
            $items = @($candidate.items)
            foreach ($item in $items) {
                if (Test-ATRLDriveEnabled -ConnectionInfo $item) {
                    return $true
                }
            }
        }

        $boolPropertyNames = @(
            'driveEnabled', 'DriveEnabled', 'isDriveEnabled', 'IsDriveEnabled',
            'drive', 'Drive', 'isEnabled', 'IsEnabled', 'enabled', 'Enabled',
            'hasDrive', 'HasDrive', 'driveSyncEnabled', 'DriveSyncEnabled',
            'supportsDrive', 'SupportsDrive', 'driveSync', 'DriveSync',
            'isDriveSync', 'IsDriveSync', 'primary', 'Primary'
        )

        foreach ($propertyName in $boolPropertyNames) {
            if ($candidate.PSObject.Properties.Name -contains $propertyName) {
                $value = $candidate.$propertyName
                if ($value -is [bool]) {
                    if ($value) { return $true }
                }
                elseif ($value -is [string]) {
                    if ($value -match '^(true|yes|enabled|on)$') { return $true }
                }
            }
        }

        foreach ($propertyName in @('status', 'Status', 'state', 'State', 'type', 'Type')) {
            if ($candidate.PSObject.Properties.Name -contains $propertyName) {
                $value = [string]$candidate.$propertyName
                if ($value -match 'drive|enabled|connected|pwdi|PWDI') {
                    return $true
                }
            }
        }

        foreach ($propertyName in @('url', 'Url') ) {
            if ($candidate.PSObject.Properties.Name -contains $propertyName) {
                $url = [string]$candidate.$propertyName
                if ($url -match '(/drive/|/pwdrive/|driveEnabled|DriveEnabled|/PWDrive/|/ProjectWiseDrive/|/PW_WSG/|/workarea/|/repositories/)') {
                    return $true
                }
            }
        }
    }

    return $false
}

function Get-ATRLTokenObject {
    [CmdletBinding()]
    param()

    $tokenCandidates = @(
        { Get-Command -Name 'Get-OIDCToken' -ErrorAction SilentlyContinue },
        { Get-Command -Name 'pwps_dab\Get-OIDCToken' -ErrorAction SilentlyContinue }
    )

    foreach ($candidate in $tokenCandidates) {
        $cmd = & $candidate
        if ($null -ne $cmd) {
            try {
                $token = & $cmd.Name -Authority 'https://ims.bentley.com' -UseCacheIfAvailable -ErrorAction Stop
                if ($token -and -not [string]::IsNullOrWhiteSpace($token.access_token)) {
                    return $token
                }
            }
            catch {
                # Fall through to the next token source.
            }
        }
    }

    return $null
}

function Get-ATRLWorkAreaConnections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [object]$OidcToken
    )

    $allConnections = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null

    do {
        $uri = "https://api.bentley.com/workarea/v1/projects/$ProjectId/connections"
        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {
            $uri = "$uri?continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $headers = @{
            Authorization = "Bearer $($OidcToken.access_token)"
            Accept = 'application/json'
        }

        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        }
        catch {
            break
        }

        $items = @()
        if ($response -and $response.items) {
            $items = @($response.items)
        }
        elseif ($response -and $response.value) {
            $items = @($response.value)
        }
        elseif ($response -and $response.connections) {
            $items = @($response.connections)
        }
        elseif ($response -and $response) {
            $items = @($response)
        }

        foreach ($item in $items) {
            if ($null -ne $item) {
                $allConnections.Add($item)
            }
        }

        $continuationToken = $null
        if ($response -and $response.nextPageToken) {
            $continuationToken = [string]$response.nextPageToken
        }
        elseif ($response -and $response.'@odata.nextLink') {
            $nextLink = [string]$response.'@odata.nextLink'
            if (-not [string]::IsNullOrWhiteSpace($nextLink)) {
                $query = [uri]$nextLink
                $continuationToken = $query.Query
                if ($continuationToken.StartsWith('?')) {
                    $continuationToken = $continuationToken.Substring(1)
                }
                if ($continuationToken -match 'continuationToken=([^&]+)') {
                    $continuationToken = $Matches[1]
                }
            }
        }
    } while (-not [string]::IsNullOrWhiteSpace($continuationToken))

    if ($allConnections.Count -eq 0) {
        try {
            $fallback = @(Get-CloudProjectWorkAreaConnections -CloudProjectId $ProjectId -OIDCToken $OidcToken -ErrorAction Stop)
            foreach ($item in $fallback) {
                if ($null -ne $item) {
                    $allConnections.Add($item)
                }
            }
        }
        catch {
            $allConnections = [System.Collections.Generic.List[object]]::new()
        }
    }

    return @($allConnections)
}

function Get-ATRLProjectApiProjects {
    [CmdletBinding()]
    param()

    $oidcToken = Get-ATRLTokenObject
    if ($null -eq $oidcToken) {
        throw 'No Bentley OIDC token command is available in this session. Ensure the correct pwps module is imported and you are signed in.'
    }

    $rawAccessToken = $oidcToken.access_token
    if ([string]::IsNullOrWhiteSpace($rawAccessToken)) {
        $rawAccessToken = $oidcToken
    }

    $allProjects = [System.Collections.Generic.List[object]]::new()
    $nextUri = 'https://api.bentley.com/itwins/?subClass=Project&includeInactive=false'

    do {
        $headers = @{
            Authorization = "Bearer $rawAccessToken"
            'X-Max-Return' = '1000'
            Accept = 'application/vnd.bentley.itwin-platform.v1+json'
            Prefer = 'return=representation'
        }

        $response = Invoke-RestMethod -Uri $nextUri -Headers $headers -Method Get -ErrorAction Stop
        $pageProjects = @()
        if ($response -and $response.itwins) {
            $pageProjects = @($response.itwins)
        }
        elseif ($response -and $response.value) {
            $pageProjects = @($response.value)
        }
        elseif ($response -and $response.items) {
            $pageProjects = @($response.items)
        }

        foreach ($project in $pageProjects) {
            if ($null -ne $project) {
                $allProjects.Add($project)
            }
        }

        $nextUri = $null
        if ($response -and $response.'@odata.nextLink') {
            $nextUri = [string]$response.'@odata.nextLink'
        }
        elseif ($response -and $response.nextLink) {
            $nextUri = [string]$response.nextLink
        }
    } while (-not [string]::IsNullOrWhiteSpace($nextUri))

    $projectList = [System.Collections.Generic.List[object]]::new()
    foreach ($project in @($allProjects)) {
        $projectId = $project.id
        if ([string]::IsNullOrWhiteSpace($projectId)) { continue }

        $workAreaConnection = @()
        try {
            $workAreaConnection = @(Get-ATRLWorkAreaConnections -ProjectId $projectId -OidcToken $oidcToken)
        }
        catch {
            $workAreaConnection = @()
        }

        $hasWorkAreaConnection = ($workAreaConnection.Count -gt 0)
        $driveEnabled = $false
        if ($hasWorkAreaConnection) {
            $driveEnabled = Test-ATRLDriveEnabled -ConnectionInfo $workAreaConnection
        }

        $displayName = $project.displayName
        if (-not [string]::IsNullOrWhiteSpace($project.number)) {
            $displayName = "$($project.displayName) ($($project.number))"
        }

        $projectList.Add([pscustomobject]@{
                ProjectId = $projectId
                Name = $project.displayName
                Number = $project.number
                DisplayName = $displayName
                HasWorkAreaConnection = $hasWorkAreaConnection
                DriveEnabled = $driveEnabled
                WorkAreaConnection = $workAreaConnection
                IsSynced = $false
                IsSaved = $false
            })
    }

    return @($projectList | Sort-Object DisplayName)
}

function Get-ATRLConnectedCloudProjects {
    [CmdletBinding()]
    param(
        [string]$MetadataUrl = 'http://localhost:5000/metadata',
        [string]$ProjectStateFile = ''
    )

    $savedProjectIds = @()
    $stateFile = Get-ATRLProjectStateFilePath -ProjectStateFile $ProjectStateFile
    if (Test-Path -Path $stateFile) {
        try {
            $savedJson = Get-Content -Path $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($savedJson -and $savedJson.projects) {
                $savedProjectIds = @($savedJson.projects)
            }
        }
        catch {
            $savedProjectIds = @()
        }
    }

    $metadata = $null
    try {
        $metadata = Invoke-RestMethod -Uri $MetadataUrl -Method Get -ContentType 'application/json' -ErrorAction Stop
    }
    catch {
        $metadata = $null
    }

    $syncedProjectIds = @()
    if ($metadata -and $metadata.syncedProjects) {
        $syncedProjectIds = @($metadata.syncedProjects)
    }

    $projectList = @(Get-ATRLProjectApiProjects)
    foreach ($project in $projectList) {
        $project.IsSynced = ($syncedProjectIds -contains $project.ProjectId)
        $project.IsSaved = ($savedProjectIds -contains $project.ProjectId)
    }

    return @($projectList | Where-Object { $_.HasWorkAreaConnection -and $_.DriveEnabled } | Sort-Object DisplayName)
}

function Save-ATRLProjectSelection {
    param(
        [string[]]$ProjectIds,
        [string]$ProjectStateFile = ''
    )

    $stateFile = Get-ATRLProjectStateFilePath -ProjectStateFile $ProjectStateFile
    $cleanIds = @($ProjectIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    [pscustomobject]@{
        savedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        projects = @($cleanIds)
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8

    return $cleanIds
}

function Get-ATRLBearerToken {
    $rawToken = $null

    if (Get-Command -Name 'pwps_dab\Get-OIDCToken' -ErrorAction SilentlyContinue) {
        try {
            $rawToken = pwps_dab\Get-OIDCToken -UseCacheIfAvailable -UnattendedMode -PreserveRegistryValues -ErrorAction Stop
        }
        catch {
            try {
                $rawToken = pwps_dab\Get-OIDCToken -UseCacheIfAvailable -ErrorAction Stop
            }
            catch {
                $rawToken = pwps_dab\Get-OIDCToken -ErrorAction Stop
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($rawToken)) {
        throw 'No OIDC token was available. Sign in to ProjectWise or supply a valid token source.'
    }

    if (Get-Command -Name ConvertTo-EncodedToken -ErrorAction SilentlyContinue) {
        return "Bearer $(ConvertTo-EncodedToken $rawToken)"
    }

    return "Bearer $rawToken"
}

function Sync-ATRLSelectedProjects {
    [CmdletBinding()]
    param(
        [string[]]$ProjectIds,
        [string]$MetadataUrl = 'http://localhost:5000/metadata',
        [string]$ProjectStateFile = ''
    )

    $selection = @($ProjectIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($selection.Count -eq 0) {
        throw 'No project ids were supplied to sync.'
    }
    if ($selection.Count -gt 80) {
        throw 'The Desktop Connector UI only supports up to 80 projects in a single sync batch.'
    }

    $metadata = Invoke-RestMethod -Uri $MetadataUrl -Method Get -ContentType 'application/json' -ErrorAction Stop
    $userId = $metadata.user.id
    $token = Get-ATRLBearerToken

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($projectId in $selection) {
        $payload = [pscustomobject]@{
            ProjectId = $projectId
            UserId = $userId
            ConnectionId = [guid]::NewGuid().ToString()
        } | ConvertTo-Json -Depth 3

        $response = Invoke-RestMethod -Uri 'http://localhost:5000/SyncProject' -Method Post -Headers @{ Authorization = $token; 'Content-Type' = 'application/json' } -Body $payload -ErrorAction Stop
        $results.Add([pscustomobject]@{
                ProjectId = $projectId
                Result = $response
            })
    }

    Save-ATRLProjectSelection -ProjectIds $selection -ProjectStateFile $ProjectStateFile | Out-Null
    return $results
}

function Show-ATRLProjectSelector {
    [CmdletBinding()]
    param(
        [string]$MetadataUrl = 'http://localhost:5000/metadata',
        [string]$ProjectStateFile = ''
    )

    $projects = @(Get-ATRLConnectedCloudProjects -MetadataUrl $MetadataUrl -ProjectStateFile $ProjectStateFile)
    if ($projects.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            'No ProjectWise Drive-enabled cloud projects were found for this account. Check that the account has a valid project connection and Drive enabled on the work area connection.',
            'ProjectWise Drive Sync',
            'OK',
            'Warning') | Out-Null
        return @()
    }

    $xamlPath = Join-Path $PSScriptRoot 'ATRL_PWDriveProjectSelector.xaml'
    if (-not (Test-Path -Path $xamlPath)) {
        throw "Missing XAML file: $xamlPath"
    }

    [xml]$xaml = Get-Content -Path $xamlPath -Raw
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $projectListBox = $window.FindName('ProjectListBox')
    $filterTextBox = $window.FindName('FilterTextBox')
    $selectionCountText = $window.FindName('SelectionCountText')
    $syncButton = $window.FindName('SyncButton')
    $cancelButton = $window.FindName('CancelButton')
    $selectAllButton = $window.FindName('SelectAllButton')
    $clearButton = $window.FindName('ClearButton')
    $refreshButton = $window.FindName('RefreshButton')

    $projectListBox.ItemsSource = $projects
    $projectListBox.DisplayMemberPath = 'DisplayName'

    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($projectListBox.ItemsSource)
    $view.Filter = {
        param($item)
        if ($null -eq $item) { return $false }
        if ([string]::IsNullOrWhiteSpace($filterTextBox.Text)) { return $true }
        return $item.DisplayName -match [regex]::Escape($filterTextBox.Text)
    }

    $updateSelectionCount = {
        $count = $projectListBox.SelectedItems.Count
        $selectionCountText.Text = "$count selected"
        $syncButton.IsEnabled = ($count -gt 0 -and $count -le 80)
    }

    $filterTextBox.Add_TextChanged({
        $view.Refresh()
    })

    $projectListBox.Add_SelectionChanged({
        & $updateSelectionCount
    })

    $selectAllButton.Add_Click({
        $projectListBox.SelectAll()
        & $updateSelectionCount
    })

    $clearButton.Add_Click({
        $projectListBox.SelectedItems.Clear()
        & $updateSelectionCount
    })

    $refreshButton.Add_Click({
        $refreshedProjects = @(Get-ATRLConnectedCloudProjects -MetadataUrl $MetadataUrl -ProjectStateFile $ProjectStateFile)
        $projectListBox.ItemsSource = $refreshedProjects
        $projectListBox.DisplayMemberPath = 'DisplayName'
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($projectListBox.ItemsSource)
        $view.Filter = {
            param($item)
            if ($null -eq $item) { return $false }
            if ([string]::IsNullOrWhiteSpace($filterTextBox.Text)) { return $true }
            return $item.DisplayName -match [regex]::Escape($filterTextBox.Text)
        }
        foreach ($project in $refreshedProjects) {
            if (-not $project.IsSynced) {
                $projectListBox.SelectedItems.Add($project) | Out-Null
            }
        }
        & $updateSelectionCount
    })

    foreach ($project in $projects) {
        if (-not $project.IsSynced) {
            $projectListBox.SelectedItems.Add($project) | Out-Null
        }
    }
    & $updateSelectionCount

    $syncButton.Add_Click({
        $selectedProjects = @($projectListBox.SelectedItems)
        if ($selectedProjects.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Select at least one project to sync.', 'ProjectWise Drive Sync', 'OK', 'Warning') | Out-Null
            return
        }

        if ($selectedProjects.Count -gt 80) {
            [System.Windows.MessageBox]::Show('A maximum of 80 projects can be synced in one batch.', 'ProjectWise Drive Sync', 'OK', 'Warning') | Out-Null
            return
        }

        try {
            $projectIds = @($selectedProjects | ForEach-Object { $_.ProjectId })
            Sync-ATRLSelectedProjects -ProjectIds $projectIds -MetadataUrl $MetadataUrl -ProjectStateFile $ProjectStateFile | Out-Null
            [System.Windows.MessageBox]::Show("Sync request submitted for $($projectIds.Count) project(s).", 'ProjectWise Drive Sync', 'OK', 'Information') | Out-Null
            $window.Close()
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'ProjectWise Drive Sync', 'OK', 'Error') | Out-Null
        }
    })

    $cancelButton.Add_Click({
        $window.Close()
    })

    $window.ShowDialog() | Out-Null
    return $projects
}

if ($ShowWindow -or $MyInvocation.InvocationName -ne '.') {
    Show-ATRLProjectSelector -MetadataUrl $MetadataUrl -ProjectStateFile $ProjectStateFile
}
