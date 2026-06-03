# Runbook — Validate Phase 0 in a test subscription

End-to-end walkthrough: publish the policy, prove it denies model deployments, approve a single model, prove only that model gets through, then clean up.

Audience: a governance / cloud platform engineer with **Owner** (or equivalent custom role with `Microsoft.Authorization/policyAssignments/*` + `Microsoft.CognitiveServices/*`) on the test subscription.

> Two paths through every step:
> - **Portal** — point-and-click in the Azure portal. Best for first-time validation, demos, and reviewers.
> - **PowerShell** — the scripts in `/scripts/`. Best for repeatable rollouts and CI.
>
> Pick whichever you prefer per step; you can mix freely.

---

## Prerequisites

**For the portal path**
- An empty Azure subscription you can experiment in (no production workloads).
- Owner role on that subscription.
- A browser signed in to that tenant.

**For the PowerShell path (additional)**
- PowerShell 7+ (Windows PowerShell 5.1 also works).
- Az PowerShell modules:
  ```powershell
  Install-Module Az.Accounts, Az.Resources, Az.CognitiveServices -Scope CurrentUser
  ```
- (Optional, for the deny test) Azure CLI 2.55+ — `az --version`.

Sign in once at the top of your session:
```powershell
Connect-AzAccount -UseDeviceAuthentication      # device code avoids the VS Code popup issue
Set-AzContext -SubscriptionId <TEST_SUB_ID>
```

Set a couple of variables you'll reuse:
```powershell
$SubId = '<TEST_SUB_ID>'
$rg    = 'rg-aipolicy-test'
$loc   = 'eastus'
```

---

## Step 1 — Publish the policy definitions and initiative

You're loading three custom JSON definitions into the subscription's policy library so they can be assigned. Nothing is enforced yet.

### Portal
1. **Azure portal → Policy → Definitions**.
2. Confirm scope at the top is **your test subscription** (use **Scope** picker if not).
3. **+ Policy definition** → paste contents of [policies/deny-cogsvc-model-deployments.json](policies/deny-cogsvc-model-deployments.json) → **Save**.
4. **+ Policy definition** → paste contents of [policies/deny-mlw-serverless-endpoints.json](policies/deny-mlw-serverless-endpoints.json) → **Save**.
5. **+ Initiative definition** → paste contents of [policies/initiative-ai-model-governance.json](policies/initiative-ai-model-governance.json) → **Save**.
6. Filter **Definition type = Initiative**; you should see **AI Model Governance**.

### PowerShell
```powershell
./scripts/deploy-initiative.ps1 -SubscriptionId $SubId
```

Expected: three "Created/Updated" lines and no red errors.

---

## Step 2 — Assign the initiative with an empty allowlist (= deny all)

This is the moment the subscription starts blocking model deployments.

### Portal
1. **Azure portal → Policy → Assignments → Assign initiative**.
2. **Scope** = test subscription. **Initiative definition** = *AI Model Governance*.
3. **Assignment name** = `ai-model-governance`. Display name = `AI Model Governance — baseline deny`.
4. **Parameters** tab:
   - **Effect** = `Deny`
   - **Allowed Cognitive Services / Azure OpenAI models** = leave **empty**
   - **Allowed serverless (MaaS) offers** = leave **empty**
5. **Non-compliance message** (optional): "Model not on the approved list. Request approval via <your process>."
6. **Review + create** → **Create**.

### PowerShell
```powershell
./scripts/assign-to-subscription.ps1 `
    -SubscriptionId  $SubId `
    -AssignmentFile  assignments/sub-test-baseline-deny.json
```

Wait **2–5 minutes** before testing — policy assignments are not instantaneous.

---

## Step 3 — Prove deny works

Try to deploy *any* model. It must be blocked.

### Portal (recommended for the demo)
1. Create a Cognitive Services / Azure OpenAI account (the empty parent resource is allowed):
   **Azure portal → Create a resource → Azure OpenAI → Create**. Resource group = `rg-aipolicy-test`. Any name + region. **Review + create → Create**.
2. Open the account → **Model deployments → Manage deployments → + Deploy model → Deploy base model**.
3. Pick **gpt-4o-mini** (or any model) → **Deploy**.
4. **Expected:** the deploy fails with `RequestDisallowedByPolicy` and a link to the assignment **AI Model Governance — baseline deny**.

### Azure CLI (scripted equivalent)
```powershell
$aoai = "aoai-test-$([guid]::NewGuid().ToString('N').Substring(0,6))"
az group create -n $rg -l $loc | Out-Null
az cognitiveservices account create `
    -n $aoai -g $rg -l $loc --kind OpenAI --sku S0 --yes | Out-Null

# Should FAIL with RequestDisallowedByPolicy
az cognitiveservices account deployment create `
    -n $aoai -g $rg `
    --deployment-name gpt-4o-mini-test `
    --model-name gpt-4o-mini --model-version "2024-07-18" --model-format OpenAI `
    --sku-name Standard --sku-capacity 1
```

> If `az` reports `ResourceGroupNotFound` or a "subscription doesn't exist" error, your `az` session is in a different tenant than your Az PowerShell session. Fix:
> ```powershell
> $tenant = (Get-AzContext).Tenant.Id
> az login --use-device-code --tenant $tenant
> az account set --subscription $SubId
> ```

---

## Step 4 — Approve gpt-4o

Simulate the AI Governance Board approving one model.

### Portal
1. **Azure portal → Policy → Assignments → AI Model Governance — baseline deny → Edit assignment**.
2. **Parameters** tab.
3. In **Allowed Cognitive Services / Azure OpenAI models**, add a row: `OpenAI/gpt-4o`.
4. **Review + save → Save**.

### PowerShell
```powershell
./scripts/approve-model.ps1 `
    -SubscriptionId   $SubId `
    -ModelIdentifier  "OpenAI/gpt-4o"
