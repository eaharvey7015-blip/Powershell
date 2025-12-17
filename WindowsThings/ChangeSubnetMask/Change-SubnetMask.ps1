<#
.SYNOPSIS
    Change the subnet mask (prefix length) for a Windows Server's existing IPv4 address.

.DESCRIPTION
    This script modifies ONLY the subnet mask (prefix length) for an existing IPv4 address.
    It retains the current IP address, default gateway, and DNS server settings.
    Includes safety checks, a 7-second wait after changes, and automatic rollback if connectivity fails.
    Skips change if the subnet mask is already set to the requested prefix length.
    Can be run locally or remotely via PowerShell remoting.

.PARAMETERS
    ServerName       - Prompted interactively; 'localhost' for the local machine or remote server name.
    PrefixLength     - Prompted interactively; CIDR prefix length (1–32).

.WORKFLOW
    1. Prompt for server name and new prefix length.
    2. Validate prefix length.
    3. Gather current network settings (IP, gateway, DNS).
    4. If current prefix matches requested, skip change.
    5. Remove only the IP (retain gateway).
    6. Add IP back with new prefix length.
    7. Wait 7 seconds for NIC to rebind.
    8. Test connectivity to gateway.
    9. If connectivity fails, rollback to previous settings.

.REQUIREMENTS
    - Run PowerShell as Administrator.
    - For remote use, target server must have PowerShell Remoting enabled.
    - User must have permission to reconfigure network interfaces.
#>

function Get-SubnetMaskFromPrefix {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateRange(1,32)]
        [int]$PrefixLength
    )
    $maskBits = ("1" * $PrefixLength).PadRight(32, "0")
    $octets = for ($i = 0; $i -lt 4; $i++) {
        [convert]::ToInt32($maskBits.Substring($i * 8, 8), 2)
    }
    return ($octets -join ".")
}

$Server = Read-Host "Enter the server name (use 'localhost' for local)"
$PrefixLengthInput = Read-Host "Enter the desired prefix length (CIDR format, e.g., 24)"
if (-not ($PrefixLengthInput -match '^\d+$')) { Write-Host "Invalid prefix length." -ForegroundColor Red; exit }
$PrefixLength = [int]$PrefixLengthInput
if ($PrefixLength -lt 1 -or $PrefixLength -gt 32) { Write-Host "Prefix length must be 1-32." -ForegroundColor Red; exit }

$ScriptBlock = {
    param($PrefixLength)
    function Get-SubnetMaskFromPrefix {
        param([int]$PrefixLength)
        $maskBits = ("1" * $PrefixLength).PadRight(32, "0")
        $octets = for ($i = 0; $i -lt 4; $i++) {
            [convert]::ToInt32($maskBits.Substring($i * 8, 8), 2)
        }
        return ($octets -join ".")
    }

    $Adapter = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -ne $null } | Select-Object -First 1
    if (-not $Adapter) { Write-Host "No IPv4 adapter found." -ForegroundColor Red; return }

    $InterfaceAlias = $Adapter.InterfaceAlias
    $OldIP      = $Adapter.IPv4Address[0].IPAddress
    $OldPrefix  = $Adapter.IPv4Address[0].PrefixLength
    $Gateway    = $Adapter.IPv4DefaultGateway.NextHop
    $OldDNS     = (Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4).ServerAddresses
    $SubnetMask = Get-SubnetMaskFromPrefix -PrefixLength $PrefixLength

    # Skip if already correct prefix length
    if ($OldPrefix -eq $PrefixLength) {
        Write-Host "Prefix length is already /$PrefixLength — no change needed." -ForegroundColor Green
        return
    }

    Write-Host "`nCurrent settings:" -ForegroundColor Cyan
    Write-Host "Interface: $InterfaceAlias"
    Write-Host "IP Address: $OldIP"
    Write-Host "Gateway: $Gateway"
    Write-Host "DNS Servers: $($OldDNS -join ', ')"
    Write-Host "New CIDR: /$PrefixLength"
    Write-Host "New Subnet Mask: $SubnetMask"

    $confirm = Read-Host "Type 'YES' to apply the change"
    if ($confirm -ne 'YES') { Write-Host "Cancelled." -ForegroundColor Yellow; return }

    try {
        Remove-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $OldIP -Confirm:$false
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $OldIP -PrefixLength $PrefixLength
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $OldDNS

        Write-Host "Waiting 7 seconds for network to rebind..." -ForegroundColor Yellow
        Start-Sleep -Seconds 7

        Write-Host "Testing connectivity to $Gateway..." -ForegroundColor Yellow
        if (-not (Test-Connection -ComputerName $Gateway -Count 2 -Quiet)) {
            Write-Host "Ping failed — rolling back." -ForegroundColor Red
            Remove-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $OldIP -Confirm:$false
            New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $OldIP -PrefixLength $OldPrefix -DefaultGateway $Gateway
            Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $OldDNS
            Write-Host "Rollback complete — original settings restored." -ForegroundColor Green
        } else {
            Write-Host "Connectivity OK — change persisted." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
}

if ($Server -eq "localhost" -or $Server -eq $env:COMPUTERNAME) {
    & $ScriptBlock $PrefixLength
} else {
    Invoke-Command -ComputerName $Server -ScriptBlock $ScriptBlock -ArgumentList $PrefixLength
}