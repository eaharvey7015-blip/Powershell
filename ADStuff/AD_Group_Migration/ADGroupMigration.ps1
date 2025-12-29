<#
.SYNOPSIS
    AD Group Migration Tool - Export and Import Active Directory group members between domains.

.DESCRIPTION
    This script is designed for migrating AD group memberships from one domain to another.
    It operates in two phases via an interactive menu:

    1. EXPORT PHASE:
        - Prompts for an existing AD group in the source domain.
        - Exports all members (users only) to a CSV file in the script's directory.
        - Collects: GivenName, Surname, SamAccountName, UserPrincipalName, EmailAddress.
        - Saves file in UTF8 encoding as "<GroupName>_Members.csv".

    2. IMPORT PHASE:
        - Prompts for:
            a) Target group name to create/use in target domain.
            b) Path to CSV containing group members (defaults to script directory).
            c) Default temporary password for new accounts.
            d) OU for the **group** (e.g., Security Groups OU).
            e) OU for the **users** (e.g., Users OU).
        - Creates the group if it does not exist in the chosen Group OU.
        - Creates user accounts if they do not exist in the chosen Users OU.
        - Adds all imported users to the specified group.
        - Sets all new accounts to "Change Password at Next Logon".
        - Keeps Users OU and Groups OU clean and organized.

.WORKFLOW
    Source Domain:
        1. Run script, choose option 1 (Export).
        2. Enter source group name.
        3. CSV is created in same folder as the script.

    Target Domain:
        1. Place CSV in same folder as script.
        2. Run script, choose option 2 (Import).
        3. Enter group name, confirm CSV filename, enter temporary password.
        4. Select OUs for the group and for the users from the provided list.
        5. Script will create missing objects and apply group membership.

.REQUIREMENTS
    - RSAT Active Directory PowerShell module installed.
    - Admin rights in source domain for export.
    - Admin rights in target domain for import.
    - PowerShell 5.1+.
    - Proper network/domain connectivity between management machine and domain controllers.

.LIMITATIONS
    - Passwords are **not** migrated from source domain; default temporary password is set during import.
    - Nested group handling: the export is recursive, so all user members are included even if nested in other groups.
    - This script does not migrate SID history or permissions — only creates accounts and sets memberships.

.OUTPUT
    - CSV: "<GroupName>_Members.csv" in the script directory after export.
    - Console output logs each creation/addition during import.

.EXAMPLES
    Export members of the "Hitachi_Admins" group from source domain:
        PS> .\ADGroupMigration.ps1
        Enter choice (1 or 2): 1
        Enter the name of the AD group to export members from: Hitachi_Admins
        --> CSV file "Hitachi_Admins_Members.csv" saved to script directory.

    Import members into target domain to specific OUs:
        PS> .\ADGroupMigration.ps1
        Enter choice (1 or 2): 2
        Enter the AD group name to create/add users to in target domain: Hitachi_Admins
        Enter CSV filename (default is Hitachi_Admins_Members.csv): [press Enter]
        Enter default temporary password for new users: TempP@ss2024
        Select OU for the GROUP: [menu selection]
        Select OU for the USERS: [menu selection]
        --> Group created in Groups OU, users created in Users OU, memberships linked.

.AUTHOR
    Anthony Harvey
    Date: 2024-02-21
    Version: 2.0 (Clean OU separation, DN targeting, robust CSV handling)
#>

Import-Module ActiveDirectory -ErrorAction Stop

function Get-OUSelection {
    # Get all OUs and CN=Users container
    $OUs = Get-ADOrganizationalUnit -Filter * | Sort-Object Name
    $UsersContainer = Get-ADObject -Filter { Name -eq "Users" -and ObjectClass -eq "container" }
    if ($UsersContainer) {
        $OUs += $UsersContainer
    }

    Write-Host "`nAvailable Locations:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $OUs.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $OUs[$i].DistinguishedName)
    }

    $selection = Read-Host "Enter the number for desired location"
    if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $OUs.Count) {
        return $OUs[$selection - 1].DistinguishedName
    } else {
        Write-Host "Invalid selection." -ForegroundColor Red
        return $null
    }
}

function Export-ADGroupMembers {
    Write-Host "`n=== EXPORT GROUP MEMBERS ===" -ForegroundColor Cyan

    $GroupName = Read-Host "Enter the name of the AD group to export members from"

    try {
        Get-ADGroup -Identity $GroupName -ErrorAction Stop
    } catch {
        Write-Host "Group '${GroupName}' not found in AD." -ForegroundColor Red
        return
    }

    $Members = Get-ADGroupMember -Identity $GroupName -Recursive |
               Where-Object { $_.objectClass -eq 'user' }

    if (-not $Members) {
        Write-Host "No user accounts found in '${GroupName}'." -ForegroundColor Yellow
        return
    }

    $ExportDir = $PSScriptRoot
    $ExportPath = Join-Path $ExportDir ("{0}_Members.csv" -f $GroupName)

    $Members | ForEach-Object {
        Get-ADUser $_.SamAccountName -Properties GivenName, Surname, SamAccountName, UserPrincipalName, EmailAddress
    } |
    Select-Object GivenName, Surname, SamAccountName, UserPrincipalName, EmailAddress |
    Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

    Write-Host "Exported $($Members.Count) members to: ${ExportPath}" -ForegroundColor Green
}

