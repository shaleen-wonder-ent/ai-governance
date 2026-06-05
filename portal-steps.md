# Portal Steps — Phase 0 AI Model Governance, end-to-end in the Azure Portal

End-to-end portal walkthrough: create the two policy definitions, bundle them into an initiative, assign with an empty allowlist (deny all), prove the deny works, approve a single model, prove only that model gets through, rehearse the kill switch, and clean up. Every step is a click in the [Azure portal](https://portal.azure.com) or [Azure AI Foundry](https://ai.azure.com) — nothing else.

Audience: a governance / cloud platform engineer with **Owner** (or equivalent custom role with `Microsoft.Authorization/policyDefinitions/*`, `Microsoft.Authorization/policySetDefinitions/*`, `Microsoft.Authorization/policyAssignments/*`, and `Microsoft.CognitiveServices/*`) on the test subscription.

Time: ~20–30 minutes including the 2 × 5-minute policy-propagation waits.

---

## Table of contents

1. [Prerequisites](#prerequisites)
2. [Step 1 — Create the first policy definition (Cognitive Services / Azure OpenAI deployments)](#step-1--create-the-first-policy-definition-cognitive-services--azure-openai-deployments)
3. [Step 2 — Create the second policy definition (Azure ML / Foundry serverless endpoints)](#step-2--create-the-second-policy-definition-azure-ml--foundry-serverless-endpoints)
4. [Step 3 — Create the initiative (bundle both definitions)](#step-3--create-the-initiative-bundle-both-definitions)
5. [Step 4 — Assign the initiative to the subscription with an empty allowlist (= deny all)](#step-4--assign-the-initiative-to-the-subscription-with-an-empty-allowlist--deny-all)
6. [Step 5 — Prove the deny works](#step-5--prove-the-deny-works)
7. [Step 6 — Approve a single model (gpt-4o)](#step-6--approve-a-single-model-gpt-4o)
8. [Step 7 — Re-test: gpt-4o succeeds, everything else still denied](#step-7--re-test-gpt-4o-succeeds-everything-else-still-denied)
9. [Step 8 — Kill switch (Effect = Disabled)](#step-8--kill-switch-effect--disabled)
10. [Step 9 — Cleanup](#step-9--cleanup)
11. [Optional — Apply the stricter account-kinds policy](#optional--apply-the-stricter-account-kinds-policy)
12. [Troubleshooting (portal)](#troubleshooting-portal)
13. [Portal quirks worth knowing](#portal-quirks-worth-knowing)

---

## Prerequisites

1. An empty Azure subscription you can experiment in — no production workloads.
2. **Owner** role on that subscription. Check at **Subscriptions → \<your sub\> → Access control (IAM) → Role assignments → your account**.
3. A browser signed in to the right tenant. Verify the tenant in the top-right of the portal (your account avatar → directory name).

---

## Step 1 — Create the first policy definition (Cognitive Services / Azure OpenAI deployments)

You are loading a custom definition into the subscription's policy library. Nothing is enforced yet — assignment is Step 4.

1. In the portal's top search bar type **Policy** → click **Policy** (the shield icon).
2. Left nav → **Authoring** → **Definitions**.
3. Confirm scope. At the top of the Definitions blade there is a **Scope** picker — set it to your test subscription only (clear any management group selections).
4. Click **+ Policy definition** on the toolbar.
5. Fill in the **Policy definition** blade:
   - **Definition location**: click the blue **…** picker → choose your test subscription → **Select**. (This is the scope where the definition will live. It must be the same subscription where you'll assign it.)
   - **Name**: paste exactly:
     ```
     Deny Cognitive Services model deployments not in the approved list
     ```
     (Must match the `displayName` in the JSON so the initiative picks it up by name in Step 3.)
   - **Description**: paste exactly:
     ```
     Denies creation or update of Azure Cognitive Services / Azure OpenAI / Azure AI Foundry model deployments (Microsoft.CognitiveServices/accounts/deployments) unless the model identifier <format>/<name> is present in the allowedModels parameter. An empty allowedModels array denies every model — this is the default blanket-deny posture.
     ```
   - **Category**: select **Create new** → enter `AI Governance`.
6. In the **POLICY RULE** JSON editor (the big code box at the bottom), select all the placeholder content and delete it, then paste the block below **exactly as-is**. If GitHub is blocked in your environment, open the local copy [policies/portal-paste/step1-cogsvc-model-deployments.json](policies/portal-paste/step1-cogsvc-model-deployments.json) in Notepad and copy from there — the file contains only this JSON.

   ```json
   {
     "mode": "All",
     "parameters": {
       "effect": {
         "type": "String",
         "metadata": {
           "displayName": "Effect",
           "description": "Use Audit during rollout soak, Deny in steady state. Defaults to Audit so an accidental assignment never silently black-holes deployments."
         },
         "allowedValues": [ "Audit", "Deny", "Disabled" ],
         "defaultValue": "Audit"
       },
       "allowedModels": {
         "type": "Array",
         "metadata": {
           "displayName": "Allowed models",
           "description": "Array of approved models in the form '<format>/<name>', e.g. ['OpenAI/gpt-4o','OpenAI/text-embedding-3-large']. Empty array means all models are denied."
         },
         "defaultValue": []
       }
     },
     "policyRule": {
       "if": {
         "allOf": [
           {
             "field": "type",
             "equals": "Microsoft.CognitiveServices/accounts/deployments"
           },
           {
             "value": "[concat(field('Microsoft.CognitiveServices/accounts/deployments/model.format'), '/', field('Microsoft.CognitiveServices/accounts/deployments/model.name'))]",
             "notIn": "[parameters('allowedModels')]"
           }
         ]
       },
       "then": {
         "effect": "[parameters('effect')]"
       }
     }
   }
   ```

   > Sanity check: the JSON should start with `"mode"` and end with the closing `"effect": "[parameters('effect')]"` block. Do **not** include a `"name"`, `"displayName"`, or outer `"properties": { ... }` wrapper — those are set by the form fields above.
7. Click **Save** (bottom of the blade).
8. The new definition opens — copy its **Definition ID** (top right, under the name) into a scratchpad. You will need it in Step 3.
   - The ID looks like `/subscriptions/<sub-guid>/providers/Microsoft.Authorization/policyDefinitions/<guid-or-name>`.

---

## Step 2 — Create the second policy definition (Azure ML / Foundry serverless endpoints)

Repeat Step 1's flow with the second policy.

1. **Policy → Definitions → + Policy definition**.
2. **Definition location**: same test subscription.
3. **Name**: paste exactly:
   ```
   Deny Azure ML / Foundry serverless endpoints not in the approved list
   ```
4. **Description**: paste exactly:
   ```
   Denies creation or update of Azure Machine Learning / Azure AI Foundry pay-as-you-go (serverless) model endpoints (Microsoft.MachineLearningServices/workspaces/serverlessEndpoints) unless the offer '<publisher>/<offerName>' is present in the allowedModels parameter. An empty allowedModels array denies every offer — this is the default blanket-deny posture.
   ```
5. **Category**: select **Use existing** → `AI Governance`.
6. **POLICY RULE** editor — clear it and paste exactly. Offline copy: [policies/portal-paste/step2-mlw-serverless-endpoints.json](policies/portal-paste/step2-mlw-serverless-endpoints.json) (open in Notepad if GitHub is blocked).

   ```json
   {
     "mode": "All",
     "parameters": {
       "effect": {
         "type": "String",
         "metadata": {
           "displayName": "Effect",
           "description": "Use Audit during rollout soak, Deny in steady state. Defaults to Audit so an accidental assignment never silently black-holes deployments."
         },
         "allowedValues": [ "Audit", "Deny", "Disabled" ],
         "defaultValue": "Audit"
       },
       "allowedModels": {
         "type": "Array",
         "metadata": {
           "displayName": "Allowed serverless offers",
           "description": "Array of approved offers in the form '<publisher>/<offerName>', e.g. ['Meta/Llama-3.1-8B-Instruct']. Empty array means all offers are denied."
         },
         "defaultValue": []
       }
     },
     "policyRule": {
       "if": {
         "allOf": [
           {
             "field": "type",
             "equals": "Microsoft.MachineLearningServices/workspaces/serverlessEndpoints"
           },
           {
             "value": "[concat(field('Microsoft.MachineLearningServices/workspaces/serverlessEndpoints/offer.publisher'), '/', field('Microsoft.MachineLearningServices/workspaces/serverlessEndpoints/offer.offerName'))]",
             "notIn": "[parameters('allowedModels')]"
           }
         ]
       },
       "then": {
         "effect": "[parameters('effect')]"
       }
     }
   }
   ```

7. Click **Save**.
8. Copy this second definition's **Definition ID** into the same scratchpad.

You now have two custom definitions and two Definition IDs.

---

## Step 3 — Create the initiative (bundle both definitions)

Build the initiative through the portal UI — it picks the two definitions from the catalog and wires their parameters to initiative-level parameters that will be set at assignment time.

1. **Policy → Definitions → + Initiative definition**.
2. **Basics** tab:
   - **Definition location**: your test subscription.
   - **Name**: `AI Model Governance` (this becomes the display name).
   - **Description**: paste exactly:
     ```
     Phase 0 initiative: blanket Deny on all AI model deployments in the scope it is assigned to, with a per-assignment, per-model approval allowlist. Bundles Cognitive Services model deployments and Azure ML/Foundry serverless endpoints into one assignable unit.
     ```
   - **Category**: **Use existing** → `AI Governance`.
   - **Initiative version (preview)**: leave blank or `1.0.0`.
3. **Policies** tab → **+ Add policy definition(s)**:
   - In the right-hand pane, set the **Type** filter to **Custom**.
   - Tick the two definitions you created in Steps 1 and 2.
   - Click **Add** at the bottom.
4. Back on the **Policies** tab, click the first definition (`Deny Cognitive Services model deployments...`) → **Edit reference ID** → set to `denyCogSvcModelDeployments`. Click the second → set its reference ID to `denyMlwServerlessEndpoints`. (These names match the initiative JSON; they're optional but keep things tidy.)
5. **Initiative parameters** tab → **+ Add initiative parameter**. Add three parameters — one row each.

   > **Important:** for **Array**-typed parameters, both **Allowed Values** and **Default Value** are **JSON editors** — values must be valid JSON (strings need double quotes, arrays need square brackets). For **String**-typed parameters, **Allowed Values** is still a JSON editor but **Default Value** is a plain text input (no quotes). If you see a red **Invalid JSON** message, that's why.

   **Parameter 1 — `effect`** (this one is **String**, not Array):
   - **Name** = `effect`
   - **Display name** = `Effect (applies to all member policies)`
   - **Description** = `Audit for soak, Deny in steady state. Defaults to Audit so an accidental assignment never silently black-holes deployments.`
   - **Type** = **String** ← change from the default Array
   - **Enable Strong Type** = No
   - **Allowed Values** (JSON editor — paste exactly, including brackets and quotes):
     ```json
     ["Audit", "Deny", "Disabled"]
     ```
   - **Default Value** (plain text input — type without quotes):
     ```
     Audit
     ```
   - Click **Save**.

   **Parameter 2 — `allowedCognitiveServicesModels`** (Array):
   - **Name** = `allowedCognitiveServicesModels`
   - **Display name** = `Allowed Cognitive Services / Azure OpenAI models`
   - **Description** = `Array in form '<format>/<name>'. Empty = deny all.`
   - **Type** = **Array**
   - **Enable Strong Type** = No
   - **Allowed Values** = *(leave blank)*
   - **Default Value** (JSON editor — paste exactly):
     ```json
     []
     ```
   - Click **Save**.

   **Parameter 3 — `allowedServerlessOffers`** (Array):
   - **Name** = `allowedServerlessOffers`
   - **Display name** = `Allowed serverless (MaaS) offers`
   - **Description** = `Array in form '<publisher>/<offerName>'. Empty = deny all.`
   - **Type** = **Array**
   - **Enable Strong Type** = No
   - **Allowed Values** = *(leave blank)*
   - **Default Value** (JSON editor — paste exactly):
     ```json
     []
     ```
   - Click **Save**.
6. **Policy parameters** tab — wire each member policy's parameter to the matching initiative parameter you just created.

   You'll see four rows (two parameters per member policy). For **each** row, do a **two-step pick**:

   1. Click the **Value Type** dropdown → choose **`Use Initiative Parameter`** (the third option, below `Default Value` and `Set value`).
   2. A second dropdown appears in the **Value(s)** column → pick the matching initiative parameter from the list (the portal filters this list to only show initiative parameters whose Type matches the row's Type).

   Set all four rows as follows:

   | Reference ID                  | Parameter name             | Type   | Value Type                  | Value(s)                           |
   | ----------------------------- | -------------------------- | ------ | --------------------------- | ---------------------------------- |
   | `denyCogSvcModelDeployments`  | Effect                     | String | `Use Initiative Parameter`  | `effect`                           |
   | `denyCogSvcModelDeployments`  | Allowed models             | Array  | `Use Initiative Parameter`  | `allowedCognitiveServicesModels`   |
   | `denyMlwServerlessEndpoints`  | Effect                     | String | `Use Initiative Parameter`  | `effect`                           |
   | `denyMlwServerlessEndpoints`  | Allowed serverless offers  | Array  | `Use Initiative Parameter`  | `allowedServerlessOffers`          |

   > **Do not** leave `Default Value` selected — that hard-codes the value (Audit / empty list) and the assignment-time inputs in [Step 4](#step-4--assign-the-initiative-to-the-subscription-with-an-empty-allowlist--deny-all) will silently have no effect. **Do not** pick `Set value` either — that bakes a fixed literal into the initiative.
   >
   > If the **Value(s)** dropdown is empty when you pick `Use Initiative Parameter`, you didn't create the matching initiative parameter in step 5 — go back to the **Initiative parameters** tab and add it, then return here.
7. **Review + create** → confirm the summary → **Create**.

---

## Step 4 — Assign the initiative to the subscription with an empty allowlist (= deny all)

This is the moment enforcement begins.

1. **Policy → Assignments → Assign initiative** (toolbar dropdown next to **Assign policy**).
2. **Basics** tab:
   - **Scope**: click the **…** picker → set **Subscription** = your test subscription → leave **Resource Group** blank → **Select**.
   - **Exclusions**: none.
   - **Initiative definition**: click the **…** picker → filter **Type = Custom** → choose **AI Model Governance** → **Select**.
   - **Assignment name**: clear the auto-filled value and set it to exactly `ai-model-governance`. (This name is what scripts later look up — keep it stable.)
   - **Display name**: `AI Model Governance — baseline deny`.
   - **Description**: `Phase 0 baseline assignment for the test subscription. Empty allowlists = blanket deny of every AI model deployment and every MaaS offer.`
   - **Policy enforcement**: **Enabled**.
3. **Parameters** tab — **uncheck** *Only show parameters that need input* to see all three:
   - **Effect (applies to all member policies)** = `Deny`.
   - **Allowed Cognitive Services / Azure OpenAI models** = leave the list **empty** (do not add any rows).
   - **Allowed serverless (MaaS) offers** = leave **empty**.
4. **Remediation** tab — leave defaults (no managed identity, no remediation task — Deny doesn't need them).
5. **Non-compliance messages** tab:
   - **Default non-compliance message** (the single text box at the top) — paste:
     ```
     AI model deployments are blocked by the AI Model Governance policy. Submit a model-approval ticket; once approved, this subscription's allowlist will be updated.
     ```
     This message automatically applies to **both** member policies — the table below shows the two definitions (`denyCogSvcModelDeployments`, `denyMlwServerlessEndpoints`) with checkmarks; you don't need to touch it. Only use **Edit message for selected policies** if you want a different message per policy.
6. **Review + create** → confirm summary → **Create**.

**Wait 2–5 minutes** before testing. Policy assignments take up to 30 minutes globally but typically propagate within 5 in a fresh subscription.

---

## Step 5 — Prove the deny works

All Azure OpenAI / Azure AI model deployments today happen through **Azure AI Foundry**, so we'll attempt the deployment from there — [https://ai.azure.com](https://ai.azure.com). The policy hooks at the ARM resource-type level (`Microsoft.CognitiveServices/accounts/deployments`), so it doesn't matter whether the deploy is triggered from the Azure portal, AI Foundry, Azure CLI, or an SDK — the Deny fires in the ARM control plane and the Foundry UI surfaces the error directly.

---

## Step 6 — Approve a single model (gpt-4o)

Simulates the AI Governance Board approving exactly one model for this subscription.

1. **Policy → Assignments**.
2. Set scope at the top to your test subscription.
3. Click **AI Model Governance — baseline deny**.
4. Toolbar → **Edit assignment**.
5. **Parameters** tab — leave *Only show parameters that need input* checked; the two allowlist parameters will be visible. (The **Effect** parameter doesn't show up because you'll leave it on its current value, `Deny`.)
6. Edit **Allowed Cognitive Services / Azure OpenAI models**:
   - Click the small **`...`** (three-dot) button to the right of the input box. A side editor titled *Allowed Cognitive Services / Azure OpenAI models* opens with an **Editor** showing the current value, e.g. `[]`.
   - Replace the editor's contents with exactly:
     ```json
     ["OpenAI/gpt-4o"]
     ```
   - Click **Save** in the side editor. The main parameters list now shows `["OpenAI/gpt-4o"]` for that row.

   > **Case- and slash-sensitive.** `openai/gpt-4o` will NOT match. `gpt-4o` alone will NOT match. The format is `<format>/<name>` and for Azure OpenAI the format is always `OpenAI`.
   >
   > To approve more models later, add them to the array: `["OpenAI/gpt-4o", "OpenAI/gpt-4o-mini", "OpenAI/text-embedding-3-large"]`.
7. Leave **Allowed serverless (MaaS) offers** as `[]` (no MaaS offer is being approved in this step).
8. Optionally update **Display name** to `AI Model Governance — gpt-4o approved` (matches [assignments/sub-test-after-gpt4o-approval.json](assignments/sub-test-after-gpt4o-approval.json)) and the non-compliance message to *"Only the AI models on this subscription's approved list may be deployed. Submit a model-approval ticket to add another model."*
9. **Review + save → Save**.

**Wait 2–5 minutes** for the new allowlist to propagate.

---

## Step 7 — Re-test: gpt-4o succeeds, everything else still denied

Back in [Azure AI Foundry](https://ai.azure.com), same project as Step 5 → **Models + endpoints** (or **Deployments**):

1. **+ Deploy model → Deploy base model → gpt-4o → Confirm → Deploy.**
   - **Expected:** Succeeds. The deployment shows as **Succeeded** within ~30 s — because `OpenAI/gpt-4o` is now on the allowlist.
2. **+ Deploy model → Deploy base model → pick any other model from the gpt family** (e.g. `gpt-4o-mini`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4-turbo`, `gpt-35-turbo`) **→ Confirm → Deploy.**
   - **Expected:** Fails with **`RequestDisallowedByPolicy`**, citing the same assignment **AI Model Governance — baseline deny**. Only `gpt-4o` is approved; every other gpt-family variant — and every non-gpt model — is still denied.

This pair (one allowed, one denied, same project, same operator) is the **definitive Phase 0 acceptance test**.

---

## Step 8 — Kill switch (Effect = Disabled)

Rehearse turning enforcement off without deleting the assignment. You want this muscle memory **before** you need it during an incident.

1. **Policy → Assignments → AI Model Governance — baseline deny → Edit assignment → Parameters**.
2. **Effect** dropdown → `Disabled` → **Review + save → Save**.
3. Wait ~2–5 minutes.
4. Back in Azure AI Foundry → **+ Deploy model → gpt-4o-mini → Deploy**.
   - **Expected:** Succeeds (enforcement is off).
5. Re-open the assignment → set **Effect** back to `Deny` → **Save**. Enforcement resumes after ~2–5 minutes.

---

## Step 9 — Cleanup

Removes everything you created, in the right order (assignments first, then initiative, then definitions, then the test resource group).

1. **Policy → Assignments** → click **AI Model Governance — baseline deny** → toolbar → **Delete assignment** → confirm.
2. **Policy → Definitions** → set filter **Definition type = Initiative** → click **AI Model Governance** → toolbar → **Delete definition** → confirm.
3. **Policy → Definitions** → set filter **Definition type = Policy**, **Type = Custom** → delete the two definitions you created in Steps 1 and 2.
4. **Resource groups → rg-aipolicy-test → Delete resource group** → type the RG name to confirm → **Delete**.

Optional: also delete the Azure OpenAI account before the RG if soft-delete is enabled and you want the name freed up immediately (Azure OpenAI account → **Overview → Delete → confirm "Purge"**).

---

## Optional — Apply the stricter account-kinds policy

By default Phase 0 lets people *create* an empty Azure OpenAI / AI Foundry account; only model deployments are blocked. To also block account creation itself, deploy a standalone definition + assignment for the stricter `deny-cogsvc-account-kinds` policy.

1. **Policy → Definitions → + Policy definition** — repeat Step 1's flow with these values:
   - **Definition location**: your test subscription.
   - **Name**: paste exactly:
     ```
     Deny Cognitive Services accounts whose kind is not in the approved list
     ```
   - **Description**: paste exactly:
     ```
     Optional, stricter-mode policy. Blocks creation of Microsoft.CognitiveServices/accounts whose 'kind' is not present in the allowedKinds parameter. Empty array denies every kind. Not included in the default ai-model-governance initiative because Cognitive Services covers more than generative AI (Speech, Vision, Translator, ...). Assign this only if your organization wants to gate the parent account, not just the model deployment, and provide an explicit allowedKinds list for any non-GenAI workloads you still permit.
     ```
   - **Category**: **Use existing** → `AI Governance`.
   - **POLICY RULE** — clear the editor and paste exactly. Offline copy: [policies/portal-paste/optional-cogsvc-account-kinds.json](policies/portal-paste/optional-cogsvc-account-kinds.json) (open in Notepad if GitHub is blocked).

     ```json
     {
       "mode": "All",
       "parameters": {
         "effect": {
           "type": "String",
           "metadata": {
             "displayName": "Effect",
             "description": "Use Audit during rollout soak, Deny in steady state. Defaults to Audit so an accidental assignment never silently black-holes account creation."
           },
           "allowedValues": [ "Audit", "Deny", "Disabled" ],
           "defaultValue": "Audit"
         },
         "allowedKinds": {
           "type": "Array",
           "metadata": {
             "displayName": "Allowed Cognitive Services account kinds",
             "description": "Array of approved values for Microsoft.CognitiveServices/accounts.kind, e.g. ['SpeechServices','ComputerVision']. Empty array denies every kind. Note: 'OpenAI' and 'AIServices' are the generative-AI kinds; omit them to keep the per-model allowlist as the only path to GenAI."
           },
           "defaultValue": []
         }
       },
       "policyRule": {
         "if": {
           "allOf": [
             {
               "field": "type",
               "equals": "Microsoft.CognitiveServices/accounts"
             },
             {
               "field": "kind",
               "notIn": "[parameters('allowedKinds')]"
             }
           ]
         },
         "then": {
           "effect": "[parameters('effect')]"
         }
       }
     }
     ```

   - Click **Save**.
2. **Policy → Assignments → Assign policy** (not *initiative* — this is a single definition):
   - **Scope** = test subscription.
   - **Policy definition** = `Deny Cognitive Services accounts whose kind is not in the approved list`.
   - **Parameters**:
     - **Effect** = `Deny`.
     - **Allowed Cognitive Services account kinds** = list any non-GenAI kinds your org legitimately uses (e.g. `SpeechServices`, `ComputerVision`). To block *all* Cognitive Services account creation including Speech / Vision / Translator, leave empty.
   - **Non-compliance message**: e.g. *"Cognitive Services account creation is restricted. Request an approved kind via your governance process."*
3. **Review + create → Create.**

Heads-up: this is **stricter** and breaks any team currently standing up a Cognitive Services workspace. Communicate before you assign.

---

## Troubleshooting (portal)

| Symptom | Likely cause | Fix |
|---|---|---|
| **+ Policy definition** isn't available / greyed out | Your account doesn't have `Microsoft.Authorization/policyDefinitions/write` at the scope | Check **Subscriptions → \<sub\> → Access control (IAM) → My access**. You need Owner, Resource Policy Contributor, or equivalent. |
| Pasting JSON into the policy rule editor fails with "Invalid JSON" | You pasted the outer `{ "name": ..., "properties": { ... } }` wrapper, or your paste lost a trailing brace | Paste only the block shown in the step — the first key must be `"mode"` and the last closing brace must match the first opening brace. Do **not** include `"name"`, `"displayName"`, `"description"`, `"metadata"`, or a `"properties"` wrapper at the top level. |
| **Create initiative parameter** dialog shows red **"Invalid JSON"** under Allowed Values | The Allowed Values box is a JSON editor, but you typed free-text (e.g. `Audit, Deny, Disabled` or `[Audit, Deny, Disabled]`) | Wrap strings in double quotes and arrays in square brackets: `["Audit", "Deny", "Disabled"]`. Note: for **String**-typed parameters the **Default Value** is a plain text input (type `Audit`, no quotes); for **Array**-typed parameters Default Value is also JSON (`[]`). |
| `effect` parameter saved as Array and the assignment shows a list editor instead of a dropdown | Type was left at the dialog's default (Array) instead of being switched to String | Re-open **Initiative parameters → effect → Edit**, change **Type** to **String**, set Allowed Values to `["Audit", "Deny", "Disabled"]` and Default Value to `Audit` (no quotes), save. || **Policy parameters** tab — Value(s) dropdown is empty after picking `Use Initiative Parameter` | You haven't created an initiative parameter of the right Type yet, or the Type doesn't match (e.g. row is Array, but you only have a String initiative parameter) | Go back to **Initiative parameters → + Add initiative parameter** and add the missing one with the correct Type. The Value(s) dropdown filters to only show initiative parameters whose Type matches the row's Type. |
| Assignment-time inputs for Effect / Allowed models have no effect — initiative always uses Audit / empty list | One or more rows on the **Policy parameters** tab were left at `Default Value` or `Set value` instead of `Use Initiative Parameter` | Edit the initiative → **Policy parameters** tab → change every row's **Value Type** to `Use Initiative Parameter` and pick the matching initiative param in **Value(s)**. Save and re-test. |
| Assignment created but deployment still succeeds | Tested before 2–5 minute propagation, OR the assignment scope is below the resource being created (e.g. assigned to a different RG) | Wait 5 minutes. Verify scope in **Policy → Assignments → \<assignment\> → Overview**. Re-test. |
| Deployment still fails with `RequestDisallowedByPolicy` after you approved the model | Allowlist string doesn't match the model identifier exactly | Compare the value in the assignment's `allowedCognitiveServicesModels` to the format `<format>/<name>` — `OpenAI/gpt-4o`, **not** `openai/gpt-4o`, `OpenAI/GPT-4o`, or `gpt-4o`. Case- and slash-sensitive. |
| Two policy definitions with the same display name appear in the catalog | You saved the same definition twice | Delete duplicates from **Policy → Definitions** (filter **Type = Custom**). Recreate the initiative if it now points at the wrong one. |
| You see your assignment under **Compliance** but **Resource compliance** shows 0 resources | Expected — Deny is a **preventative** effect, it doesn't evaluate existing resources for compliance state. Test by trying a new deployment instead. |
| **Edit assignment** button is missing | You're viewing a built-in or inherited (management-group-scoped) assignment | You can only edit assignments at the scope you have rights to. For Phase 0 everything is at the subscription scope — confirm you opened the right one. |

---

## Portal quirks worth knowing

### 1. The portal generates a GUID for the definition's resource name

When you create a definition via **+ Policy definition**, the **Name** field you fill in becomes the **displayName**, and Azure assigns a **GUID** as the underlying resource name. The full ID looks like:

```
/subscriptions/<sub>/providers/Microsoft.Authorization/policyDefinitions/<some-guid>
```

That's why [Step 3](#step-3--create-the-initiative-bundle-both-definitions) builds the initiative by picking the definitions from the catalog rather than asking you to type any IDs — the UI resolves them by displayName.

### 2. Array-typed parameters use a JSON editor at assignment time, not a "+ Add row" list

When you edit the assignment in [Step 6](#step-6--approve-a-single-model-gpt-4o), the **Allowed Cognitive Services / Azure OpenAI models** parameter shows a small read-only input with a **`...`** (three-dot) button. Clicking `...` opens a side editor where you paste the full JSON array (e.g. `["OpenAI/gpt-4o"]`) and click **Save**. Typing directly into the small input box won't work — you have to use the side editor. After saving, the main parameters list reflects the JSON; re-open the assignment if you want to confirm it persisted.

---

## What this proves

Complete Step 7 successfully and you've demonstrated the Phase 0 contract:

1. The initiative denies *all* AI model deployments by default.
2. A single edit (add one string to the allowlist) approves *one* model, leaving the rest denied.
3. The kill switch (`Effect = Disabled`) flips enforcement off without losing the configuration.

For the architecture rationale and the Phase 1+ direction, see [design.md](design.md).
