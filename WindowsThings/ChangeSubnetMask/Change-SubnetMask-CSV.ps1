<#
.SYNOPSIS
    Change the subnet mask (prefix length) for multiple Windows Servers from a CSV list.

.DESCRIPTION
    Reads a list of servers from a CSV (column "ServerName"), connects to each locally or via PowerShell remoting,
    and changes ONLY the subnet mask/prefix length for the existing IPv4 address, keeping IP, gateway, and DNS the same.
    Skips servers where the prefix length already matches the requested value.
    Logs results to CSV, shows a table + summary at the end.
#>

function Get-SubnetMaskFromPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 32)]
        [int]$PrefixLength
    )
    $maskBits = ("1" * $PrefixLength).PadRight(32, "0")
    $octets = for ($i = 0; $i -lt 4; $i++) {
        [convert]::ToInt32($maskBits.Substring($i * 8, 8), 2)
    }
    return ($octets -join ".")
}

# === Interactive inputs ===
$ServerListPath = Read-Host "Enter full path to CSV file (must have 'ServerName' column)"
if (-not (Test-Path $ServerListPath)) { Write-Host "File not found: $ServerListPath" -ForegroundColor Red; exit }

$PrefixLengthInput = Read-Host "Enter desired prefix length (CIDR format, e.g., 24)"
if (-not ($PrefixLengthInput -match '^\d+$')) { Write-Host "Invalid prefix length." -ForegroundColor Red; exit }
$PrefixLength = [int]$PrefixLengthInput
if ($PrefixLength -lt 1 -or $PrefixLength -gt 32) { Write-Host "Prefix length must be between 1 and 32." -ForegroundColor Red; exit }

# === ScriptBlock to run locally/remotely ===
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
    if (-not $Adapter) {
        Write-Host "No IPv4 adapter found." -ForegroundColor Red
        return [PSCustomObject]@{
            OldPrefix = $null
            NewPrefix = $PrefixLength
            Result    = "No IPv4 Adapter Found"
        }
    }

    $InterfaceAlias = $Adapter.InterfaceAlias
    $OldIP      = $Adapter.IPv4Address[0].IPAddress
    $OldPrefix  = $Adapter.IPv4Address[0].PrefixLength
    $Gateway    = $Adapter.IPv4DefaultGateway.NextHop
    $OldDNS     = (Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4).ServerAddresses
    $SubnetMask = Get-SubnetMaskFromPrefix -PrefixLength $PrefixLength

    if ($OldPrefix -eq $PrefixLength) {
        Write-Host "Prefix length already /$PrefixLength — skipping." -ForegroundColor Green
        return [PSCustomObject]@{
            OldPrefix = $OldPrefix
            NewPrefix = $PrefixLength
            Result    = "Skipped - Already /$PrefixLength"
        }
    }

    Write-Host "`nChanging $InterfaceAlias on $env:COMPUTERNAME from /$OldPrefix to /$PrefixLength ($SubnetMask)" -ForegroundColor Yellow

    try {
        # SAFER: change subnet mask only, keep IP/gateway/DNS — no remove/add
        Set-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $OldIP -PrefixLength $PrefixLength -DefaultGateway $Gateway
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $OldDNS

        Write-Host "Waiting 7 seconds for network to rebind..." -ForegroundColor Yellow
        Start-Sleep -Seconds 7

        if (-not (Test-Connection -ComputerName $Gateway -Count 2 -Quiet)) {
            Write-Host "Ping failed — rolling back to /$OldPrefix" -ForegroundColor Red
            Set-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $OldIP -PrefixLength $OldPrefix -DefaultGateway $Gateway
            Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $OldDNS
            return [PSCustomObject]@{
                OldPrefix = $OldPrefix
                NewPrefix = $PrefixLength
                Result    = "Failed - Rolled Back"
            }
        } else {
            Write-Host "Connectivity OK — change persisted." -ForegroundColor Green
            return [PSCustomObject]@{
                OldPrefix = $OldPrefix
                NewPrefix = $PrefixLength
                Result    = "Success"
            }
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return [PSCustomObject]@{
            OldPrefix = $OldPrefix
            NewPrefix = $PrefixLength
            Result    = "Error: $($_.Exception.Message)"
        }
    }
}

# === Read CSV & run per-server ===
$Servers = Import-Csv $ServerListPath
$Results = @()

foreach ($Server in $Servers) {
    $Target = $Server.ServerName
    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Host "Skipping empty or invalid entry in CSV" -ForegroundColor Yellow
        continue
    }

    Write-Host "`n---------- Processing Server: $Target ----------" -ForegroundColor Cyan

    try {
        $Res = if ($Target -eq "localhost" -or $Target -eq $env:COMPUTERNAME) {
            & $ScriptBlock $PrefixLength
        } else {
            Invoke-Command -ComputerName $Target -ScriptBlock $ScriptBlock -ArgumentList $PrefixLength
        }

        $Results += [PSCustomObject]@{
            ServerName = $Target
            OldPrefix  = $Res.OldPrefix
            NewPrefix  = $Res.NewPrefix
            Result     = $Res.Result
        }
    }
    catch {
        Write-Host "ERROR on ${Target}: $_" -ForegroundColor Red
        $Results += [PSCustomObject]@{
            ServerName = $Target
            OldPrefix  = $null
            NewPrefix  = $PrefixLength
            Result     = "Error: $($_.Exception.Message)"
        }
    }
}

# === Export results to CSV ===
$ReportPath = "C:\Temp\SubnetChange_Report.csv"
$Results | Export-Csv -Path $ReportPath -NoTypeInformation
Write-Host "`n=== Report saved to $ReportPath ===" -ForegroundColor Cyan

# === Show table in console ===
Write-Host "`n=== Subnet Change Summary ==="
$Results | Format-Table -AutoSize ServerName,OldPrefix,NewPrefix,Result

# === Show summary counts ===
$TotalCount   = $Results.Count
$SuccessCount = ($Results | Where-Object { $_.Result -like 'Success*' }).Count
$FailCount    = ($Results | Where-Object { $_.Result -like 'Failed*' -or $_.Result -like 'Error*' }).Count
$SkippedCount = ($Results | Where-Object { $_.Result -like 'Skipped*' }).Count

Write-Host "`nSummary:"
Write-Host "  Total Servers: $TotalCount"
Write-Host "  Success: $SuccessCount"
Write-Host "  Failed/Rolled Back/Error: $FailCount"
Write-Host "  Skipped (Already Set): $SkippedCount"