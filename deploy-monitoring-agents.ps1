$VMs = Get-AzVM
$SADiagnostics = "INSERT DIAGNOSTICS STORAGE ACCOUNT"
$SArg = "INSERT DIAGNOSTICS STORAGE ACCOUNT RESOURCE GROUP NAME"
$law = "INSERT NAME FOR LOG ANALYTICS WORKSPACE"
$MONrg = "INSERT MONITORING RESOURCE GROUP NAME"
$template = "INSERT PATH FOR LOG ANALYTICS WORKSPACE TEMPLATE"
$lawlocation = "INSERT LOG ANALYTICS WORKSPACE LOCATION"
$DiagnosticsFile = "INSERT PATH FOR DIAGNOSTICS CONFIG FILE"

#--- Boot Diagnostics ---

foreach ($VM in $VMs){
    $VMContext = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -vmname $VM.Name
    if ($VMContext.DiagnosticsProfile.BootDiagnostics.Enabled){
        Write-Host "VM $VM.Name has Boot Diagnostics enabled."
    }
    else{
        Write-Host "VM $VM.Name does not have Boot Diagnostics enabled. Proceeding to enable it."
        Set-AzVMBootDiagnostic -VM $VM -Enable -ResourceGroupName $SArg -StorageAccountName $SADiagnostics
        Write-Host "VM $VM.Name has now enabled Boot Diagnostics."
    }
}

#--- Diagnostics Extension ---
$publicSettings = [IO.File]::ReadAllText($DiagnosticsFile)
$publicSettings = $publicSettings.Replace('__DIAGNOSTIC_STORAGE_ACCOUNT__', $SADiagnostics)

$sasToken = New-AzStorageAccountSASToken -Service Blob,Table -ResourceType Service,Container,Object -Permission "racwdlup" -Context (Get-AzStorageAccount -ResourceGroupName $SArg -AccountName $SADiagnostics).Context
$protectedSettings="{'storageAccountName': '$SArg', 'storageAccountSasToken': '$sasToken'}"

foreach ($VM in $VMs){
    $VMContext = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -vmname $VM.Name
    $publicSettings = $publicSettings.Replace('__VM_RESOURCE_ID__', $VM.Id)
    if ($VM.StorageProfile.OsDisk.OsType -eq "Linux"){
        Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -ExtensionType "LinuxDiagnostic" -Publisher "Microsoft.Azure.Diagnostics" -Name "LinuxDiagnostic" -SettingString $publicSettings -ProtectedSettingString $protectedSettings -TypeHandlerVersion 3.0 -Verbose
    }
}

#--- Deploy Log Analytics Workspace ---
New-AzResourceGroupDeployment -Name "LAW-01" -ResourceGroupName $MONrg -Mode Incremental -TemplateFile $template -WorkspaceName $law -Verbose

#--- Set Azure Monitor for VMs---
<#
Install required script from here https://www.powershellgallery.com/packages/Install-VMInsights/1.7
More infor onparameter flags and deployment here https://docs.microsoft.com/en-us/azure/azure-monitor/insights/vminsights-enable-at-scale-powershell#enable-with-powershell
If you haven't run Enable-AzureRmAlias -Scope CurrentUser. This allows to run the above script in PowerShell Core as it is using AzureRM modules.
#>
$workspaceid = (Get-AzOperationalInsightsWorkspace -Name $law -ResourceGroupName $MONrg).CustomerId.Guid
$workspacekey = (Get-AzOperationalInsightsWorkspaceSharedKey -Name $law -ResourceGroupName $MONrg).PrimarySharedKey
$subscriptionid = (Get-AzContext).Subscription.Id
Install-VMInsights.ps1 -WorkspaceId $workspaceid -WorkspaceKey $workspacekey -SubscriptionId $subscriptionid -WorkspaceRegion $lawlocation -Approve
<#
This script runs unattended for all VMs in subcription
-ResourceGroup "VMs RG" (Optional if you want to set up Azure Monitor for only VMs in a specific RG)
-Name "VM Name" (Optional if you want to set up Azure Monitor for a single VM)
#>
