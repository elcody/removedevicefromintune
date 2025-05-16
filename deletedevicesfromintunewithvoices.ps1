function Remove-DeviceCompletely {
    param (
        [Parameter(Mandatory=$true, ParameterSetName="DeviceName")]
        [string]$DeviceName,
        
        [Parameter(Mandatory=$true, ParameterSetName="SerialNumber")]
        [string]$SerialNumber,

        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [switch]$NoVoice
    )
    
    # Initialize speech synthesizer
    if (-not $NoVoice) {
        try {
            $speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $voiceEnabled = $true
        } catch {
            Write-Host "Speech synthesis not available on this system. Continuing without voice." -ForegroundColor Yellow
            $voiceEnabled = $false
        }
    } else {
        $voiceEnabled = $false
    }
    
    # Function to speak text with random Mechanicus phrases
    function Speak-WithPraise {
        param([string]$Text, [string]$Color = "White")
        
        # Array of Mechanicus phrases
        $mechanicusPhrases = @(
            "Praise the Omnissiah!",
            "The Machine Spirit is pleased!",
            "For the glory of the Machine God!",
            "The Omnissiah protects!",
            "The Emperor Wills It!",
            "The Omnissiah Wills It!"
          
        )
        
        # Select random phrase
        $randomPhrase = $mechanicusPhrases | Get-Random
        
        # Write to host
        Write-Host $Text -ForegroundColor $Color
        
        # Speak if enabled
        if ($voiceEnabled) {
            $speak.Speak("$Text. $randomPhrase")
        }
    }
    
    try {
        # Ensure we have necessary permissions
        $requiredScopes = @(
            "Device.ReadWrite.All", 
            "DeviceManagementServiceConfig.ReadWrite.All",
            "Directory.ReadWrite.All"
        )
        
        # Check if already connected with proper scopes
        $currentConnection = Get-MgContext
        $needReconnect = $false
        
        if ($null -eq $currentConnection) {
            $needReconnect = $true
        } else {
            foreach ($scope in $requiredScopes) {
                if ($currentConnection.Scopes -notcontains $scope) {
                    $needReconnect = $true
                    break
                }
            }
        }
        
        if ($needReconnect) {
            Speak-WithPraise "Connecting to Microsoft Graph with required permissions..." "Cyan"
            Connect-MgGraph -Scopes $requiredScopes
        }
        
        # Search for the device in Intune
        if ($DeviceName) {
            Speak-WithPraise "Searching for device with name: $DeviceName" "Cyan"
            $filter = "deviceName eq '$DeviceName'"
        } else {
            Speak-WithPraise "Searching for device with serial number: $SerialNumber" "Cyan"
            $filter = "serialNumber eq '$SerialNumber'"
        }
        
        # Get device from Intune
        $intuneDevice = Get-MgDeviceManagementManagedDevice -Filter $filter -All | Select-Object -First 1
        
        # Variables to track what we found
        $foundInIntune = $false
        $foundInAutopilot = $false
        $foundInEntra = $false
        $deviceAzureADId = $null
        $serialNumberToUse = $SerialNumber
        
        # Check if device was found in Intune
        if ($null -ne $intuneDevice) {
            $foundInIntune = $true
            $serialNumberToUse = $intuneDevice.SerialNumber
            $azureADDeviceId = $intuneDevice.AzureADDeviceId
            
            Speak-WithPraise "`nDevice found in Intune:" "Green"
            Speak-WithPraise "  Name: $($intuneDevice.DeviceName)" "White"
            Speak-WithPraise "  Intune ID: $($intuneDevice.Id)" "White"
            Speak-WithPraise "  Serial: $($intuneDevice.SerialNumber)" "White"
            Speak-WithPraise "  Model: $($intuneDevice.Model)" "White"
            Speak-WithPraise "  Azure AD Device ID: $azureADDeviceId" "White"
        } else {
            Speak-WithPraise "Device not found in Intune." "Yellow"
        }
        
        # Search in Autopilot using serial number
        if ($serialNumberToUse) {
            $autopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
            $autopilotDevice = $autopilotDevices | Where-Object { $_.SerialNumber -eq $serialNumberToUse }
            
            if ($autopilotDevice) {
                $foundInAutopilot = $true
                Speak-WithPraise "`nDevice found in Autopilot:" "Green"
                Speak-WithPraise "  Autopilot ID: $($autopilotDevice.Id)" "White"
                Speak-WithPraise "  Serial: $($autopilotDevice.SerialNumber)" "White"
                Speak-WithPraise "  Model: $($autopilotDevice.Model)" "White"
            } else {
                Speak-WithPraise "`nDevice not found in Autopilot." "Yellow"
            }
        }
        
        # Search in Entra ID (Azure AD)
        # Try to find by Azure AD Device ID if we have it from Intune
        if ($azureADDeviceId) {
            $entraDevice = Get-MgDevice -Filter "DeviceId eq '$azureADDeviceId'"
            
            if ($entraDevice) {
                $foundInEntra = $true
                $deviceAzureADId = $entraDevice.Id
                
                Speak-WithPraise "`nDevice found in Entra ID (by DeviceId):" "Green"
                Speak-WithPraise "  Display Name: $($entraDevice.DisplayName)" "White"
                Speak-WithPraise "  Object ID: $($entraDevice.Id)" "White"
                Speak-WithPraise "  Device ID: $($entraDevice.DeviceId)" "White"
            }
        }
        
        # If not found by DeviceId, try by display name if we have it
        if (-not $foundInEntra -and $intuneDevice -and $intuneDevice.DeviceName) {
            $entraDevices = Get-MgDevice -Filter "DisplayName eq '$($intuneDevice.DeviceName)'"
            
            if ($entraDevices -and $entraDevices.Count -gt 0) {
                $foundInEntra = $true
                $entraDevice = $entraDevices[0]
                $deviceAzureADId = $entraDevice.Id
                
                Speak-WithPraise "`nDevice found in Entra ID (by name):" "Green"
                Speak-WithPraise "  Display Name: $($entraDevice.DisplayName)" "White"
                Speak-WithPraise "  Object ID: $($entraDevice.Id)" "White"
                Speak-WithPraise "  Device ID: $($entraDevice.DeviceId)" "White"
                
                if ($entraDevices.Count -gt 1) {
                    Speak-WithPraise "  Warning: Multiple devices found with this name in Entra ID." "Yellow"
                }
            }
        }
        
        if (-not $foundInEntra) {
            Speak-WithPraise "`nDevice not found in Entra ID." "Yellow"
        }
        
        # If device not found anywhere
        if (-not ($foundInIntune -or $foundInAutopilot -or $foundInEntra)) {
            Speak-WithPraise "`nDevice not found in any system (Intune, Autopilot, or Entra ID)." "Red"
            return
        }
        
        # Get confirmation to delete
        if (-not $Force) {
            Speak-WithPraise "`n==================== REMOVAL SUMMARY ====================" "Cyan"
            Speak-WithPraise "The following actions will be performed:" "Cyan"
            
            if ($foundInIntune) {
                Speak-WithPraise "- Remove device from Intune" "White"
            }
            
            if ($foundInAutopilot) {
                Speak-WithPraise "- Remove device from Autopilot" "White"
            }
            
            if ($foundInEntra) {
                Speak-WithPraise "- Remove device from Entra ID (Azure AD)" "White"
            }
            
            Speak-WithPraise "=======================================================" "Cyan"
            
            $confirm = Read-Host "`nProceed with device removal? (Y/N)"
            if ($confirm -ne "Y" -and $confirm -ne "y") {
                Speak-WithPraise "Operation canceled." "Yellow"
                return
            }
        }
        
        # Start removal process
        
        # 1. Remove from Intune
        if ($foundInIntune) {
            try {
                Speak-WithPraise "`nRemoving device from Intune..." "Cyan"
                Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $intuneDevice.Id -ErrorAction Stop
                Speak-WithPraise "Successfully removed from Intune." "Green"
            }
            catch {
                Speak-WithPraise "Error removing from Intune: $_" "Red"
            }
        }
        
        # 2. Remove from Autopilot
        if ($foundInAutopilot) {
            try {
                Speak-WithPraise "Removing device from Autopilot..." "Cyan"
                Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $autopilotDevice.Id -ErrorAction Stop
                Speak-WithPraise "Successfully removed from Autopilot." "Green"
            }
            catch {
                Speak-WithPraise "Error removing from Autopilot: $_" "Red"
            }
        }
        
        # 3. Remove from Entra ID (Azure AD)
        if ($foundInEntra) {
            try {
                Speak-WithPraise "Removing device from Entra ID (Azure AD)..." "Cyan"
                Remove-MgDevice -DeviceId $deviceAzureADId -ErrorAction Stop
                Speak-WithPraise "Successfully removed from Entra ID." "Green"
            }
            catch {
                Speak-WithPraise "Error removing from Entra ID: $_" "Red"
            }
        }
        
        Speak-WithPraise "`nDevice removal process completed." "Green"
        
        # Special completion message with extended phrase
        if ($voiceEnabled) {
            $finalPhraises = @(
                "The machine spirit has been properly released from its duty. Praise the Omnissiah!",
                "This device has been returned to the void. Glory to the Omnissiah!",
                "The binary exorcism is complete. The Omnissiah's will is done!",
                "Another sacred task completed for the Machine God. The cogitators are pleased!",
                "Device purged from all records as the Omnissiah commands!"
            )
            $finalMessage = $finalPhraises | Get-Random
            $speak.Speak($finalMessage)
        }
    }
    catch {
        Speak-WithPraise "`nUnexpected error occurred:" "Red"
        Speak-WithPraise $_ "Red"
        Write-Host $_.Exception.StackTrace -ForegroundColor DarkRed
    }
    finally {
        # Dispose of speech synthesizer
        if ($voiceEnabled) {
            $speak.Dispose()
        }
    }
}

# Usage examples:
 Remove-DeviceCompletely -SerialNumber "Serial Number"
# OR
 #Remove-DeviceCompletely -DeviceName "Device name"
# 
# To run without voice:
# Remove-DeviceCompletely -SerialNumber "Serial Number" -NoVoice
