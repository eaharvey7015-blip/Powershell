<#
.SYNOPSIS
    Bulk Local Administrator Password Update Script.

.DESCRIPTION
    This script prompts the user to select a server list file via a GUI file picker.
    The file can be either:
        - CSV with a column named 'Server', or
        - TXT with one server name per line.
    
    The script then securely prompts the user via a masked GUI textbox for the new
    local Administrator password (supports copy & paste of long random passwords).
    
    For each server in the list:
        - Connects using PowerShell Remoting (WinRM).
        - Detects if Set-LocalUser cmdlet is available (Windows Server 2016+ or Win10).
        - Falls back to 'net user' command for older OS versions.
        - Changes the password of the local 'Administrator' account.
        - Provides on-screen feedback for each server processed.

    Designed for sysadmins needing secure bulk password changes without hardcoding
    credentials or file paths.

.PARAMETER None
    This script does not accept traditional parameters — all input is gathered
    interactively (file picker & GUI password prompt).

.EXAMPLE
    PS C:\> .\Bulk-AdminPasswordUpdate.ps1
    # Prompts you to pick the file, paste the password, and changes the local
    # admin password on all listed servers.

.INPUTS
    None — uses interactive GUI prompts for all input.

.OUTPUTS
    On-screen status messages for each server processed.
    Optionally, can be extended to output a CSV or log file.

.REQUIREMENTS
    - Administrative rights on all target servers.
    - PowerShell Remoting (WinRM) enabled on all target servers.
      Enable with: Enable-PSRemoting -Force
    - Network connectivity to all servers.
    - For CSV input, the first line must have "Server" as a column header.
    - PowerShell 5.1+ recommended for maximum compatibility.

.NOTES
    Author: Anthony Harvey
    Version: 1.0
    Creation Date: 2024-06-05
    Tested On: Windows 10, Windows Server 2012 R2, 2016, 2019
    Purpose: Secure bulk update of local Administrator passwords.

    Security Notes:
    - No passwords are hardcoded.
    - Password captured only in memory, cleared at end of script.
    - Run over trusted admin network or in secure session.

.LINK
    Company IT Scripts Repository
    Microsoft Docs - Set-LocalUser Cmdlet: https://learn.microsoft.com/powershell/module/microsoft.powershell.localaccounts/set-localuser
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

### 1. Prompt for server list file via file selection dialog ###
$OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
$OpenFileDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
$OpenFileDialog.Filter = "CSV or TXT files (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*"
$OpenFileDialog.Title = "Select Server List File"

if ($OpenFileDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "No file selected. Exiting." -ForegroundColor Yellow
    exit
}
$ServerListPath = $OpenFileDialog.FileName

### 2. Read server list (CSV column 'Server' or plain text) ###
try {
    $ServerData = Import-Csv $ServerListPath -ErrorAction Stop
    if ($ServerData -and $ServerData[0].Server) {
        $Servers = $ServerData.Server
        Write-Host "Loaded $(($Servers).Count) servers from CSV."
    } else {
        Write-Host "CSV does not have a 'Server' column. Treating as plain text."
        $Servers = Get-Content $ServerListPath
    }
} catch {
    Write-Host "Not a proper CSV. Reading as plain text..."
    $Servers = Get-Content $ServerListPath
}

$Servers = $Servers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if ($Servers.Count -eq 0) {
    Write-Error "No server names found in file."
    exit
}

### 3. Prompt for password via masked input box ###
$form = New-Object System.Windows.Forms.Form
$form.Text = "Enter New Local Administrator Password"
$form.Size = New-Object System.Drawing.Size(400,150)
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Text = "Paste the new local Administrator password below:"
$label.AutoSize = $true
$label.Top = 20
$label.Left = 20
$form.Controls.Add($label)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Width = 340
$textBox.Top = 50
$textBox.Left = 20
$textBox.UseSystemPasswordChar = $true
$form.Controls.Add($textBox)

$okButton = New-Object System.Windows.Forms.Button
$okButton.Text = "OK"
$okButton.Top = 80
$okButton.Left = 280
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.AcceptButton = $okButton
$form.Controls.Add($okButton)

if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "Password entry cancelled. Exiting." -ForegroundColor Yellow
    exit
}

$PlainPassword = $textBox.Text
if ([string]::IsNullOrWhiteSpace($PlainPassword)) {
    Write-Error "No password entered. Exiting."
    exit
}

Write-Host "`nStarting password change for local Administrator on each server..." -ForegroundColor Green

### 4. Change password remotely on each server ###
foreach ($Server in $Servers) {
    $Server = $Server.Trim()
    Write-Host "Processing $Server..." -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($Password)
            try {
                if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
                    # Windows Server 2016+ method
                    $AdminUser = Get-LocalUser -Name "Administrator"
                    $AdminUser | Set-LocalUser -Password (ConvertTo-SecureString $Password -AsPlainText -Force)
                    Write-Host "[$env:COMPUTERNAME] Password changed via Set-LocalUser."
                } else {
                    # Older OS fallback
                    cmd /c "net user Administrator $Password"
                    Write-Host "[$env:COMPUTERNAME] Password changed via net user."
                }
            } catch {
                Write-Warning "[$env:COMPUTERNAME] Failed to change password: $_"
            }
        } -ArgumentList $PlainPassword -ErrorAction Stop
    } catch {
        Write-Warning "Could not connect to $Server : $_"
    }
}

### 5. Clear password variable from memory ###
$PlainPassword = $null

Write-Host "`nAll done." -ForegroundColor Green