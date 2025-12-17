<#
.SYNOPSIS
Adds a domain security group to the local Administrators group on remote servers from a CSV list.
Automatically sets TrustedHosts for the target servers.
Generates a detailed CSV report of results.

.DESCRIPTION
- Prompts for:
    1. Server list CSV path (must have "ComputerName" header)
    2. Report CSV path
    3. Domain/security group name (NetBIOS format, e.g. GMSPROD/adm_windows)
- Adds all target servers to TrustedHosts
- Loops through each target:
    * Pings first to check reachability
    * Uses ADSI to add group to "Administrators" local group
    * Records `Success`, `Already Present`, `Unreachable`, or `Failed` to report
#>

# Prompt for CSV file path
$ServerList = Read-Host "Enter the full path to the server list CSV (must have a ComputerName header)"
# Prompt for output report path
$ReportPath = Read-Host "Enter the full path to save the results report CSV"
# Prompt for domain/security group
$SecurityGroup = Read-Host "Enter the domain/security group to add to local Administrators (use DOMAIN/GROUP format)"

# Validate server list
if (-not (Test-Path $ServerList)) {
    Write-Host "Server list file not found at $ServerList" -ForegroundColor Red
    exit
}

$Computers = Import-Csv $ServerList
if (-not ($Computers -and $Computers[0].ComputerName)) {
    Write-Host "CSV missing 'ComputerName' header or empty" -ForegroundColor Red
    exit
}

# Add all target hosts to TrustedHosts
$TargetList = ($Computers.ComputerName | Where-Object { $_ -and $_.Trim() -ne "" }) -join ","
Write-Host "Adding to TrustedHosts: $TargetList" -ForegroundColor Yellow
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TargetList -Force

# Initialize report array
$Report = @()

# Loop through servers
foreach ($Computer in $Computers) {
    $Server = $Computer.ComputerName.Trim()
    if ([string]::IsNullOrWhiteSpace($Server)) { continue }

    Write-Host "Processing ${Server} ..." -ForegroundColor Cyan
    try {
        # Ping check
        if (-not (Test-Connection -ComputerName $Server -Count 1 -Quiet)) {
            $Report += [PSCustomObject]@{ ComputerName=$Server; Status="Unreachable"; Message="Server not reachable via ping" }
            Write-Host "${Server}: Server not reachable via ping" -ForegroundColor Yellow
            continue
        }

        # Execute remote add
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($GroupName)
            $admins = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
            $alreadyMember = $false
            foreach ($member in @($admins.psbase.Invoke("Members"))) {
                $memberObj = $member.GetType().InvokeMember("Name", 'GetProperty', $null, $member, $null)
                if ($memberObj -eq $GroupName.Split('/')[1]) { $alreadyMember = $true; break }
            }
            if (-not $alreadyMember) {
                $admins.Add("WinNT://$GroupName,group")
                return @{ Status="Success"; Message="Added $GroupName to local Administrators" }
            } else {
                return @{ Status="Already Present"; Message="$GroupName is already in local Administrators" }
            }
        } -ArgumentList $SecurityGroup -ErrorAction Stop |
        ForEach-Object {
            $Report += [PSCustomObject]@{ ComputerName=$Server; Status=$_.Status; Message=$_.Message }
            Write-Host "${Server}: $($_.Message)" -ForegroundColor Green
        }
    }
    catch {
        $Report += [PSCustomObject]@{ ComputerName=$Server; Status="Failed"; Message=$_.Exception.Message }
        Write-Host "${Server}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Export report
$Report | Export-Csv -Path $ReportPath -NoTypeInformation
Write-Host "Report saved to $ReportPath" -ForegroundColor Yellow