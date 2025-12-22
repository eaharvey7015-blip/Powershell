# ===============================
# PowerShell Stuff - Daily Tools Menu
# ===============================
Import-Module ActiveDirectory
Clear-Host

do {
    Write-Host "==== Daily Tasks Menu ===="
    Write-Host "1) List all AD groups for a user"
    Write-Host "2) Create Security Groups from CSV (filter & select OU)"
    Write-Host "3) Exit"
    Write-Host

    $choice = Read-Host "Enter your choice (number)"

    switch ($choice) {
        '1' {
            # Option 1 - List all AD groups for a user
            $user = Read-Host "Enter the username"
            Get-ADUser -Identity $user -Properties MemberOf |
                Select-Object -ExpandProperty MemberOf |
                ForEach-Object { (Get-ADGroup $_).Name }
            Write-Host
        }
        '2' {
            # Option 2 - Create Security Groups from CSV - Filter & Select OU
            $ouFilter = Read-Host "Enter part of the OU name to filter (leave blank for all)"
            
            if ([string]::IsNullOrWhiteSpace($ouFilter)) {
                $ous = Get-ADOrganizationalUnit -Filter * | Sort-Object Name
            }
            else {
                $ous = Get-ADOrganizationalUnit -Filter "Name -like '*$ouFilter*'" | Sort-Object Name
            }

            if ($ous.Count -eq 0) {
                Write-Host "No OUs found matching filter '$ouFilter'" -ForegroundColor Red
                Pause
                break
            }

            Write-Host "Available OUs:"
            for ($i = 0; $i -lt $ous.Count; $i++) {
                Write-Host "$($i+1)) $($ous[$i].Name) - $($ous[$i].DistinguishedName)"
            }

            $ouChoice = Read-Host "Enter the number of the OU to use"

            if ($ouChoice -match '^\d+$' -and $ouChoice -ge 1 -and $ouChoice -le $ous.Count) {
                $ou = $ous[$ouChoice-1].DistinguishedName
                Write-Host "Selected OU: $ou" -ForegroundColor Cyan
            }
            else {
                Write-Host "Invalid OU choice." -ForegroundColor Red
                Pause
                break
            }

            $csvPath = Read-Host "Enter full path to CSV file (e.g. C:\Scripts\groups.csv)"
            
            if (-Not (Test-Path $csvPath)) {
                Write-Host "CSV file not found at $csvPath" -ForegroundColor Red
            }
            else {
                $groups = Import-Csv -Path $csvPath
                
                foreach ($group in $groups) {
                    $name = $group.GroupName

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
            }
            Write-Host
        }
        '3' {
            Write-Host "Exiting..."
            break
        }
        Default {
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
        }
    }

    if ($choice -ne '3') {
        Write-Host
        Pause
        Clear-Host
    }
} while ($choice -ne '3')