<#
.SYNOPSIS
Deploys an MSI silently to remote machines listed in serverlist.csv.
Pre-checks if product is installed, skips unreachable hosts,
and logs results to DeploymentResults.csv.
#>

# ==============================
# Configuration
# ==============================

$ServerList   = ".\serverlist.csv"              # CSV with ComputerName header
$MSIPath      = "C:\WindowsExporterAH\windows_exporter-0.31.3-amd64.msi"     # Local path to MSI file
$RemotePath   = "C:\Temp"                       # Temp folder on remote machines
$ResultsCsv   = ".\DeploymentResults.csv"       # Results file
$ProductCode  = "{13C1979E-FEE4-4895-A029-B7814AAA1E0E}"  # MSI Product GUID

# ==============================
# Prep & Validation
# ==============================

if (!(Test-Path $ServerList)) {
    Write-Error "Server list CSV not found at: $ServerList"
    exit 1
}

$Computers = Import-Csv $ServerList
if (-not ($Computers -and $Computers[0].ComputerName)) {
    Write-Error "CSV missing 'ComputerName' header or empty."
    exit 1
}

if (!(Test-Path $MSIPath)) {
    Write-Error "MSI file not found at: $MSIPath"
    exit 1
}

# ==============================
# Add All Targets to TrustedHosts
# ==============================
$TargetList = ($Computers.ComputerName | Where-Object { $_ -and $_.Trim() -ne "" }) -join ","
Write-Host "Adding to TrustedHosts: $TargetList" -ForegroundColor Yellow
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TargetList -Force

# ==============================
# Initialize Results
# ==============================
$Results = @()

# ==============================
# Deployment Loop
# ==============================
foreach ($ComputerEntry in $Computers) {
    $Computer = $ComputerEntry.ComputerName.Trim()
    if ([string]::IsNullOrWhiteSpace($Computer)) { continue }

    Write-Host "Processing ${Computer} ..." -ForegroundColor Cyan
    $Status = "Unknown"
    $Message = ""

    # --- Step 1: Ping check ---
    if (-not (Test-Connection -ComputerName $Computer -Count 1 -Quiet)) {
        $Status  = "Unreachable"
        $Message = "Cannot reach host via ping"
        Write-Host "${Computer}: $Message" -ForegroundColor Red
        $Results += [PSCustomObject]@{ ComputerName=$Computer; Status=$Status; Message=$Message }
        continue
    }

    try {
        # --- Step 2: Check if software installed remotely ---
        $Installed = Invoke-Command -ComputerName $Computer -Authentication Negotiate -ErrorAction Stop -ScriptBlock {
            param($ProductCode)
            $paths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($p in $paths) {
                $apps = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -eq $ProductCode }
                if ($apps) { return $true }
            }
            return $false
        } -ArgumentList $ProductCode

        if ($Installed) {
            $Status  = "Already Installed"
            $Message = "Product code $ProductCode found; skipped install"
            Write-Host "${Computer}: $Message" -ForegroundColor Yellow
        }
        else {
            # --- Step 3: Create remote folder ---
            Invoke-Command -ComputerName $Computer -Authentication Negotiate -ErrorAction Stop -ScriptBlock {
                param($Path)
                if (-not (Test-Path $Path)) {
                    New-Item -Path $Path -ItemType Directory -Force | Out-Null
                }
            } -ArgumentList $RemotePath

            # --- Step 4: Copy MSI via PowerShell Remoting ---
            $session = New-PSSession -ComputerName $Computer -Authentication Negotiate -ErrorAction Stop
            Copy-Item -Path $MSIPath -Destination $RemotePath -ToSession $session -Force
            Remove-PSSession $session

            # --- Step 5: Install silently ---
            $RemoteMSI = "$RemotePath\$(Split-Path $MSIPath -Leaf)"
            Invoke-Command -ComputerName $Computer -Authentication Negotiate -ErrorAction Stop -ScriptBlock {
                param($Path)
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$Path`" /qn /norestart" -Wait
            } -ArgumentList $RemoteMSI

            $Status  = "Success"
            $Message = "Deployment completed successfully"
            Write-Host "${Computer}: Deployment complete." -ForegroundColor Green
        }
    }
    catch {
        $Status  = "Failed"
        $Message = $_.Exception.Message
        Write-Host "${Computer}: Deployment failed. $Message" -ForegroundColor Red
    }

    # --- Step 6: Add result record ---
    $Results += [PSCustomObject]@{
        ComputerName = $Computer
        Status       = $Status
        Message      = $Message
    }
}

# ==============================
# Save Results
# ==============================
$Results | Export-Csv -Path $ResultsCsv -NoTypeInformation
Write-Host "Deployment complete. Results saved to $ResultsCsv" -ForegroundColor Yellow