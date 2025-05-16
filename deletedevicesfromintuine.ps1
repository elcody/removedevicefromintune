# Install required modules if not already installed
##Install-Module Microsoft.Graph.Intune -force
#Install-Module Microsoft.Graph.DeviceManagement.Administration -force
#Install-Module Microsoft.Graph.Identity.DirectoryManagement -force

Connect-MgGraph -Scopes "Device.ReadWrite.All", "DeviceManagementServiceConfig.ReadWrite.All"
function Remove-DeviceCompletely {
    param (
        [Parameter(Mandatory=$true, ParameterSetName="DeviceName")]
        [string]$DeviceName,
        
        [Parameter(Mandatory=$true, ParameterSetName="SerialNumber")]
        [string]$SerialNumber,

        [Parameter()]
        [switch]$Force
    )
    
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
            Write-Host "Connecting to Microsoft Graph with required permissions..." -ForegroundColor Cyan
            Connect-MgGraph -Scopes $requiredScopes
        }
        
        # Search for the device in Intune
        if ($DeviceName) {
            Write-Host "Searching for device with name: $DeviceName" -ForegroundColor Cyan
            $filter = "deviceName eq '$DeviceName'"
        } else {
            Write-Host "Searching for device with serial number: $SerialNumber" -ForegroundColor Cyan
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
            
            Write-Host "`nDevice found in Intune:" -ForegroundColor Green
            Write-Host "  Name: $($intuneDevice.DeviceName)" -ForegroundColor White
            Write-Host "  Intune ID: $($intuneDevice.Id)" -ForegroundColor White
            Write-Host "  Serial: $($intuneDevice.SerialNumber)" -ForegroundColor White
            Write-Host "  Model: $($intuneDevice.Model)" -ForegroundColor White
            Write-Host "  Azure AD Device ID: $azureADDeviceId" -ForegroundColor White
        } else {
            Write-Host "Device not found in Intune." -ForegroundColor Yellow
        }
        
        # Search in Autopilot using serial number
        if ($serialNumberToUse) {
            $autopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
            $autopilotDevice = $autopilotDevices | Where-Object { $_.SerialNumber -eq $serialNumberToUse }
            
            if ($autopilotDevice) {
                $foundInAutopilot = $true
                Write-Host "`nDevice found in Autopilot:" -ForegroundColor Green
                Write-Host "  Autopilot ID: $($autopilotDevice.Id)" -ForegroundColor White
                Write-Host "  Serial: $($autopilotDevice.SerialNumber)" -ForegroundColor White
                Write-Host "  Model: $($autopilotDevice.Model)" -ForegroundColor White
            } else {
                Write-Host "`nDevice not found in Autopilot." -ForegroundColor Yellow
            }
        }
        
        # Search in Entra ID (Azure AD)
        # Try to find by Azure AD Device ID if we have it from Intune
        if ($azureADDeviceId) {
            $entraDevice = Get-MgDevice -Filter "DeviceId eq '$azureADDeviceId'"
            
            if ($entraDevice) {
                $foundInEntra = $true
                $deviceAzureADId = $entraDevice.Id
                
                Write-Host "`nDevice found in Entra ID (by DeviceId):" -ForegroundColor Green
                Write-Host "  Display Name: $($entraDevice.DisplayName)" -ForegroundColor White
                Write-Host "  Object ID: $($entraDevice.Id)" -ForegroundColor White
                Write-Host "  Device ID: $($entraDevice.DeviceId)" -ForegroundColor White
            }
        }
        
        # If not found by DeviceId, try by display name if we have it
        if (-not $foundInEntra -and $intuneDevice -and $intuneDevice.DeviceName) {
            $entraDevices = Get-MgDevice -Filter "DisplayName eq '$($intuneDevice.DeviceName)'"
            
            if ($entraDevices -and $entraDevices.Count -gt 0) {
                $foundInEntra = $true
                $entraDevice = $entraDevices[0]
                $deviceAzureADId = $entraDevice.Id
                
                Write-Host "`nDevice found in Entra ID (by name):" -ForegroundColor Green
                Write-Host "  Display Name: $($entraDevice.DisplayName)" -ForegroundColor White
                Write-Host "  Object ID: $($entraDevice.Id)" -ForegroundColor White
                Write-Host "  Device ID: $($entraDevice.DeviceId)" -ForegroundColor White
                
                if ($entraDevices.Count -gt 1) {
                    Write-Host "  Warning: Multiple devices found with this name in Entra ID." -ForegroundColor Yellow
                }
            }
        }
        
        if (-not $foundInEntra) {
            Write-Host "`nDevice not found in Entra ID." -ForegroundColor Yellow
        }
        
        # If device not found anywhere
        if (-not ($foundInIntune -or $foundInAutopilot -or $foundInEntra)) {
            Write-Host "`nDevice not found in any system (Intune, Autopilot, or Entra ID)." -ForegroundColor Red
            return
        }
        
        # Get confirmation to delete
        if (-not $Force) {
            Write-Host "`n==================== REMOVAL SUMMARY ====================" -ForegroundColor Cyan
            Write-Host "The following actions will be performed:" -ForegroundColor Cyan
            
            if ($foundInIntune) {
                Write-Host "- Remove device from Intune" -ForegroundColor White
            }
            
            if ($foundInAutopilot) {
                Write-Host "- Remove device from Autopilot" -ForegroundColor White
            }
            
            if ($foundInEntra) {
                Write-Host "- Remove device from Entra ID (Azure AD)" -ForegroundColor White
            }
            
            Write-Host "=======================================================" -ForegroundColor Cyan
            
            $confirm = Read-Host "`nProceed with device removal? (Y/N)"
            if ($confirm -ne "Y" -and $confirm -ne "y") {
                Write-Host "Operation canceled." -ForegroundColor Yellow
                return
            }
        }
        
        # Start removal process
        
        # 1. Remove from Intune
        if ($foundInIntune) {
            try {
                Write-Host "`nRemoving device from Intune..." -ForegroundColor Cyan
                Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $intuneDevice.Id -ErrorAction Stop
                Write-Host "Successfully removed from Intune." -ForegroundColor Green
            }
            catch {
                Write-Host "Error removing from Intune: $_" -ForegroundColor Red
            }
        }
        
        # 2. Remove from Autopilot
        if ($foundInAutopilot) {
            try {
                Write-Host "Removing device from Autopilot..." -ForegroundColor Cyan
                Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $autopilotDevice.Id -ErrorAction Stop
                Write-Host "Successfully removed from Autopilot." -ForegroundColor Green
            }
            catch {
                Write-Host "Error removing from Autopilot: $_" -ForegroundColor Red
            }
        }
        
        # 3. Remove from Entra ID (Azure AD)
        if ($foundInEntra) {
            try {
                Write-Host "Removing device from Entra ID (Azure AD)..." -ForegroundColor Cyan
                Remove-MgDevice -DeviceId $deviceAzureADId -ErrorAction Stop
                Write-Host "Successfully removed from Entra ID." -ForegroundColor Green
            }
            catch {
                Write-Host "Error removing from Entra ID: $_" -ForegroundColor Red
            }
        }
        
        Write-Host "`nDevice removal process completed." -ForegroundColor Green
    }
    catch {
        Write-Host "`nUnexpected error occurred:" -ForegroundColor Red
        Write-Host $_ -ForegroundColor Red
        Write-Host $_.Exception.StackTrace -ForegroundColor DarkRed
    }
}


# Usage examples:
# By device name:
#Remove-DeviceFromIntuneAndAutopilot -DeviceName "DEVICE NAME"

# By serial number:
Remove-DeviceFromIntuneAndAutopilot -SerialNumber 'SERIAL NUMBER'