& {
Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
 
# Ensure TLS 1.2 is enabled for secure downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 
# Prompt for Store-Specific Account Credentials
Write-Host "==========================================" -ForegroundColor Yellow
$TargetUser = Read-Host "Enter Username for this store account"
$TargetPasswordPlain = Read-Host "Enter Password for $TargetUser" -AsSecureString
$TargetPasswordText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TargetPasswordPlain))
Write-Host "==========================================" -ForegroundColor Yellow
 
function Download-Clean {
    param (
        [string]$Url,
        [string]$Destination,
        [string]$Name
    )
    Write-Host "Downloading $Name..." -ForegroundColor Cyan
    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            curl.exe -sSL -L --connect-timeout 15 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o $Destination $Url
        } else {
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            $webClient.DownloadFile($Url, $Destination)
        }
 
        if (Test-Path $Destination) {
            Unblock-File -Path $Destination -ErrorAction SilentlyContinue
            Write-Host " -> Finished & Unblocked: $Name" -ForegroundColor Green
        } else {
            throw "Download failed to create file."
        }
    } catch {
        Write-Host " -> FAILED: $Name ($($_.Exception.Message))" -ForegroundColor Red
    }
}
 
Write-Host "`nStarting PC Setup for User: $TargetUser..." -ForegroundColor Green
 
# 1. TIMEZONE & POWER SETTINGS
Write-Host "`n[1/5] Setting Timezone & Power Settings..." -ForegroundColor Cyan
Set-TimeZone -Id "Eastern Standard Time"
 
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
 
powercfg /change monitor-timeout-dc 0
powercfg /change disk-timeout-dc 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-dc 0
 
# 2. DEFENDER & PRINTERS
Write-Host "`n[2/5] Cleaning Printers & Enabling Defender..." -ForegroundColor Cyan
Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
Get-Printer | Where-Object { $_.Name -notlike "*Microsoft*" -and $_.Name -notlike "*Fax*" } | Remove-Printer -ErrorAction SilentlyContinue
 
# 3. UNINSTALL MCAFEE
Write-Host "`n[3/5] Removing McAfee..." -ForegroundColor Cyan
Get-Package -Name "*McAfee*" -ErrorAction SilentlyContinue | Uninstall-Package -Force -ErrorAction SilentlyContinue
Get-CimInstance -ClassName Win32_Product -Filter "Name LIKE '%McAfee%'" -ErrorAction SilentlyContinue | ForEach-Object { $_.Uninstall() }
 
# 4. USER MANAGEMENT, AUTOLOGON & TRUST POLICIES
Write-Host "`n[4/5] Setting up User '$TargetUser', AutoLogon & Bypassing Security Prompts..." -ForegroundColor Cyan
 
# Create Local User
New-LocalUser -Name $TargetUser -Password $TargetPasswordPlain -FullName $TargetUser -Description "Store User Account" -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Users" -Member $TargetUser -ErrorAction SilentlyContinue
 
# Standard Security Questions
$UserSID = (Get-LocalUser -Name $TargetUser).SID.Value
$SecQuestionsRegistry = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountManagement\SecurityQuestions\$UserSID"
if (-not (Test-Path $SecQuestionsRegistry)) { New-Item -Path $SecQuestionsRegistry -Force | Out-Null }
 
Set-ItemProperty -Path $SecQuestionsRegistry -Name "Question1" -Value "What was your first pet's name?" -Force
Set-ItemProperty -Path $SecQuestionsRegistry -Name "Answer1" -Value "mcxxmx1955" -Force
Set-ItemProperty -Path $SecQuestionsRegistry -Name "Question2" -Value "What city were you born in?" -Force
Set-ItemProperty -Path $SecQuestionsRegistry -Name "Answer2" -Value "mcxxmx1955" -Force
Set-ItemProperty -Path $SecQuestionsRegistry -Name "Question3" -Value "What was your childhood nickname?" -Force
Set-ItemProperty -Path $SecQuestionsRegistry -Name "Answer3" -Value "mcxxmx1955" -Force
 
# TrustManager Settings for ClickOnce Apps (.NET)
$TrustPaths = @(
    "HKLM:\SOFTWARE\Microsoft\.NETFramework\Security\TrustManager\PromptingLevel",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\Security\TrustManager\PromptingLevel"
)
foreach ($path in $TrustPaths) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name "Internet" -Value "Enabled" -Force
    Set-ItemProperty -Path $path -Name "MyComputer" -Value "Enabled" -Force
    Set-ItemProperty -Path $path -Name "LocalIntranet" -Value "Enabled" -Force
    Set-ItemProperty -Path $path -Name "UntrustedSites" -Value "Enabled" -Force
}
 
