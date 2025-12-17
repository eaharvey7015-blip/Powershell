# Requires the ActiveDirectory module
Import-Module ActiveDirectory

# Ask for OU Distinguished Name
$ou = Read-Host "Enter the OU DN where you want to create the groups (e.g. OU=Security Groups,DC=gmsprod,DC=internal)"

# Path to your CSV file
$csvPath = "C:\Scripts\groups.csv"

# Read CSV file (must have GroupName as header)
$groups = Import-Csv -Path $csvPath

foreach ($group in $groups) {
    $name = $group.GroupName

    # Check if the group already exists
    if (Get-ADGroup -Filter { Name -eq $name }) {
        Write-Host "Group '$name' already exists. Skipping..." -ForegroundColor Yellow
    }
    else {
        Write-Host "Creating group '$name' in $ou..." -ForegroundColor Green
        New-ADGroup -Name $name `
                    -GroupScope Global `
                    -GroupCategory Security `
                    -Path $ou
    }
}