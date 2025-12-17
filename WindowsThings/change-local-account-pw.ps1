<#
.SYNOPSIS
    Change the password for a specific local user account across multiple servers from a CSV list.

.DESCRIPTION
    Reads a CSV with a column "ServerName".
    Prompts for the local username you want to change and the new password via GUI InputBox (paste-friendly).
    Changes that local account's password locally or remotely via Invoke-Command.
    Logs results to a CSV file.

.CSV FORMAT
    ServerName
    Server01
    Server02
    192.168.1.25

.REQUIREMENTS
    - Run PowerShell as Administrator.
    - PowerShell Remoting enabled on all target servers.
    - Admin rights on target machines.
#>

# Load Microsoft.VisualBasic for InputBox
Add-Type -AssemblyName Microsoft.VisualBasic

# Prompt for CSV location
$CsvPath = Read-Host "Enter full path to CSV file containing server names"
if (-not (Test-Path $CsvPath)) {
    Write-Host "CSV file not found!" -ForegroundColor Red
    exit
}

# Prompt for local account name
$UserName = Read-Host "Enter the local account name to change (case-insensitive)"

# Prompt for password via GUI InputBox (paste-friendly)
$PwdPlain = [Microsoft.VisualBasic.Interaction]::InputBox("Enter new password for $UserName", "$UserName Password Entry")

if ([string]::IsNullOrWhiteSpace($PwdPlain)) {
    Write-Host "No password entered. Exiting..." -ForegroundColor Yellow
    exit
}

# Convert to SecureString
$Pwd = ConvertTo-SecureString $PwdPlain -AsPlainText -Force

# Import CSV
try {
    $Servers = Import-Csv -Path $CsvPath
} catch {
    Write-Host "Error reading CSV: $_" -ForegroundColor Red
    exit
}

# Store results
$Results = @()

# Script block to change a single user password
$ChangePwdBlock = {
    param($UserName, $Pwd)

    $ServerResult = [PSCustomObject]@{
        ServerName   = $env:COMPUTERNAME
        Status       = "Unknown"
        Message      = ""
    }

    try {
        $UserExists = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue

        if ($UserExists) {
            Set-LocalUser -Name $UserName -Password $Pwd
            $ServerResult.Status = "Success"
            $ServerResult.Message = "$UserName password changed."
        } else {
            $ServerResult.Status = "Account Missing"
            $ServerResult.Message = "$UserName not found on this server."
        }
    }
    catch {
        $ServerResult.Status = "Error"
        $ServerResult.Message = $_.Exception.Message
    }

    return $ServerResult
}

# Loop through each server
foreach ($Server in $Servers) {
    $ServerName = $Server.ServerName.Trim()
    if (-not $ServerName) { continue }

    Write-Host "`n------ Processing: $ServerName ------" -ForegroundColor Cyan

    try {
        if ($ServerName -eq "localhost" -or $ServerName -eq $env:COMPUTERNAME) {
            $result = & $ChangePwdBlock $UserName $Pwd
        } else {
            $result = Invoke-Command -ComputerName $ServerName -ScriptBlock $ChangePwdBlock -ArgumentList $UserName, $Pwd -ErrorAction Stop
        }
    }
    catch {
        $result = [PSCustomObject]@{
            ServerName = $ServerName
            Status     = "Connection Failed"
            Message    = $_.Exception.Message
        }
    }

    $Results += $result
}

# Save results log
$LogPath = Join-Path -Path $PSScriptRoot -ChildPath ("PasswordChangeLog_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Results | Export-Csv -Path $LogPath -NoTypeInformation

Write-Host "`nPassword change complete. Log saved to: $LogPath" -ForegroundColor Green