```

Expected output: `Approved 'OpenAI/gpt-4o' on ai-model-governance ...` and the new allowlist printed.

Wait **2–5 minutes** for propagation.

---

## Step 5 — Re-test: gpt-4o succeeds, everything else still denied

### Portal
1. Same Azure OpenAI account → **Model deployments → + Deploy model → gpt-4o → Deploy**. **Expected: success.**
2. Then **+ Deploy model → gpt-4o-mini → Deploy**. **Expected: still `RequestDisallowedByPolicy`.**

### Azure CLI
```powershell
# Should SUCCEED
az cognitiveservices account deployment create `
    -n $aoai -g $rg `
    --deployment-name gpt-4o-test `
    --model-name gpt-4o --model-version "2024-08-06" --model-format OpenAI `
    --sku-name Standard --sku-capacity 1

# Should FAIL with RequestDisallowedByPolicy
az cognitiveservices account deployment create `
    -n $aoai -g $rg `
    --deployment-name gpt-4o-mini-test `
    --model-name gpt-4o-mini --model-version "2024-07-18" --model-format OpenAI `
    --sku-name Standard --sku-capacity 1
```

This single pair is the definitive Phase 0 acceptance test.

---

## Step 6 — Kill switch (optional but recommended to rehearse)

Prove you can disable the policy without deleting it, in case of an emergency.

### Portal
1. **Azure portal → Policy → Assignments → AI Model Governance — baseline deny → Edit assignment → Parameters**.
2. Set **Effect** = `Disabled`. **Save**.
3. Re-run any denied deployment from Step 3 — it now succeeds.
4. Set **Effect** back to `Deny`. **Save**. Enforcement resumes after ~2–5 minutes.

### PowerShell
```powershell
$scope      = "/subscriptions/$SubId"
$assignment = Get-AzPolicyAssignment -Name 'ai-model-governance' -Scope $scope
$assignmentId = if ($assignment.PolicyAssignmentId) { $assignment.PolicyAssignmentId } else { $assignment.Id }

$params = @{}
foreach ($p in $assignment.Parameter.PSObject.Properties) { $params[$p.Name] = $p.Value.value }
$params.effect = 'Disabled'                   # or 'Deny' to re-enable

Set-AzPolicyAssignment -Id $assignmentId -PolicyParameterObject $params | Out-Null
```

---

## Step 7 — Cleanup

Removes the assignment, the initiative, the two custom definitions, and the test resource group.

### Portal
1. **Policy → Assignments** → delete `AI Model Governance — baseline deny`.
2. **Policy → Definitions** → delete **AI Model Governance** (initiative).
3. **Policy → Definitions** → delete the two policy definitions (`Deny Cognitive Services model deployments...` and `Deny Azure ML / Foundry serverless endpoints...`).
4. **Resource groups → rg-aipolicy-test → Delete**.

### PowerShell
```powershell
Remove-AzPolicyAssignment    -Name 'ai-model-governance'                        -Scope "/subscriptions/$SubId"
Remove-AzPolicySetDefinition -Name 'ai-model-governance'                        -SubscriptionId $SubId -Force
Remove-AzPolicyDefinition    -Name 'deny-cognitive-services-model-deployments'  -SubscriptionId $SubId -Force
Remove-AzPolicyDefinition    -Name 'deny-ml-serverless-endpoints'               -SubscriptionId $SubId -Force
Remove-AzResourceGroup       -Name $rg -Force
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Connect-AzAccount` opens nothing in VS Code terminal | Browser popup blocked by integrated terminal | `Connect-AzAccount -UseDeviceAuthentication` |
| `az` returns `ResourceGroupNotFound` for an RG you can see in the portal | `az` is signed into a different tenant than Az PowerShell | `(Get-AzContext).Tenant.Id` → `az login --use-device-code --tenant <id>` → `az account set --subscription <id>` |
| `New-AzCognitiveServicesAccountDeployment` errors with `Cannot find type [...PSDeploymentModel]` | Type removed in newer `Az.CognitiveServices` | Use the `az cognitiveservices account deployment create` form above |
| `approve-model.ps1` fails with `Cannot bind argument to parameter 'Id' because it is an empty string` | Older Az.Resources surfaced `.PolicyAssignmentId`; newer surfaces `.Id` | Already handled in the script (falls back to `.Id`). Pull latest. |
| Deployment succeeded that should have been denied | Assignment hadn't propagated, or you tested before Step 2 finished, or you're testing at a scope outside the assignment | Wait 5 minutes; confirm assignment scope in **Policy → Assignments** |
| `RequestDisallowedByPolicy` after you approved the model | Propagation delay, or the model identifier doesn't match the allowlist string (case- and slash-sensitive: `OpenAI/gpt-4o`, not `openai/gpt-4o` or `gpt-4o`) | Wait 5 minutes; compare allowlist exactly to the model's publisher/name |

---

## What this proves

Pass the test above and you've demonstrated:

1. The initiative denies *all* model deployments by default.
2. A single edit (add one string to the allowlist) approves *one* model, leaving the rest denied.
3. The kill switch (`effect = Disabled`) flips enforcement off without losing the configuration.

That's the Phase 0 contract. Phase 1 (rolling this out to multiple subscriptions via a management group) reuses these exact JSON files — see [design.md §11](design.md#11-phases-13--direction-of-travel).
