function Remove-DeviceFromIntuneAutopilotAndEntra {
    param (
        [Parameter(Mandatory=$true, ParameterSetName="DeviceName")]
        [string]$DeviceName,
        
        [Parameter(Mandatory=$true, ParameterSetName="SerialNumber")]
        [string]$SerialNumber,

        [Parameter()]
        [switch]$Force
    )
    
    try {
        # Search for the device
        if ($DeviceName) {
            Write-Host "Searching for device with name: $DeviceName" -ForegroundColor Cyan
            $filter = "deviceName eq '$DeviceName'"
        } else {
            Write-Host "Searching for device with serial number: $SerialNumber" -ForegroundColor Cyan
            $filter = "serialNumber eq '$SerialNumber'"
        }
        
        # Get device from Intune
        $intuneDevice = Get-MgDeviceManagementManagedDevice -Filter $filter -All | Select-Object -First 1
        
        # Check if device was found in Intune
        if ($null -eq $intuneDevice) {
            Write-Host "No device found in Intune." -ForegroundColor Yellow
            
            # Check Autopilot regardless of search method
            Write-Host "Checking Autopilot..." -ForegroundColor Cyan
            $autopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
            $autopilotDevice = $null
            
            if ($SerialNumber) {
                # Search by serial number
                $autopilotDevice = $autopilotDevices | Where-Object { $_.SerialNumber -eq $SerialNumber }
            } elseif ($DeviceName) {
                # Search by device name - Autopilot devices might have the name in various properties
                $autopilotDevice = $autopilotDevices | Where-Object { 
                    $_.DisplayName -eq $DeviceName -or 
                    $_.DisplayName -like "*$DeviceName*" -or
                    $_.UserPrincipalName -like "*$DeviceName*"
                }
            }
            
            if ($autopilotDevice) {
                Write-Host "Found device in Autopilot:" -ForegroundColor Green
                Write-Host "  Display Name: $($autopilotDevice.DisplayName)" -ForegroundColor White
                Write-Host "  Serial Number: $($autopilotDevice.SerialNumber)" -ForegroundColor White
                Write-Host "  Model: $($autopilotDevice.Model)" -ForegroundColor White
                
                if ($Force -or (Read-Host "Remove from Autopilot? (Y/N)") -eq 'Y') {
                    try {
                        Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $autopilotDevice.Id
                        Write-Host "Device removed from Autopilot." -ForegroundColor Green
                    }
                    catch {
                        if ($_.Exception.Message -like "*less than 30minutes ago*") {
                            Write-Host "Autopilot deletion already in progress (30-minute cooldown). Will complete automatically." -ForegroundColor Yellow
                        } else {
                            throw
                        }
                    }
                }
            } else {
                Write-Host "Device not found in Autopilot." -ForegroundColor Yellow
            }
            
            # Still check Entra ID even if not found in Intune/Autopilot
            # Add pause if we removed something from Autopilot
            if ($autopilotDevice) {
                Write-Host "`nWaiting 30 seconds for Autopilot changes to propagate before checking Entra ID..." -ForegroundColor Yellow
                Write-Host "This prevents conflicts since Entra ID devices cannot be removed while still in Autopilot." -ForegroundColor Yellow
                
                # Countdown timer for better user experience
                for ($i = 30; $i -gt 0; $i--) {
                    Write-Host "`rWaiting... $i seconds remaining" -NoNewline -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
                Write-Host "`rWait complete. Proceeding with Entra ID check...                    " -ForegroundColor Green
            }
            
            Write-Host "`nChecking Entra ID for device..." -ForegroundColor Cyan
            $entraDevices = @()
            
            if ($DeviceName) {
                # Primary search: exact match
                $entraDevices = Get-MgDevice -Filter "displayName eq '$DeviceName'" -All
                
                # Secondary search: partial match in case of slight naming differences
                if ($entraDevices.Count -eq 0) {
                    Write-Host "Exact name match not found, trying partial match..." -ForegroundColor Yellow
                    $allEntraDevices = Get-MgDevice -All -Property Id,DisplayName,DeviceId,OperatingSystem
                    $entraDevices = $allEntraDevices | Where-Object { $_.DisplayName -like "*$DeviceName*" }
                }
            } elseif ($SerialNumber) {
                # Search by serial number - multiple methods
                Write-Host "Searching Entra ID by serial number (multiple methods)..." -ForegroundColor Cyan
                $allEntraDevices = Get-MgDevice -All -Property Id,DisplayName,DeviceId,OperatingSystem,PhysicalIds
                
                # Method 1: PhysicalIds search
                $entraDevices = $allEntraDevices | Where-Object { 
                    $_.PhysicalIds -contains "[HWID]:$SerialNumber" -or 
                    $_.PhysicalIds -like "*$SerialNumber*" 
                }
                
                # Method 2: Device name contains serial (common pattern)
                if ($entraDevices.Count -eq 0) {
                    Write-Host "PhysicalIds search failed, trying device name pattern..." -ForegroundColor Yellow
                    $entraDevices = $allEntraDevices | Where-Object { 
                        $_.DisplayName -like "*$SerialNumber*"
                    }
                }
            }
            
            if ($entraDevices.Count -gt 0) {
                foreach ($entraDevice in $entraDevices) {
                    Write-Host "Found device in Entra ID:" -ForegroundColor Green
                    Write-Host "  Name: $($entraDevice.DisplayName)" -ForegroundColor White
                    Write-Host "  ID: $($entraDevice.Id)" -ForegroundColor White
                    
                    if ($Force -or (Read-Host "Remove '$($entraDevice.DisplayName)' from Entra ID? (Y/N)") -eq 'Y') {
                        Remove-MgDevice -DeviceId $entraDevice.Id -ErrorAction Stop
                        Write-Host "Device removed from Entra ID." -ForegroundColor Green
                    }
                }
            } else {
                Write-Host "Device not found in Entra ID with current search methods." -ForegroundColor Yellow
                Write-Host "You may need to manually remove it from the Azure portal if it still exists." -ForegroundColor Yellow
            }
            
            return
        }
        
        # Display device information
        Write-Host "`nDevice found in Intune:" -ForegroundColor Green
        Write-Host "  Name: $($intuneDevice.DeviceName)" -ForegroundColor White
        Write-Host "  ID: $($intuneDevice.Id)" -ForegroundColor White
        Write-Host "  Serial: $($intuneDevice.SerialNumber)" -ForegroundColor White
        Write-Host "  Model: $($intuneDevice.Model)" -ForegroundColor White
        Write-Host "  Azure AD Device ID: $($intuneDevice.AzureAdDeviceId)" -ForegroundColor White
        
        # Get confirmation
        if (-not $Force) {
            $confirm = Read-Host "`nRemove this device from Intune, Autopilot, and Entra ID? (Y/N)"
            if ($confirm -ne "Y" -and $confirm -ne "y") {
                Write-Host "Operation canceled." -ForegroundColor Yellow
                return
            }
        }
        
        # Step 1: Remove from Intune
        Write-Host "`n[1/3] Removing from Intune..." -ForegroundColor Cyan
        Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $intuneDevice.Id -ErrorAction Stop
        Write-Host "Successfully removed from Intune." -ForegroundColor Green
        
        # Step 2: Remove from Autopilot
        $serialNumber = $intuneDevice.SerialNumber
        if ($serialNumber) {
            Write-Host "`n[2/3] Checking Autopilot..." -ForegroundColor Cyan
            $autopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
            $autopilotDevice = $autopilotDevices | Where-Object { $_.SerialNumber -eq $serialNumber }
            
            if ($autopilotDevice) {
                Write-Host "Found in Autopilot. Removing..." -ForegroundColor Cyan
                try {
                    Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $autopilotDevice.Id -ErrorAction Stop
                    Write-Host "Successfully removed from Autopilot." -ForegroundColor Green
                } catch {
                    if ($_.Exception.Message -like "*less than 30minutes ago*") {
                        Write-Host "Autopilot deletion already in progress (30-minute cooldown). Will complete automatically." -ForegroundColor Yellow
                    } else {
                        throw
                    }
                }
            } else {
                Write-Host "Device not found in Autopilot." -ForegroundColor Yellow
            }
        }
        
        # Step 3: Remove from Entra ID (improved search logic)
        # Add pause to allow Autopilot removal to propagate
        if ($serialNumber) {
            Write-Host "`nWaiting 30 seconds for Autopilot changes to propagate before removing from Entra ID..." -ForegroundColor Yellow
            Write-Host "This prevents conflicts since Entra ID devices cannot be removed while still in Autopilot." -ForegroundColor Yellow
            
            # Countdown timer for better user experience
            for ($i = 30; $i -gt 0; $i--) {
                Write-Host "`rWaiting... $i seconds remaining" -NoNewline -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            Write-Host "`rWait complete. Proceeding with Entra ID removal...                    " -ForegroundColor Green
        }
        
        Write-Host "`n[3/3] Removing from Entra ID..." -ForegroundColor Cyan
        
        $entraDevice = $null
        $deviceNameToSearch = $intuneDevice.DeviceName
        
        # Method 1: Try to find by Azure AD Device ID from Intune
        if ($intuneDevice.AzureAdDeviceId) {
            Write-Host "Searching by Azure AD Device ID..." -ForegroundColor Cyan
            try {
                $entraDevice = Get-MgDevice -DeviceId $intuneDevice.AzureAdDeviceId -ErrorAction SilentlyContinue
                if ($entraDevice) {
                    Write-Host "Found device by Azure AD Device ID." -ForegroundColor Green
                }
            } catch {
                Write-Host "Could not find device by Azure AD Device ID." -ForegroundColor Yellow
            }
        }
        
        # Method 2: Search by exact display name
        if (-not $entraDevice) {
            Write-Host "Searching by device name: $deviceNameToSearch" -ForegroundColor Cyan
            $entraDevices = Get-MgDevice -Filter "displayName eq '$deviceNameToSearch'" -All
            if ($entraDevices.Count -gt 0) {
                $entraDevice = $entraDevices[0]
                Write-Host "Found device by exact name match." -ForegroundColor Green
                if ($entraDevices.Count -gt 1) {
                    Write-Host "Multiple devices found with same name. Using first match." -ForegroundColor Yellow
                }
            }
        }
        
        # Method 3: Search by partial name match
        if (-not $entraDevice) {
            Write-Host "Exact name match failed, trying partial match..." -ForegroundColor Yellow
            $allEntraDevices = Get-MgDevice -All -Property Id,DisplayName,DeviceId,OperatingSystem
            $partialMatches = $allEntraDevices | Where-Object { 
                $_.DisplayName -like "*$deviceNameToSearch*" -or 
                $deviceNameToSearch -like "*$($_.DisplayName)*"
            }
            
            if ($partialMatches.Count -gt 0) {
                $entraDevice = $partialMatches[0]
                Write-Host "Found device by partial name match: $($entraDevice.DisplayName)" -ForegroundColor Green
            }
        }
        
        # Method 4: Search by serial number in device name (common pattern)
        if (-not $entraDevice -and $serialNumber) {
            Write-Host "Trying to find device by serial number in name..." -ForegroundColor Yellow
            $allEntraDevices = Get-MgDevice -All -Property Id,DisplayName,DeviceId,OperatingSystem
            $serialMatches = $allEntraDevices | Where-Object { 
                $_.DisplayName -like "*$serialNumber*"
            }
            
            if ($serialMatches.Count -gt 0) {
                $entraDevice = $serialMatches[0]
                Write-Host "Found device by serial number in name: $($entraDevice.DisplayName)" -ForegroundColor Green
            }
        }
        
        if ($entraDevice) {
            Write-Host "Found device in Entra ID:" -ForegroundColor Green
            Write-Host "  Name: $($entraDevice.DisplayName)" -ForegroundColor White
            Write-Host "  ID: $($entraDevice.Id)" -ForegroundColor White
            
            Remove-MgDevice -DeviceId $entraDevice.Id -ErrorAction Stop
            Write-Host "Successfully removed from Entra ID." -ForegroundColor Green
        } else {
            Write-Host "Device not found in Entra ID with any search method." -ForegroundColor Yellow
            Write-Host "The device may have been already removed or may need manual removal from Azure portal." -ForegroundColor Yellow
        }
        
        Write-Host "`nDevice removal completed!" -ForegroundColor Green
        Write-Host "✓ Removed from Intune" -ForegroundColor Green
        Write-Host "✓ Checked/Removed from Autopilot" -ForegroundColor Green
        Write-Host "✓ Checked/Removed from Entra ID" -ForegroundColor Green
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host $_.Exception.StackTrace -ForegroundColor DarkRed
    }
}

# Connect with all required scopes
Write-Host "Connecting to Microsoft Graph with required permissions..." -ForegroundColor Cyan
Connect-MgGraph -Scopes @(
    "Device.ReadWrite.All",
    "DeviceManagementServiceConfig.ReadWrite.All",
    "Directory.ReadWrite.All"
)


#here is where you enter the device name
#you need to use the device name to remove from entra
#for some reason I can't get it to purge entra the first time successfully run script twice
Remove-DeviceFromIntuneAutopilotAndEntra -DeviceName ""
