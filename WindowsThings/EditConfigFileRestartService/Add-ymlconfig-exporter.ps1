# monitoredservices.csv should contain a column called "ComputerName"
# Example:
# ComputerName
# SERVER01
# SERVER02

$csvPath = ".\monitoredservices.csv"

# YAML config content as multi-line string
$configContent = @"
collectors:
 enabled: cpu,logical_disk,net,os,service,system
collector:
 service:
   include: PI AE Manager|pibufss|PI Data Inserter Manager|PI HDAIS|pimsgss|pinetmgr
log:
 level: info

"@

# Loop through each computer listed in the CSV
Import-Csv $csvPath | ForEach-Object {
    $computer = $_.ComputerName
    Write-Host "Processing $computer ..." -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $computer -ScriptBlock {
            param($configContent)

            $configPath = "C:\Program Files\windows_exporter\config.yaml"

            # Backup existing config if it exists
            if (Test-Path $configPath) {
                Copy-Item $configPath "$configPath.bak" -Force
                Write-Host "Backed up existing config.yaml to config.yaml.bak" -ForegroundColor Yellow
            } else {
                Write-Host "No existing config.yaml found, creating new one..." -ForegroundColor Yellow
            }

            # Write new config.yaml file
            Set-Content -Path $configPath -Value $configContent -Force -Encoding UTF8
            Write-Host "Updated $configPath with new configuration." -ForegroundColor Green

            # Restart the windows_exporter service
            if (Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue) {
                Restart-Service -Name "windows_exporter" -Force
                Write-Host "Restarted windows_exporter service." -ForegroundColor Green
            } else {
                Write-Host "Service 'windows_exporter' not found on system." -ForegroundColor Red
            }

        } -ArgumentList $configContent -ErrorAction Stop

    } catch {
        Write-Host "Failed to process $computer : $_" -ForegroundColor Red
    }
}