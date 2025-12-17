<#
.SYNOPSIS
    Collects all successful user logons (console or RDP) on the local machine within the last 24 hours.

.DESCRIPTION
    This script queries the Windows Security event log for Event ID 4624 (successful logons)
    starting from the last 24 hours. It extracts relevant fields including:
    - Timestamp of the logon
    - Username
    - Domain
    - Logon type (Console or RDP)
    - Server name (hostname where script runs)
    
    System and service accounts are excluded to focus on real user logons.
    The results are exported to a CSV file that can be opened directly in Excel
    for sorting, filtering, and table creation.

.PARAMETER since
    The start time for the search. Default is 1 day ago. Can be adjusted by changing:
        $since = (Get-Date).AddDays(-1)

.PARAMETER outputCsv
    File path for the CSV output. Default is set to C:\Temp\LastDayLogons.csv.

.OUTPUTS
    CSV formatted file containing columns:
        Server, TimeCreated, Domain, UserName, LogonType

.NOTES
    Author : <Your Name>
    Version: 1.0
    Requirements:
      - PowerShell 5.1 or higher
      - Local Administrator privileges (to read Security log)
      - Run locally on the target machine or via Invoke-Command for remote query
      - Security event log retention may limit historical results
#>

# How far back to search (default = 1 day)
$since = (Get-Date).AddDays(-1)

# Logon types to include
$logonTypes = @(2, 10)   # 2 = Interactive (console), 10 = RemoteDesktop

# Output file for Excel
$outputCsv = "C:\Temp\LastDayLogons.csv"

# Get logons from last 24 hrs
$logons = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624; StartTime=$since} |
    ForEach-Object {
        $xml = [xml]$_.ToXml()
        [PSCustomObject]@{
            Server      = $env:COMPUTERNAME
            TimeCreated = $_.TimeCreated
            Domain      = $xml.Event.EventData.Data[6].'#text'  # TargetDomainName
            UserName    = $xml.Event.EventData.Data[5].'#text'  # TargetUserName
            LogonType   = switch ($xml.Event.EventData.Data[8].'#text') {
                              "2"  { "Console" }
                              "10" { "RDP" }
                              default { $xml.Event.EventData.Data[8].'#text' }
                          }
        }
    } |
    Where-Object { 
        $_.LogonType -in @("Console", "RDP") -and
        $_.UserName -notin @('ANONYMOUS LOGON', 'LOCAL SERVICE', 'NETWORK SERVICE', 'SYSTEM')
    } |
    Sort-Object TimeCreated -Descending

# Export clean CSV
$logons | Export-Csv -Path $outputCsv -NoTypeInformation

Write-Host "Logon data saved to $outputCsv — ready for Excel" -ForegroundColor Green