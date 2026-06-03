# Assigns the AI Model Governance initiative to a subscription using the
# parameters in an assignment JSON file under ./assignments/.
#
# Phase 0 assumes the initiative was published to the SAME subscription via
# scripts/deploy-initiative.ps1.
#
# Example:
#   ./scripts/assign-to-subscription.ps1 `
#       -SubscriptionId 00000000-0000-0000-0000-000000000000 `
#       -AssignmentFile assignments/sub-test-baseline-deny.json

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $AssignmentFile,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$path = if ([IO.Path]::IsPathRooted($AssignmentFile)) { $AssignmentFile } else { Join-Path $RepoRoot $AssignmentFile }
$raw  = (Get-Content $path -Raw).Replace('<SUBSCRIPTION_ID>', $SubscriptionId)
$a    = $raw | ConvertFrom-Json

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$initiative = Get-AzPolicySetDefinition -Name 'ai-model-governance' -SubscriptionId $SubscriptionId

Write-Host "Assigning initiative '$($initiative.Name)' to subscription $SubscriptionId" -ForegroundColor Cyan

# Convert parameters node to the hashtable shape New-AzPolicyAssignment expects.
$paramHash = @{}
foreach ($p in $a.properties.parameters.PSObject.Properties) {
    $paramHash[$p.Name] = $p.Value.value
}

New-AzPolicyAssignment `
    -Name $a.name `
    -DisplayName $a.properties.displayName `
    -Description $a.properties.description `
    -Scope ("/subscriptions/$SubscriptionId") `
    -PolicySetDefinition $initiative `
    -PolicyParameterObject $paramHash `
    -EnforcementMode $a.properties.enforcementMode `
    -NonComplianceMessage $a.properties.nonComplianceMessages | Out-Null

Write-Host "Assigned." -ForegroundColor Green
