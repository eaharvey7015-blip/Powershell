<#
.SYNOPSIS
    Manages server-specific ADM- security groups in two phases:
    1. PrepAD      - Nests ADM_WINDOWS into each server-specific ADM- group in AD (uses group list CSV).
    2. DeployLocal - Removes ADM_WINDOWS from local Administrators on each server and adds its ADM-<ServerName> group (uses server list CSV).

.DESCRIPTION
    - PrepAD phase ensures ADM_WINDOWS is a nested member of each server-specific ADM- group in Active Directory.
    - DeployLocal phase replaces direct ADM_WINDOWS membership on servers with the corresponding ADM-<ServerName> domain group in local Administrators.
    - Accepts a CSV file as input for each phase (different formats).
    - Creates a log CSV for both phases with status per target.

    PROD servers:
        - Assumes DNS resolution works normally.

    DEV / UAT servers:
        - If server hostnames are NOT in DNS, they must be defined in the local hosts file
          on the machine running the script: C:\Windows\System32\drivers\etc\hosts
        - Entries MUST match exactly the ServerName values in your DeployLocal CSV.
          Example:
              10.50.1.45  DEV-SERVER-01
              10.50.1.46  UAT-SERVER-02
        - This allows Kerberos authentication to work as if the servers were in DNS.
        - No IP addresses should be in the DeployLocal CSV; only hostnames that resolve via hosts file or DNS.

.PARAMETER PrepAD
    Runs the Active Directory preparation phase.
    CSV must have a column "GroupName" with the server-specific groups to update.

.PARAMETER DeployLocal
    Runs the local deployment phase on servers.
    CSV must have a column "ServerName" with the server hostnames.

.EXAMPLE
    PS> .\Manage-ServerAdminGroups.ps1 -PrepAD
    # Prompts for CSV of group names and adds ADM_WINDOWS to each.

    PS> .\Manage-ServerAdminGroups.ps1 -DeployLocal
    # Prompts for CSV of server names and updates local Administrator membership.

.REQUIREMENTS
    - RSAT Active Directory module available
    - Domain account with rights to manage groups in AD
    - Local admin rights on servers for DeployLocal phase
    - PowerShell Remoting enabled on servers
    - For DEV/UAT servers without DNS entries: local hosts file entries required for name resolution.

.NOTES
    Author:  Anthony Harvey
    Date:    2024-02-20
    Domain:  gmsprod.internal (NetBIOS Name: GMSPROD)
#>

[CmdletBinding()]
param(
    [switch]$PrepAD,
    [switch]$DeployLocal
)

Import-Module ActiveDirectory -ErrorAction Stop

# Common vars
$NestedGroup = "ADM_WINDOWS"

