#Requires -PSEdition Core
<#
.SYNOPSIS 
    Deploys Role assignments from a plan file.  

.PARAMETER pacEnvironmentSelector
    Defines which Policy as Code (PAC) environment we are using, if omitted, the script prompts for a value. The values are read from `$DefinitionsRootFolder/global-settings.jsonc.

.PARAMETER definitionsRootFolder
    Definitions folder path. Defaults to environment variable `$env:PAC_DEFINITIONS_FOLDER or './Definitions'.

.PARAMETER inputFolder
    Input folder path for plan files. Defaults to environment variable `$env:PAC_INPUT_FOLDER, `$env:PAC_OUTPUT_FOLDER or './Output'.

.PARAMETER interactive
    Use switch to indicate interactive use

.EXAMPLE
    Deploy-RolesPlan.ps1 -PacEnvironmentSelector "dev" -DefinitionsRootFolder "C:\PAC\Definitions" -InputFolder "C:\PAC\Output" -Interactive
    Deploys Role assignments from a plan file.

.EXAMPLE
    Deploy-RolesPlan.ps1 -Interactive
    Deploys Role assignments from a plan file. The script prompts for the PAC environment and uses the default definitions and input folders.

.LINK
    https://azure.github.io/enterprise-azure-Policy-as-code/#deployment-scripts

#>

[CmdletBinding()]
param (
    [parameter(HelpMessage = "Defines which Policy as Code (PAC) environment we are using, if omitted, the script prompts for a value. The values are read from `$DefinitionsRootFolder/global-settings.jsonc.",
        Position = 0
    )]
    [string] $PacEnvironmentSelector,

    [Parameter(HelpMessage = "Definitions folder path. Defaults to environment variable `$env:PAC_DEFINITIONS_FOLDER or './Definitions'.")]
    [string]$DefinitionsRootFolder,

    [Parameter(HelpMessage = "Input folder path for plan files. Defaults to environment variable `$env:PAC_INPUT_FOLDER, `$env:PAC_OUTPUT_FOLDER or './Output'.")]
    [string]$InputFolder,

    [Parameter(HelpMessage = "Use switch to indicate interactive use")]
    [switch] $Interactive
)

$PSDefaultParameterValues = @{
    "Write-Information:InformationVariable" = "+global:epacInfoStream"
}

Clear-Variable -Name epacInfoStream -Scope global -Force -ErrorAction SilentlyContinue

# Dot Source Helper Scripts
. "$PSScriptRoot/../Helpers/Add-HelperScripts.ps1"

$InformationPreference = "Continue"
$PacEnvironment = Select-PacEnvironment $PacEnvironmentSelector -DefinitionsRootFolder $DefinitionsRootFolder -InputFolder $InputFolder  -Interactive $Interactive
Set-AzCloudTenantSubscription -Cloud $PacEnvironment.cloud -TenantId $PacEnvironment.tenantId -Interactive $PacEnvironment.interactive

$PlanFile = $PacEnvironment.rolesPlanInputFile
$plan = Get-DeploymentPlan -PlanFile $PlanFile -AsHashtable

if ($null -eq $plan) {
    Write-Warning "***************************************************************************************************"
    Write-Warning "Plan does not exist, skip Role assignments deployment."
    Write-Warning "***************************************************************************************************"
    Write-Warning ""
}
else {

    Write-Information "***************************************************************************************************"
    Write-Information "Deploy Role assignments from plan in file '$PlanFile'"
    Write-Information "Plan created on $($plan.createdOn)."
    Write-Information "***************************************************************************************************"

    $RemovedRoleAssignments = $plan.roleAssignments.removed
    $addedRoleAssignments = $plan.roleAssignments.added
    if ($RemovedRoleAssignments.psbase.Count -gt 0) {
        Write-Information "==================================================================================================="
        Write-Information "Remove ($($RemovedRoleAssignments.psbase.Count)) obsolete Role assignments"
        Write-Information "---------------------------------------------------------------------------------------------------"
        $SplatTransform = "principalId/ObjectId scope/Scope roleDefinitionId/RoleDefinitionId"
        foreach ($roleAssignment in $RemovedRoleAssignments) {
            Write-Information "$($roleAssignment.displayName): $($roleAssignment.roleDisplayName)($($roleAssignment.roleDefinitionId)) at $($roleAssignment.scope)"
            $Splat = Get-FilteredHashTable $roleAssignment -SplatTransform $SplatTransform
            $null = Remove-AzRoleAssignment @splat -WarningAction SilentlyContinue
        }
        Write-Information ""
    }

    if ($addedRoleAssignments.psbase.Count -gt 0) {
        Write-Information "==================================================================================================="
        Write-Information "Add ($($addedRoleAssignments.psbase.Count)) new Role assignments"
        Write-Information "---------------------------------------------------------------------------------------------------"
        $retriesLimit = 4
        $SplatTransform = "principalId/ObjectId objectType/ObjectType scope/Scope roleDefinitionId/RoleDefinitionId"
        $IdentitiesByAssignmentId = @{}
        foreach ($roleAssignment in $addedRoleAssignments) {
            $principalId = $roleAssignment.principalId
            if ($null -eq $principalId) {
                $PolicyAssignmentId = $roleAssignment.assignmentId
                $Identity = $null
                if ($IdentitiesByAssignmentId.ContainsKey($PolicyAssignmentId)) {
                    $Identity = $IdentitiesByAssignmentId.$PolicyAssignmentId
                }
                else {
                    $PolicyAssignment = Get-AzPolicyAssignment -Id $roleAssignment.assignmentId -WarningAction SilentlyContinue
                    $Identity = $PolicyAssignment.Identity
                    $null = $IdentitiesByAssignmentId.Add($PolicyAssignmentId, $Identity)
                }
                $principalId = $Identity.PrincipalId
                $roleAssignment.principalId = $principalId
            }
            Write-Information "$($PolicyAssignment.Properties.displayName): $($roleAssignment.roleDisplayName)($($roleAssignment.roleDefinitionId)) at $($roleAssignment.scope)"
            $Splat = Get-FilteredHashTable $roleAssignment -SplatTransform $SplatTransform
            if (Get-AzRoleAssignment -Scope $Splat.Scope -ObjectId $Splat.ObjectId -RoleDefinitionId $Splat.RoleDefinitionId) {
                Write-Information "Role assignment already exists"
            }
            else {
                while ($retries -le $retriesLimit) {

                    $result = New-AzRoleAssignment @splat -WarningAction SilentlyContinue
                    if ($null -ne $result) {
                        break
                    }
                    else {
                        Start-Sleep -Seconds 10
                        $retries++
                    }
                }
            }
            
        }
    }
    Write-Information ""
}
