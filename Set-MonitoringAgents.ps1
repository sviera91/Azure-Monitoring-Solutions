<#PSScriptInfo

.AUTHOR stvier@microsoft.com

#>
<#

.PARAMETER StorageDiagnostics
Name of the Storage Account to store Diagnostics data

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

.PARAMETER DiagnosticsFile
Path for the Diagnostics file

#>

param(
    [Parameter(mandatory = $true)][string]$StorageDiagnostics,
    [Parameter(mandatory = $true)][string]$StorageResourceGroup,
    [Parameter(mandatory = $true)][string]$LawName,
    [Parameter(mandatory = $false)][string]$MonitoringResourceGroup,
    [Parameter(mandatory = $false)][string]$Template,
    [Parameter(mandatory = $false)][string]$LawRegion,
    [Parameter(mandatory = $false)][switch]$DiagnosticsFile
)

#Get VMs
$VMs = Get-AzVM

#--- Boot Diagnostics ---

foreach ($VM in $VMs){
    $VMContext = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -vmname $VM.Name
    if ($VMContext.DiagnosticsProfile.BootDiagnostics.Enabled){
        Write-Host "VM $VM.Name has Boot Diagnostics enabled."
    }
    else{
        Write-Host "VM $VM.Name does not have Boot Diagnostics enabled. Proceeding to enable it."
        Set-AzVMBootDiagnostic -VM $VM -Enable -ResourceGroupName $StorageResourceGroup -StorageAccountName $StorageDiagnostics
        Write-Host "VM $VM.Name has now enabled Boot Diagnostics."
    }
}

#--- Diagnostics Extension ---
$publicSettings = [IO.File]::ReadAllText($DiagnosticsFile)
$publicSettings = $publicSettings.Replace('__DIAGNOSTIC_STORAGE_ACCOUNT__', $StorageDiagnostics)

$sasToken = New-AzStorageAccountSASToken -Service Blob,Table -ResourceType Service,Container,Object -Permission "racwdlup" -Context (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -AccountName $StorageDiagnostics).Context
$protectedSettings="{'storageAccountName': '$StorageResourceGroup', 'storageAccountSasToken': '$sasToken'}"

foreach ($VM in $VMs){
    $VMContext = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -vmname $VM.Name
    $publicSettings = $publicSettings.Replace('__VM_RESOURCE_ID__', $VM.Id)
    if ($VM.StorageProfile.OsDisk.OsType -eq "Linux"){
        Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -ExtensionType "LinuxDiagnostic" -Publisher "Microsoft.Azure.Diagnostics" -Name "LinuxDiagnostic" -SettingString $publicSettings -ProtectedSettingString $protectedSettings -TypeHandlerVersion 3.0 -Verbose
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
