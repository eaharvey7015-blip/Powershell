<#
.SYNOPSIS
Activate multiple Windows servers using a provided product key via PowerShell Remoting.
Includes Dry-Run mode to test connectivity before real activation.

.DESCRIPTION
- Prompts for Windows Server product key (skipped in Dry-Run mode).
- Reads a list of servers from a CSV or manual entry (ComputerName column).
- In Dry-Run mode: tests ping + PowerShell Remoting connectivity.
- In Activation mode: Installs product key and activates each target server using slmgr.vbs.
- Uses explicit path to slmgr.vbs to avoid WOW64 path redirection issues.
- Smart checks /xpr output to detect Notification, Unlicensed, Evaluation, or Initial grace period.
- Saves a connectivity/activation status log to a timestamped CSV file.

.COMPATIBILITY
Works with any Windows Server version that supports slmgr.vbs activation:
    - Server 2022 ✅
    - Server 2019 ✅
    - Server 2016 ✅
    - Server 2012 R2 ✅
    - Server 2012 ✅
    - Server 2008 R2 ✅*
    - Server 2008 ✅*

* For 2008/2008 R2:
    - Ensure PowerShell Remoting (WinRM) is installed and configured.
    - Firewall ports (TCP 5985 or 5986) must be open.

.REQUIREMENTS
- Run as admin.
- PowerShell Remoting enabled on all target servers (`Enable-PSRemoting -Force`).
- Target servers must reach Microsoft activation servers or KMS/AD host for activation.
- Product key must match the server edition you are activating.

.NOTES
Activation is via explicit cscript.exe calls to:
    $env:WINDIR\System32\slmgr.vbs /ipk <ProductKey>
    $env:WINDIR\System32\slmgr.vbs /ato
    $env:WINDIR\System32\slmgr.vbs /xpr
Non-destructive: If already activated, `/ato` just revalidates.
#>

Write-Host "Select mode:" -ForegroundColor Cyan
Write-Host "1) Dry-Run (Connectivity Test Only)"
Write-Host "2) Real Activation"
$modeChoice = Read-Host "Enter 1 or 2"

switch ($modeChoice) {
    '1' { $dryRun = $true }
    '2' { $dryRun = $false }
    default {
        Write-Host "Invalid selection. Exiting..." -ForegroundColor Red
        exit
    }
}

$csvPath = Read-Host "Enter path to CSV file with 'ComputerName' column (or press Enter to type manually)"
if ($csvPath -and (Test-Path $csvPath)) {
    $serverList = Import-Csv -Path $csvPath | Select-Object -ExpandProperty ComputerName
} else {
    $manualList = Read-Host "Enter server names separated by commas"
    $serverList = $manualList -split "\s*,\s*"
}

if (-not $dryRun) {
    $productKey = Read-Host "Enter Windows Server product key (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)"
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$logFile   = "ActivationLog-$timestamp.csv"
$logData   = @()

foreach ($server in $serverList) {
    Write-Host "Processing ${server}..." -ForegroundColor Cyan

    # Ping test
    if (-not (Test-Connection -ComputerName $server -Count 1 -Quiet)) {
        Write-Host "${server} unreachable by ping." -ForegroundColor Yellow
        $logData += [PSCustomObject]@{
            Server  = $server
            Status  = "Unreachable (Ping)"
            Message = "Ping failed"
        }
        continue
    }

    # WinRM test
    try {
        Test-WSMan -ComputerName $server -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "${server} unreachable via WinRM (PowerShell Remoting)." -ForegroundColor Yellow
        $logData += [PSCustomObject]@{
            Server  = $server
            Status  = "Unreachable (WinRM)"
            Message = "PowerShell Remoting failed"
        }
        continue
    }

    if ($dryRun) {
        Write-Host "${server} connectivity test passed." -ForegroundColor Green
        $logData += [PSCustomObject]@{
            Server  = $server
            Status  = "Dry-Run Passed"
            Message = "Ping + WinRM OK"
        }
        continue
    }

    # Activation mode
    try {
        Invoke-Command -ComputerName $server -ScriptBlock {
            param($key)
            try {
                $slmgrPath = "$env:WINDIR\System32\slmgr.vbs"

                # Install the product key
                cscript.exe //Nologo $slmgrPath /ipk $key

                # Activate Windows
                cscript.exe //Nologo $slmgrPath /ato

                # Check activation status
                $activationStatus = cscript.exe //Nologo $slmgrPath /xpr

                # Smart check: determine true status from /xpr output
                if ($activationStatus -match "Notification" -or
                    $activationStatus -match "Unlicensed" -or
                    $activationStatus -match "Evaluation" -or
                    $activationStatus -match "Initial grace period") {

                    $finalStatus = "Not Activated"
                } else {
                    $finalStatus = "Activated"
                }

                return @{
                    Status  = $finalStatus
                    Message = $activationStatus
                }
            } catch {
                return @{
                    Status  = "Failed"
                    Message = $_.Exception.Message
                }
            }
        } -ArgumentList $productKey -ErrorAction Stop | ForEach-Object {
            $logData += [PSCustomObject]@{
                Server  = $server
                Status  = $_.Status
                Message = $_.Message
            }
            Write-Host "${server}: $($_.Status) - $($_.Message)" -ForegroundColor Green
        }
    } catch {
        $logData += [PSCustomObject]@{
            Server  = $server
            Status  = "Failed"
            Message = $_.Exception.Message
        }
        Write-Host "${server}: Activation failed - $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Save log
$logData | Export-Csv -Path $logFile -NoTypeInformation
Write-Host ""
Write-Host "$(if ($dryRun){"Dry-Run complete"}else{"Activation complete"})" -ForegroundColor Cyan
Write-Host "Log saved to: $logFile" -ForegroundColor Yellow