# Remove unwanted local accounts
$KeepUsers = @($TargetUser, "Admin", "Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount", $env:USERNAME)
Get-LocalUser | Where-Object { $KeepUsers -notcontains $_.Name } | ForEach-Object {
    Remove-LocalUser -Name $_.Name -ErrorAction SilentlyContinue
}
 
# Bypass OOBE / Privacy Prompt
$OOBEPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"
if (-not (Test-Path $OOBEPath)) { New-Item -Path $OOBEPath -Force | Out-Null }
Set-ItemProperty -Path $OOBEPath -Name "DisablePrivacyExperience" -Value 1 -Type DWord -Force
 
$ConsentPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
Set-ItemProperty -Path $ConsentPath -Name "PrivacyConsentStatus" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $ConsentPath -Name "ProtectYourPC" -Value 3 -Type DWord -Force
 
# Configure AutoLogon
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "1" -Force
Set-ItemProperty -Path $WinlogonPath -Name "DefaultUserName" -Value $TargetUser -Force
Set-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -Value $TargetPasswordText -Force
 
# 5. DOWNLOADS & SYSTEM INSTALLATIONS
Write-Host "`n[5/5] Downloading & Installing Applications..." -ForegroundColor Cyan
 
# A. Google Chrome
Download-Clean -Url "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -Destination "$env:TEMP\chrome_installer.exe" -Name "Google Chrome"
if (Test-Path "$env:TEMP\chrome_installer.exe") {
    Write-Host "Installing Google Chrome..." -ForegroundColor Cyan
    Start-Process "$env:TEMP\chrome_installer.exe" -ArgumentList "/silent /install" -Wait
}
 
# B. iTunes (Installed System-Wide via Admin Privileges)
Download-Clean -Url "https://www.apple.com/itunes/download/win64" -Destination "$env:TEMP\iTunesSetup.exe" -Name "iTunes Installer"
if (Test-Path "$env:TEMP\iTunesSetup.exe") {
    Write-Host "Installing iTunes System-Wide..." -ForegroundColor Cyan
    Start-Process "$env:TEMP\iTunesSetup.exe" -ArgumentList "/quiet /norestart" -Wait
    Write-Host " -> iTunes Installation Triggered!" -ForegroundColor Green
}
 
# C. Fingerprint Driver
Download-Clean -Url "https://fpapp.mcxxmxf.com/rte_x64.msi" -Destination "$env:TEMP\rte_x64.msi" -Name "Fingerprint Driver"
if (Test-Path "$env:TEMP\rte_x64.msi") {
    Write-Host "Installing Fingerprint Driver..." -ForegroundColor Cyan
    Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\rte_x64.msi`" /qn /norestart" -Wait
}
 
# D. Downloads for Local User Session
Download-Clean -Url "https://nmap.org/dist/nmap-7.95-setup.exe" -Destination "C:\Users\Public\Desktop\nmap-setup.exe" -Name "Nmap Scanner"
 
$fpSetupPath = "C:\Users\Public\Desktop\Fingerprint_Setup.exe"
Download-Clean -Url "https://fpapp.mcxxmxf.com/setup.exe" -Destination $fpSetupPath -Name "Fingerprint App"
 
# Create User Startup Script for Fingerprint Setup (Delayed Execution for Desktop Loading)
$startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\RunUserSetups.bat"
@'
@echo off
timeout /t 8 /nobreak >nul
 
if exist "C:\Users\Public\Desktop\Fingerprint_Setup.exe" (
    start "" "C:\Users\Public\Desktop\Fingerprint_Setup.exe"
)
 
del "%~f0"
'@ | Out-File -FilePath $startupPath -Encoding ascii -Force
 
# Final Password Sync & Background Windows Updates
Write-Host "`nSyncing credentials for '$TargetUser'..." -ForegroundColor Cyan
Set-LocalUser -Name $TargetUser -Password $TargetPasswordPlain
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -Value $TargetPasswordText -Force
 
Write-Host "`nLaunching Windows Update in background..." -ForegroundColor Cyan
Start-Process -FilePath "usoclient.exe" -ArgumentList "StartScan" -WindowStyle Hidden
Start-Process -FilePath "usoclient.exe" -ArgumentList "StartDownload" -WindowStyle Hidden
Start-Process -FilePath "usoclient.exe" -ArgumentList "StartInstall" -WindowStyle Hidden
 
Write-Host "`n==========================================" -ForegroundColor Green
Write-Host " Admin Setup Completed Successfully!" -ForegroundColor Green
Write-Host " Rebooting to log into $TargetUser..." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
 
Restart-Computer -Force
}
