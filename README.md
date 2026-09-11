# ProjectWise Drive Sync Helper

This repository provides a small PowerShell-based helper for discovering ProjectWise cloud projects that are connected to ProjectWise Drive and allowing a user to select and sync them to their local machine.

The solution combines:

- PowerShell logic to query Bentley/ProjectWise project metadata
- a WPF selection window for choosing projects
- a local metadata/sync endpoint contract used by the desktop sync service

It is intended for environments where ProjectWise Drive sync is available and a local service is exposing project metadata and sync endpoints at `http://localhost:5000`.

## What it does

The scripts will:

- query the current user's connected cloud projects
- check whether each project has a work area connection and Drive enabled
- filter out projects that are not eligible for sync
- show a selectable list of valid projects in a desktop window
- submit sync requests for the selected projects
- persist the selected project IDs to a local state file

## Repository files

### `ATRL_PWDriveProjectSelector.ps1`

This is the main script. It contains the core logic for:

- obtaining an OIDC/Bentley token
- enumerating ProjectWise cloud projects from the Bentley API
- detecting whether a project has a Drive-enabled work area connection
- displaying a WPF selection window
- syncing selected projects through the local `SyncProject` endpoint
- saving project selections to a JSON state file

It can be run with or without showing the UI.

### `ATRL_GetConnectedCloudProjects.ps1`

This is a lightweight helper script that lists connected cloud projects and can optionally filter to only projects that are not already synced.

It is useful for quick checks and troubleshooting without launching the full UI.

### `ATRL_PWDriveProjectSelector.xaml`

This is the XAML definition for the WPF window used by the main PowerShell script. It defines the project filter box, selection list, sync button, and controls for selecting and clearing project selections.

## Prerequisites

Before using the scripts, ensure the following are available:

- Windows PowerShell or PowerShell 7+
- access to a Bentley/ProjectWise environment with valid authentication
- the proper Bentley PowerShell modules available in the session, including `Get-OIDCToken`
- a local metadata endpoint available on `http://localhost:5000/metadata`
- a local sync endpoint available on `http://localhost:5000/SyncProject`
- the current user is signed in to ProjectWise so an OIDC token can be acquired

The code specifically looks for token commands such as:

- `Get-OIDCToken`
- `pwps_dab\Get-OIDCToken`

## Configuration

The scripts accept a few parameters:

### `ATRL_PWDriveProjectSelector.ps1`

- `-MetadataUrl` default: `http://localhost:5000/metadata`
- `-ProjectStateFile` optional path to a JSON state file; defaults to `backupPWDProjects.json` in the script folder
- `-ShowWindow` opens the project selector UI

Example:

```powershell
.\ATRL_PWDriveProjectSelector.ps1 -ShowWindow
```

### `ATRL_GetConnectedCloudProjects.ps1`

- `-MetadataUrl` default: `http://localhost:5000/metadata`
- `-ProjectStateFile` optional path to the saved project list
- `-OnlyNotSynced` shows only projects that are not already synced

Examples:

```powershell
.\ATRL_GetConnectedCloudProjects.ps1
.\ATRL_GetConnectedCloudProjects.ps1 -OnlyNotSynced
```

## Typical workflow

1. Sign in to the appropriate Bentley/ProjectWise account.
2. Launch the selector UI:

   ```powershell
   .\ATRL_PWDriveProjectSelector.ps1 -ShowWindow
   ```

3. Review the list of valid connected projects with ProjectWise Drive enabled.
4. Filter or select the projects to sync.
5. Click the sync button.
6. The script submits the selected project IDs to the local sync endpoint and stores them in the local JSON state file.

## Project selection behavior

- Only projects with an active work area connection and Drive-enabled status are included.
- The UI supports selection of up to 80 projects per sync batch.
- The selection state is saved to a JSON file so previously saved projects can be tracked.
- The script flags projects as synced based on metadata returned from the local `metadata` service.

## Notes

- This helper depends on an external metadata/sync service running locally on port 5000.
- If no valid Bentley token is available, the scripts will fail with a clear message instructing the user to sign in or ensure the required PowerShell module is available.
- The sync request is limited to 80 projects at a time by design, matching the Desktop Connector UI constraint.

## License

This project is provided as-is for internal or team use within the ProjectWise Drive sync workflow. Update or extend the script as needed for your environment.
