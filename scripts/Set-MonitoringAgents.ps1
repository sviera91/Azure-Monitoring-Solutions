<#PSScriptInfo

.AUTHOR stvier@microsoft.com

#>
<#

.PARAMETER LinStorageDiagnostics
Name of the Storage Account to store Diagnostics data for Linux Vms

.PARAMETER WinStorageDiagnostics
Name of the Storage Account to store Diagnostics data for Windows VMs

.PARAMETER StorageResourceGroup
Name of the Storage Account Resource Grou

.PARAMETER LawName
Name of the Log Analytics Workspace

.PARAMETER MonitoringResourceGroup
Name of th eMonitoring Resource Group

.PARAMETER Template
Path for the ARM template that deploys the Log Analytics Workspace

.PARAMETER LawRegion
Region for the Log Analytics Workspace

.PARAMETER LinDiagnosticsFile
Path for the Linux Diagnostics config file

.PARAMETER WinDiagnosticsFile
Path for the Windows Diagnostics config file

#>

param(
    [Parameter(mandatory = $true)][string]$LinStorageDiagnostics,
    [Parameter(mandatory = $true)][string]$WinStorageDiagnostics,
    [Parameter(mandatory = $true)][string]$StorageResourceGroup,
    [Parameter(mandatory = $true)][string]$LawName,
    [Parameter(mandatory = $false)][string]$MonitoringResourceGroup,
    [Parameter(mandatory = $false)][string]$Template,
    [Parameter(mandatory = $false)][string]$LawRegion,
    [Parameter(mandatory = $false)][switch]$LinDiagnosticsFile,
    [Parameter(mandatory = $false)][switch]$WinDiagnosticsFile
)

#Get VMs
$VMs = Get-AzVM

#--- Boot Diagnostics ---

foreach ($VM in $VMs){

    if ($VM.DiagnosticsProfile.BootDiagnostics.Enabled){
        Write-Host "VM "$VM.Name" has Boot Diagnostics enabled."
    }
    elseif ($VM.StorageProfile.OsDisk.OsType -eq "Linux"){
        Write-Host "VM "$VM.Name" does not have Boot Diagnostics enabled. Proceeding to enable it."
        Set-AzVMBootDiagnostic -VM $VM -Enable -ResourceGroupName $StorageResourceGroup -StorageAccountName $LinStorageDiagnostics
        Write-Host "VM "$VM.Name" has now enabled Boot Diagnostics."
    }
    elseif ($VM.StorageProfile.OsDisk.OsType -eq "Windows"){
        Write-Host "VM "$VM.Name" does not have Boot Diagnostics enabled. Proceeding to enable it."
        Set-AzVMBootDiagnostic -VM $VM -Enable -ResourceGroupName $StorageResourceGroup -StorageAccountName $WinStorageDiagnostics
        Write-Host "VM "$VM.Name" has now enabled Boot Diagnostics."
    }
}

#--- Diagnostics Extension ---
$linpublicSettings = [IO.File]::ReadAllText($LinDiagnosticsFile)
$linpublicSettings = $linpublicSettings.Replace('__DIAGNOSTIC_STORAGE_ACCOUNT__', $LinStorageDiagnostics)

$winpublicSettings = [IO.File]::ReadAllText($WinDiagnosticsFile)
$winpublicSettings = $winpublicSettings.Replace('__DIAGNOSTIC_STORAGE_ACCOUNT__', $WinStorageDiagnostics)

$linSasToken = New-AzStorageAccountSASToken -Service Blob,Table -ResourceType Service,Container,Object -Permission "racwdlup" -Context (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -AccountName $LinStorageDiagnostics).Context
$protectedSettings="{'storageAccountName': '$StorageResourceGroup', 'storageAccountSasToken': '$linSasToken'}"
$winSaKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageResourceGroup -Name $WinStorageDiagnostics).Value[0]

foreach ($VM in $VMs){

    if ($VM.StorageProfile.OsDisk.OsType -eq "Linux"){
        $linpublicSettings = $linpublicSettings.Replace('__VM_RESOURCE_ID__', $VM.Id)
        Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -ExtensionType "LinuxDiagnostic" -Publisher "Microsoft.Azure.Diagnostics" -Name "LinuxDiagnostic" -SettingString $linpublicSettings -ProtectedSettingString $protectedSettings -TypeHandlerVersion 3.0 -Verbose
    }
    elseif ($VM.StorageProfile.OsDisk.OsType -eq "Windows") {
        $winpublicSettings = $winpublicSettings.Replace('__VM_RESOURCE_ID__', $VM.Id)
        Set-Content -Path 'config.json' -Value $winpublicSettings
        Set-AzVMDiagnosticsExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -AutoUpgradeMinorVersion $true -DiagnosticsConfigurationPath "config.json" -StorageAccountKey $winSaKey -verbose
        Remove-Item "config.json"
    }
}

#--- Deploy Log Analytics Workspace ---
New-AzResourceGroupDeployment -Name "LAW-01" -ResourceGroupName $MonitoringResourceGroup -Mode Incremental -TemplateFile $Template -WorkspaceName $LawName -WorkspaceLocation $LawRegion -Verbose

#--- Set Azure Monitor for VMs---
<#
Install required script from here https://www.powershellgallery.com/packages/Install-VMInsights/1.7
More infor onparameter flags and deployment here https://docs.microsoft.com/en-us/azure/azure-monitor/insights/vminsights-enable-at-scale-powershell#enable-with-powershell
If you haven't run Enable-AzureRmAlias -Scope CurrentUser. This allows to run the above script in PowerShell Core as it is using AzureRM modules.
#>
$workspaceid = (Get-AzOperationalInsightsWorkspace -Name $LawName -ResourceGroupName $MonitoringResourceGroup).CustomerId.Guid
$workspacekey = (Get-AzOperationalInsightsWorkspaceSharedKey -Name $LawName -ResourceGroupName $MonitoringResourceGroup).PrimarySharedKey
$subscriptionid = (Get-AzContext).Subscription.Id
Install-VMInsights.ps1 -WorkspaceId $workspaceid -WorkspaceKey $workspacekey -SubscriptionId $subscriptionid -WorkspaceRegion $LawRegion -Approve
<#
This script runs unattended for all VMs in subcription
-ResourceGroup "VMs RG" (Optional if you want to set up Azure Monitor for only VMs in a specific RG)
-Name "VM Name" (Optional if you want to set up Azure Monitor for a single VM)
#>
