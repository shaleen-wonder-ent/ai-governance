# Deploys the two policy definitions and the initiative at a SUBSCRIPTION scope.
# Phase 0 keeps everything inside one test subscription — no management group required.
# Run once per subscription. Idempotent — re-running updates the definitions.
#
# Phase 1 will republish these at a management-group scope; the JSON files are
# already shaped for that move (just swap the placeholder string).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId,

    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Host "Deploying AI Model Governance definitions to subscription '$SubscriptionId'" -ForegroundColor Cyan

# --- 1. Policy definitions ------------------------------------------------
$defs = @(
    @{ Name = 'deny-cognitive-services-model-deployments'; File = 'policies/deny-cogsvc-model-deployments.json' },
    @{ Name = 'deny-ml-serverless-endpoints';              File = 'policies/deny-mlw-serverless-endpoints.json' }
)

foreach ($d in $defs) {
    $path = Join-Path $RepoRoot $d.File
    Write-Host "  - Definition: $($d.Name)"
    $body = Get-Content $path -Raw | ConvertFrom-Json
    New-AzPolicyDefinition `
        -Name $d.Name `
        -DisplayName $body.properties.displayName `
        -Description $body.properties.description `
        -Policy ($body.properties.policyRule | ConvertTo-Json -Depth 100) `
        -Parameter ($body.properties.parameters | ConvertTo-Json -Depth 100) `
        -Mode $body.properties.mode `
        -SubscriptionId $SubscriptionId | Out-Null
}

# --- 2. Initiative --------------------------------------------------------
$initPath = Join-Path $RepoRoot 'policies/initiative-ai-model-governance.json'
$initRaw  = Get-Content $initPath -Raw
# Substitute the subscription placeholder in the policyDefinitionId references
$initRaw  = $initRaw.Replace('<SUBSCRIPTION_ID>', $SubscriptionId)
$init     = $initRaw | ConvertFrom-Json

Write-Host "  - Initiative: $($init.name)"
New-AzPolicySetDefinition `
    -Name $init.name `
    -DisplayName $init.properties.displayName `
    -Description $init.properties.description `
    -PolicyDefinition ($init.properties.policyDefinitions | ConvertTo-Json -Depth 100) `
    -Parameter ($init.properties.parameters | ConvertTo-Json -Depth 100) `
    -SubscriptionId $SubscriptionId | Out-Null

Write-Host "Done. Now run scripts/assign-to-subscription.ps1 against this subscription." -ForegroundColor Green