function Import-ADGroupMembers {
    Write-Host "`n=== IMPORT GROUP MEMBERS ===" -ForegroundColor Cyan

    $GroupName = Read-Host "Enter the AD group name to create/add users to in target domain"

    $CsvDir = $PSScriptRoot
    $CsvFileName = Read-Host "Enter CSV filename (default is ${GroupName}_Members.csv)"
    if (-not $CsvFileName) {
        $CsvFileName = "${GroupName}_Members.csv"
    }
    $CsvPath = Join-Path $CsvDir $CsvFileName

    if (-not (Test-Path $CsvPath)) {
        Write-Host "CSV file not found: ${CsvPath}" -ForegroundColor Red
        return
    }

    $PlainPassword = Read-Host "Enter default temporary password for new users"
    $SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force

    # Select OU for the group
    Write-Host "`nSelect OU for the GROUP:" -ForegroundColor Cyan
    $GroupOUPath = Get-OUSelection
    if (-not $GroupOUPath) { return }

    # Select OU for the users
    Write-Host "`nSelect OU for the USERS:" -ForegroundColor Cyan
    $UserOUPath = Get-OUSelection
    if (-not $UserOUPath) { return }

    # Ensure group exists in Group OU and get DN
    if (-not (Get-ADGroup -Filter { Name -eq $GroupName } -SearchBase $GroupOUPath)) {
        New-ADGroup -Name $GroupName -GroupScope Global -GroupCategory Security -Path $GroupOUPath | Out-Null
        Write-Host "Created group '${GroupName}' in ${GroupOUPath}" -ForegroundColor Green
    } else {
        Write-Host "Group '${GroupName}' already exists" -ForegroundColor Yellow
    }
    $GroupObj = Get-ADGroup -Filter { Name -eq $GroupName } -SearchBase $GroupOUPath -Properties DistinguishedName
    $GroupDN  = $GroupObj.DistinguishedName

    # Import and clean CSV data
    $Users = Import-Csv $CsvPath | ForEach-Object {
        $_.GivenName         = ($_.GivenName         -as [string]).Trim()
        $_.Surname           = ($_.Surname           -as [string]).Trim()
        $_.SamAccountName    = ($_.SamAccountName    -as [string]).Trim()
        $_.UserPrincipalName = ($_.UserPrincipalName -as [string]).Trim()
        $_.EmailAddress      = ($_.EmailAddress      -as [string]).Trim()
        $_
    }

    foreach ($u in $Users) {
        $sa  = $u.'SamAccountName'
        $upn = $u.'UserPrincipalName'

        if (-not $sa) {
            Write-Host "Skipping row with missing SamAccountName" -ForegroundColor Yellow
            continue
        }

        $ExistingUser = Get-ADUser -Filter { SamAccountName -eq $sa } -ErrorAction SilentlyContinue

        if (-not $ExistingUser) {
            New-ADUser -Name "$($u.'GivenName') $($u.'Surname')" `
                       -SamAccountName $sa `
                       -GivenName $u.'GivenName' `
                       -Surname $u.'Surname' `
                       -UserPrincipalName $upn `
                       -EmailAddress $u.'EmailAddress' `
                       -AccountPassword $SecurePassword `
                       -Enabled $true `
                       -PasswordNeverExpires $false `
                       -ChangePasswordAtLogon $true `
                       -Path $UserOUPath

            Write-Host "Created user: $sa" -ForegroundColor Green

            Start-Sleep -Seconds 1
            $ExistingUser = Get-ADUser -Filter { SamAccountName -eq $sa } -ErrorAction SilentlyContinue
        } else {
            Write-Host "User $sa already exists" -ForegroundColor Yellow
        }

        if ($ExistingUser -and $GroupDN) {
            try {
                Add-ADGroupMember -Identity $GroupDN -Members $sa
                Write-Host "Added $sa to ${GroupName}" -ForegroundColor Cyan
            } catch {
                Write-Host "Could not add $sa to ${GroupName}: $_" -ForegroundColor Red
            }
        }
    }

    Write-Host "Import completed." -ForegroundColor Green
}

# --- MENU ---
Write-Host "==================================" -ForegroundColor White
Write-Host " 1 - Export AD Group Members" -ForegroundColor White
Write-Host " 2 - Import AD Group Members" -ForegroundColor White
Write-Host "==================================" -ForegroundColor White

$Choice = Read-Host "Enter choice (1 or 2)"

switch ($Choice) {
    "1" { Export-ADGroupMembers }
    "2" { Import-ADGroupMembers }
    default { Write-Host "Invalid choice. Please run again and select 1 or 2." -ForegroundColor Red }
}