# ----------- PREP AD Phase -----------
if ($PrepAD) {
    $CsvPath = Read-Host "Enter full path to CSV file containing GroupName column for server-specific ADM- groups"
    if (-not (Test-Path $CsvPath)) {
        Write-Host "CSV not found at $CsvPath" -ForegroundColor Red
        exit
    }

    $Groups = Import-Csv -Path $CsvPath
    $PrepResults = @()

    foreach ($entry in $Groups) {
        $TargetGroup = $entry.GroupName.Trim()
        if (-not $TargetGroup) { continue }

        Write-Host "Processing: Add ${NestedGroup} into ${TargetGroup}" -ForegroundColor Cyan

        try {
            $GroupObj = Get-ADGroup -Identity $TargetGroup -ErrorAction Stop
            $Members = Get-ADGroupMember -Identity $TargetGroup -Recursive | Select-Object -ExpandProperty SamAccountName

            if ($Members -contains $NestedGroup) {
                Write-Host "Already present in ${TargetGroup}" -ForegroundColor Yellow
                $PrepResults += [PSCustomObject]@{
                    TargetGroup = $TargetGroup
                    NestedGroup = $NestedGroup
                    Status      = "Already Present"
                }
            }
            else {
                Add-ADGroupMember -Identity $TargetGroup -Members $NestedGroup -ErrorAction Stop
                Write-Host "Added ${NestedGroup} to ${TargetGroup}" -ForegroundColor Green
                $PrepResults += [PSCustomObject]@{
                    TargetGroup = $TargetGroup
                    NestedGroup = $NestedGroup
                    Status      = "Added"
                }
            }
        }
        catch {
            Write-Host "Error processing ${TargetGroup}: $_" -ForegroundColor Red
            $PrepResults += [PSCustomObject]@{
                TargetGroup = $TargetGroup
                NestedGroup = $NestedGroup
                Status      = "Error: $($_.Exception.Message)"
            }
        }
    }

    # Save PrepAD log
    $PrepLogPath = Join-Path -Path $PSScriptRoot -ChildPath ("PrepAD_Log_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $PrepResults | Export-Csv -Path $PrepLogPath -NoTypeInformation
    Write-Host "`nPrepAD phase completed. Log saved to: $PrepLogPath" -ForegroundColor Green
}

# ----------- DEPLOY Local Phase -----------
if ($DeployLocal) {
    $CsvPath = Read-Host "Enter full path to CSV file containing ServerName column"
    if (-not (Test-Path $CsvPath)) {
        Write-Host "CSV not found at $CsvPath" -ForegroundColor Red
        exit
    }

    $DomainName = (Get-ADDomain).NetBIOSName
    $Servers = Import-Csv -Path $CsvPath
    $Results = @()

    foreach ($server in $Servers) {
        $ServerName = $server.ServerName.Trim()
        if (-not $ServerName) { continue }

        $OldGroup = "$DomainName\$NestedGroup"
        $NewGroupNameOnly = "ADM-$ServerName"
        $NewGroup = "$DomainName\$NewGroupNameOnly"

        Write-Host "`nProcessing Server: ${ServerName}" -ForegroundColor Cyan

        # Verify the AD group exists
        $ADGroupCheck = Get-ADGroup -Filter { Name -eq $NewGroupNameOnly } -ErrorAction SilentlyContinue
        if (-not $ADGroupCheck) {
            Write-Host "AD group ${NewGroupNameOnly} not found in domain ${DomainName}. Skipping..." -ForegroundColor Red
            $Results += [PSCustomObject]@{
                ServerName = $ServerName
                RemovedOld = "Skipped"
                AddedNew   = "AD Group Not Found"
            }
            continue
        }

        try {
            Invoke-Command -ComputerName $ServerName -ScriptBlock {
                param($OldGroup, $NewGroup)

                $Result = [PSCustomObject]@{
                    ServerName = $env:COMPUTERNAME
                    RemovedOld = "No"
                    AddedNew   = "No"
                }

                try {
                    $admins = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop

                    if ($admins.Name -contains $OldGroup) {
                        Remove-LocalGroupMember -Group "Administrators" -Member $OldGroup -ErrorAction Stop
                        Write-Host "Removed ${OldGroup} from Administrators" -ForegroundColor Yellow
                        $Result.RemovedOld = "Yes"
                    }

                    $admins = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop
                    if ($admins.Name -contains $NewGroup) {
                        Write-Host "${NewGroup} already in Administrators" -ForegroundColor Gray
                        $Result.AddedNew = "Already Present"
                    }
                    else {
                        Add-LocalGroupMember -Group "Administrators" -Member $NewGroup -ErrorAction Stop
                        Write-Host "Added ${NewGroup} to Administrators" -ForegroundColor Green
                        $Result.AddedNew = "Yes"
                    }
                }
                catch {
                    Write-Host "Error modifying Administrators group: $_" -ForegroundColor Red
                    $Result.RemovedOld = "Error"
                    $Result.AddedNew = "Error"
                }

                return $Result
            } -ArgumentList $OldGroup, $NewGroup -ErrorAction Stop | ForEach-Object {
                $Results += $_
            }
        }
        catch {
            Write-Host "Failed to connect to ${ServerName}: $_" -ForegroundColor Red
            $Results += [PSCustomObject]@{
                ServerName = $ServerName
                RemovedOld = "Connection Failed"
                AddedNew   = "Connection Failed"
            }
        }
    }

    $LogPath = Join-Path -Path $PSScriptRoot -ChildPath ("LocalAdminReplaceLog_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $Results | Export-Csv -Path $LogPath -NoTypeInformation
    Write-Host "`nDeployLocal phase completed. Log saved to: $LogPath" -ForegroundColor Green
}

# ----------- No Switch Provided ---------
if (-not $PrepAD -and -not $DeployLocal) {
    Write-Host "Please run with either -PrepAD or -DeployLocal switch." -ForegroundColor Yellow
    Write-Host "Example: .\Manage-ServerAdminGroups.ps1 -PrepAD"
    Write-Host "         .\Manage-ServerAdminGroups.ps1 -DeployLocal"
}