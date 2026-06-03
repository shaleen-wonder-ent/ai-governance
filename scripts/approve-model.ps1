# Adds an approved model to an existing assignment's allowlist on a subscription.
# Use this after the AI Governance Board signs off on a request.
#
# Example - approve gpt-4o for the test subscription:
#   ./scripts/approve-model.ps1 `
#       -SubscriptionId 00000000-0000-0000-0000-000000000000 `
#       -ModelIdentifier OpenAI/gpt-4o `
#       -ParameterName allowedCognitiveServicesModels

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $ModelIdentifier,
    [ValidateSet('allowedCognitiveServicesModels','allowedServerlessOffers')]
    [string] $ParameterName = 'allowedCognitiveServicesModels',
    [string] $AssignmentName = 'ai-model-governance'
)

$ErrorActionPreference = 'Stop'
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$scope      = "/subscriptions/$SubscriptionId"
$assignment = Get-AzPolicyAssignment -Name $AssignmentName -Scope $scope

# Pull current params
$paramHash = @{}
foreach ($p in $assignment.Parameter.PSObject.Properties) {
    $paramHash[$p.Name] = $p.Value.value
}

$current = @($paramHash[$ParameterName])
if ($current -contains $ModelIdentifier) {
    Write-Host "$ModelIdentifier is already approved for $SubscriptionId. Nothing to do." -ForegroundColor Yellow
    return
}

$paramHash[$ParameterName] = $current + $ModelIdentifier

# Older Az.Resources surfaces .PolicyAssignmentId; newer versions surface .Id. Accept either.
$assignmentId = if ($assignment.PolicyAssignmentId) { $assignment.PolicyAssignmentId } else { $assignment.Id }

Set-AzPolicyAssignment `
    -Id $assignmentId `
    -PolicyParameterObject $paramHash | Out-Null

Write-Host "Approved '$ModelIdentifier' on $AssignmentName ($SubscriptionId). New list:" -ForegroundColor Green
$paramHash[$ParameterName] | ForEach-Object { Write-Host "  - $_" }
