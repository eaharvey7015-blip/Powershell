<#
.SYNOPSIS
Select an existing vSphere tag from a menu and apply it to multiple VMs.
Generates a CSV report of the results. Compatible with vCenter 8.x.
#>

# Ignore invalid SSL certificates for this script only
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

# Connect to vCenter
$vCenter = Read-Host "Enter vCenter Server FQDN or IP"
Connect-VIServer -Server $vCenter

# Get all tags sorted alphabetically
$tags = Get-Tag | Sort-Object Name
if (-not $tags) {
    Write-Host "No tags found in vCenter." -ForegroundColor Red
    Disconnect-VIServer -Confirm:$false
    exit
}

# Display tags with numbering
Write-Host "`nAvailable Tags:" -ForegroundColor Cyan
for ($i = 0; $i -lt $tags.Count; $i++) {
    Write-Host "$($i+1)) $($tags[$i].Name) (Category: $($tags[$i].Category.Name))"
}

# Prompt for tag selection
$tagChoice = Read-Host "`nEnter the number of the tag to apply"
if ($tagChoice -match '^\d+$' -and $tagChoice -ge 1 -and $tagChoice -le $tags.Count) {
    $selectedTag = $tags[$tagChoice-1]
    Write-Host "Selected Tag: $($selectedTag.Name)" -ForegroundColor Green
} else {
    Write-Host "Invalid selection." -ForegroundColor Red
    Disconnect-VIServer -Confirm:$false
    exit
}

# Prompt for VM list
$csvPath = Read-Host "Enter CSV path with VM names (or press Enter to type manually)"
if ($csvPath -and (Test-Path $csvPath)) {
    $vmList = Import-Csv -Path $csvPath | Select-Object -ExpandProperty ComputerName
} else {
    $vmListInput = Read-Host "Enter VM names separated by commas"
    $vmList = $vmListInput -split "\s*,\s*"
}

# Prepare log file path
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$logFile = "TaggingLog-$timestamp.csv"
$logData = @()

Write-Host "`n=== Tagging Summary ===" -ForegroundColor Cyan
Write-Host "Tag to apply : $($selectedTag.Name)"
Write-Host "VM(s) to process : $($vmList -join ', ')"
Write-Host "Log file path : $logFile"
Write-Host "========================`n"

# Loop through each VM
foreach ($vmName in $vmList) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM '$vmName' not found in vCenter. Skipping..." -ForegroundColor Red
        $logData += [PSCustomObject]@{
            VMName  = $vmName
            Status  = "Not Found"
            Message = "VM not found in vCenter"
        }
        continue
    }

    # Get current tags assigned to the VM
    $currentTags = Get-TagAssignment -Entity $vm | Select-Object -ExpandProperty Tag

    # Lowercase tag names if any exist, else empty array
    if ($currentTags) {
        $currentTagNamesLower = $currentTags.Name | ForEach-Object { $_.ToLower() }
    } else {
        $currentTagNamesLower = @()
    }

    # Case-insensitive match check
    if ($currentTags -and ($currentTags.Name -contains $selectedTag.Name -or
        $currentTagNamesLower -contains $selectedTag.Name.ToLower())) {

        Write-Host "VM '$vmName' already has tag '$($selectedTag.Name)'. Skipping..." -ForegroundColor Yellow
        $logData += [PSCustomObject]@{
            VMName  = $vmName
            Status  = "Already Tagged"
            Message = "VM already has tag '$($selectedTag.Name)'"
        }
        continue
    }

    # Apply tag
    Write-Host "Applying tag '$($selectedTag.Name)' to VM '$vmName'..." -ForegroundColor Green
    New-TagAssignment -Entity $vm -Tag $selectedTag
    $logData += [PSCustomObject]@{
        VMName  = $vmName
        Status  = "Tagged"
        Message = "Tag '$($selectedTag.Name)' applied successfully"
    }
}

Write-Host "`nTagging complete!" -ForegroundColor Cyan

# Export log data to CSV
$logData | Export-Csv -Path $logFile -NoTypeInformation
Write-Host "Detailed report saved to: $logFile" -ForegroundColor Yellow

# Disconnect from vCenter
Disconnect-VIServer -Confirm:$falsecl