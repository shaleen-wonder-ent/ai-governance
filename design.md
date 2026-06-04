# Phase 0: Blanket "Deny AI" with Per-Model Approval

## 1. Objective

An organization wants to govern AI model usage in Azure with the simplest possible
control surface:

1. A **blanket Deny** so no one can deploy **any** AI model (Azure OpenAI / Azure
   AI Foundry / Azure ML serverless endpoints) in the in-scope subscription.
2. **Validate the control in one test subscription first**, with nothing else in
   the picture — no management group, no cross-subscription complexity.
3. When a team gets formal approval for a specific model (e.g. `gpt-4o`), the
   platform team **unblocks only that model**, **only in that subscription**, by
   editing one parameter.

This document is the Phase 0 design. Multi-subscription rollout via a management
group is **Phase 1**, summarised in §11, alongside Phases 2–3 (runtime control,
operational maturity). The Phase 0 decisions that shape this design (no Audit
soak, no grandfathering, `Az` PowerShell only, run by the subscription admin)
are recorded in §13.

---

## 2. What "using a model" actually means in Azure

To deny "AI usage" you have to deny the resource types where a *consumable model
endpoint* is created. Creating an empty workspace or account is harmless;
**deploying a model onto it is the controllable surface**.

| Surface                         | Resource type to control                                                     | Notes                                                                                |
| ------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Azure OpenAI / Azure AI Foundry | `Microsoft.CognitiveServices/accounts/deployments`                           | This is the actual model deployment (gpt-4o, gpt-4o-mini, embeddings, DALL·E, etc.). |
| Azure AI Foundry — MaaS         | `Microsoft.MachineLearningServices/workspaces/serverlessEndpoints`           | Pay-as-you-go Llama / Mistral / Cohere etc. via the Foundry model catalog.           |
| Azure ML — Online endpoints     | `Microsoft.MachineLearningServices/workspaces/onlineEndpoints/deployments`   | Custom-hosted models on AML.                                                         |
| Azure ML — Batch endpoints      | `Microsoft.MachineLearningServices/workspaces/batchEndpoints/deployments`    | Batch scoring.                                                                       |

Phase 0 covers the first two (the 99% case for GenAI today). The remaining two
are listed as **Phase 0.5** in the initiative so they can be flipped on without
redesign.

> Phase 0 deliberately **does NOT block** creation of the parent
> `Microsoft.CognitiveServices/accounts` or
> `Microsoft.MachineLearningServices/workspaces`. Teams can stand up the
> workspace, register data, build prompts — they just cannot bind a model to it
> until approved. This is the lowest-friction control. Organizations that want a
> stricter posture can additionally assign the optional
> [policies/deny-cogsvc-account-kinds.json](policies/deny-cogsvc-account-kinds.json),
> which blocks Cognitive Services account creation itself. Be aware that
> Cognitive Services covers more than generative AI (Speech, Vision, Translator,
> …) — use an explicit `allowedKinds` allowlist if your org legitimately uses
> those workloads.

### 2.1 What is explicitly out of scope for Phase 0

Azure Policy can only see and act on **Azure Resource Manager resource types**.
Anything that does not surface as one of the resource types in the table above
is invisible to this initiative — by definition, not by oversight. Two cases
come up often enough to call out:

| Scenario                                                                                                   | Blocked by Phase 0? | Why / where it's handled                                                                                                                                            |
| ---------------------------------------------------------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Running an LLM yourself on a VM / AKS / Container App / Functions (Ollama, vLLM, llama.cpp, HF Transformers, …) | No                  | These aren't AI resource types, they're generic compute. ARM only sees "a VM" or "a container app" — it cannot inspect the process running inside. Out of scope for Azure Policy on model resources; addressed at the network/runtime layer in **Phase 2** (APIM + egress controls). |
| Calling third-party LLMs (OpenAI.com, Anthropic, Gemini, AWS Bedrock) from inside Azure                    | No                  | These are public HTTPS endpoints on the internet. No Azure resource is created when an app calls them, so there is nothing for Azure Policy to match. Stopped at the network egress layer in **Phase 2** (egress through APIM, Firewall, NSGs).                                       |

The takeaway: **Phase 0 is a control-plane allowlist for managed Azure GenAI
services**. It governs what model resources can be *provisioned* in your
subscription. It does not, and cannot, govern what arbitrary code on arbitrary
compute chooses to call over the network. That is a Phase 2 concern.

---

## 3. Why one parameterized policy, not "Deny + Allow"

This is the single most common source of confusion when designing AI guardrails
in Azure, so it is worth being explicit up front.

### The intuitive (but incorrect) model

It feels natural to express the design as **two policies**:

1. A *Deny* policy that blocks all AI models.
2. An *Allow* policy that grants exceptions (e.g. "allow gpt-4o").

This reads well in English but does not work in Azure Policy:

> **Azure Policy has no "Allow" effect.** The available effects are `Deny`,
> `Audit`, `Append`, `Modify`, `DeployIfNotExists`, `AuditIfNotExists`,
> `Disabled`, and `Manual`. None of them override a prior `Deny`.

The evaluation rule is unforgiving: if **any** assignment evaluated against a
resource returns `Deny`, the resource is denied — full stop. A second policy
returning anything else (including a hypothetical "Allow") does not override it.

### The correct model — one policy, one allowlist parameter

Each policy has a parameter `allowedModels` (array). The rule is:

> **`If the model being deployed is NOT in allowedModels → Deny.`**

The same policy definition delivers both behaviours:

| `allowedModels` value             | Effective behavior                       |
| --------------------------------- | ---------------------------------------- |
| `[]`                              | Deny **all** model deployments           |
| `["OpenAI/gpt-4o"]`               | Deny all **except** `OpenAI/gpt-4o`      |
| `["OpenAI/gpt-4o", "…"]`          | Deny all **except** those listed         |

The policy is *always* a `Deny`. The allowlist is just **the set of values that
do not trigger the Deny**. Approving a model is therefore not "adding an Allow
policy" — it is **editing one parameter on one assignment**.

### Why this is operationally better

| Concern                              | Two-policy model            | Single parameterized policy |
| ------------------------------------ | --------------------------- | --------------------------- |
| Works in Azure Policy                | ❌ No (no Allow effect)     | ✅ Yes                       |
| Number of artifacts to maintain      | Grows with every approval   | Always one                  |
| Audit trail of "what is allowed?"    | Spread across N assignments | One parameter, one place    |
| Risk of drift between deny and allow | High                        | Impossible                  |
| Approval workflow                    | Deploy a new policy         | Edit one parameter          |
| Revoke an approval                   | Delete a policy             | Remove one item from array  |
| Exemption sprawl                     | One per request             | None needed                 |

This is the model used throughout the rest of this document.

---

## 4. Architecture (Phase 0)

Everything lives inside a single subscription. No management group required.

```
   ┌──────────────────────────────────────────────────────────────┐
   │  Subscription: <TEST_SUBSCRIPTION_ID>                        │
   │                                                              │
   │   ┌────────────────────────────────────────────────────┐     │
   │   │  Policy DEFINITIONS (sub scope)                    │     │
   │   │   • deny-cognitive-services-model-deployments      │     │
   │   │   • deny-ml-serverless-endpoints                   │     │
   │   │                                                    │     │
   │   │  Initiative: ai-model-governance                   │     │
   │   └────────────────────┬───────────────────────────────┘     │
   │                        │ assigned to subscription scope      │
   │                        ▼                                     │
   │   ┌────────────────────────────────────────────────────┐     │
   │   │  Assignment: ai-model-governance                   │     │
   │   │  parameters:                                       │     │
   │   │    allowedCognitiveServicesModels = []  ◄─ deny    │     │
   │   │    allowedServerlessOffers        = []  ◄─ deny    │     │
   │   │  effect = Deny                                     │     │
   │   └────────────────────────────────────────────────────┘     │
   │                                                              │
   │   On approval, only one thing changes:                       │
   │     allowedCognitiveServicesModels = ["OpenAI/gpt-4o"]       │
   └──────────────────────────────────────────────────────────────┘
```

- **Definitions, initiative, and assignment all live in the same subscription.**
  Nothing else is touched.
- The initiative's `policyDefinitionId` references use the placeholder
  `<SUBSCRIPTION_ID>`, swapped at deploy time. Phase 1 will swap it for the MG
  path — no other structural change.

---

## 5. Policy artifacts (in this repo)

| File                                                                                                                | Purpose                                                                            |
| ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [policies/deny-cogsvc-model-deployments.json](policies/deny-cogsvc-model-deployments.json)                          | Deny `Microsoft.CognitiveServices/accounts/deployments` unless model is allowlisted. |
| [policies/deny-mlw-serverless-endpoints.json](policies/deny-mlw-serverless-endpoints.json)                          | Deny `Microsoft.MachineLearningServices/workspaces/serverlessEndpoints` unless offer is allowlisted. |
| [policies/initiative-ai-model-governance.json](policies/initiative-ai-model-governance.json)                        | Bundles both into one initiative `ai-model-governance`.                            |
| [policies/deny-cogsvc-account-kinds.json](policies/deny-cogsvc-account-kinds.json)                                  | *(Optional, stricter mode)* Deny creation of Cognitive Services accounts whose `kind` is not allowlisted. Not part of the default initiative. |
| [assignments/sub-test-baseline-deny.json](assignments/sub-test-baseline-deny.json)                                  | Example assignment for the test subscription — empty allowlist (deny all).         |
| [assignments/sub-test-after-gpt4o-approval.json](assignments/sub-test-after-gpt4o-approval.json)                    | Example of the same assignment after `gpt-4o` is approved.                         |
| [scripts/deploy-initiative.ps1](scripts/deploy-initiative.ps1)                                                      | Publishes the definitions + initiative to the subscription.                        |
| [scripts/assign-to-subscription.ps1](scripts/assign-to-subscription.ps1)                                            | Assigns the initiative to the subscription with a given allowlist.                 |
| [scripts/approve-model.ps1](scripts/approve-model.ps1)                                                              | Adds an approved model to an existing assignment.                                  |

---

## 6. Model identity format

We standardise on a single string format: **`<format>/<name>`** (no version).

Examples:

- `OpenAI/gpt-4o`
- `OpenAI/gpt-4o-mini`
- `OpenAI/text-embedding-3-large`
- `Microsoft/Phi-3.5-mini-instruct`
- `Meta/Llama-3.1-8B-Instruct`

For serverless endpoints the same `<publisher>/<offerName>` shape is used.

If version pinning is needed later (e.g. only `gpt-4o` version `2024-08-06`),
extend to `<format>/<name>/<version>` and update the policy `count` expression.
Recommended only after Phase 0 stabilises — version pinning creates approval
churn whenever Microsoft retires a version.

---

## 7. Prerequisites for Phase 0 kickoff

Before running the scripts in §8:

- The test **subscription ID is known** and reachable.
- The operator (the subscription admin) holds at least **`Resource Policy
  Contributor`** at the subscription scope. `Owner` is more than enough.
- The **`Az` PowerShell module** is installed and signed in
  (`Connect-AzAccount`, `Set-AzContext`).
- A **Log Analytics workspace** exists or can be created to receive Azure
  Policy compliance and Azure Activity Log events. Phase 0 does not depend
  on it being wired up immediately, but you will want it for the guardrails
  in §10.
- Existing AI deployments in the test subscription have been mentally
  written off — per the Phase 0 decisions (§13), they keep running but show
  as non-compliant. That is by design.

---

## 8. Rollout plan (Phase 0 — one subscription, straight to Deny)

Run by the **subscription admin** from a controlled workstation, using the
`Az` PowerShell module. No inventory pass and no Audit-mode soak — those are
intentionally skipped per the Phase 0 decisions (§13).

| Step | Action                                                                                                                                                                       | Owner                | Exit criteria                                                                                                       |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------- |
| 1    | **Publish definitions + initiative** to the test subscription (`scripts/deploy-initiative.ps1 -SubscriptionId <id>`).                                                        | Subscription admin   | `Get-AzPolicySetDefinition -Name ai-model-governance -SubscriptionId <id>` returns the initiative.                  |
| 2    | **Assign the initiative with `effect = Deny`** and `allowedModels = []` (`scripts/assign-to-subscription.ps1 … sub-test-baseline-deny.json`).                                | Subscription admin   | Assignment exists at subscription scope; a new model deployment attempt returns `RequestDisallowedByPolicy`.        |
| 3    | **End-to-end approval drill.** A test team requests `gpt-4o` → admin runs `scripts/approve-model.ps1` → team successfully deploys `gpt-4o`, while `gpt-4o-mini` is still blocked. | Subscription admin   | Drill log captured.                                                                                                 |
| 4    | **Operate** in the test sub for the agreed soak period (e.g. 2 weeks): track every approval request, false positive, and operational pain point.                             | Subscription admin   | Phase 0 retrospective complete.                                                                                     |
| 5    | **Handoff** runbook to operations (how to add a model to an assignment, how to revoke, how to read compliance).                                                              | Subscription admin   | Runbook signed off — gates the start of Phase 1.                                                                    |

> Already-deployed models are deliberately **not** touched. They will show as
> non-compliant in the Compliance blade — that is informational, not an action
> item for Phase 0. The policy only blocks **new** create/update requests.

---

## 9. Approval workflow (Phase 0)

Phase 0 keeps this deliberately lightweight — no governance board, no
pipeline. The subscription admin is the sole approver and the sole operator.

```
 Requester (app team)
   │
   │  1. Email/ticket to the subscription admin: model name, business justification,
   │     data classification, est. tokens/month
   ▼
 Subscription admin
   │
   │  2. Approves / rejects (records decision somewhere durable — ticket, OneNote, etc.)
   │  3. Runs scripts/approve-model.ps1 from a controlled workstation:
   │        ./scripts/approve-model.ps1 -SubscriptionId <id> -ModelIdentifier OpenAI/gpt-4o
   ▼
 Requester deploys the model — succeeds because it's now in the allowlist
```

Revocation = re-run `approve-model.ps1` with the model removed (or edit the
assignment in the portal once, deliberately). A proper PR-based workflow comes
in Phase 1, when a pipeline takes over from the admin's workstation.

---

## 10. Operational guardrails

These apply from day one, even with one subscription and one operator.
Skipping them turns the policy into theatre rather than control.

| Guardrail                                       | What                                                                                                                                                                              | Why                                                                                                                                  |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **RBAC on the assignment**                      | Only the subscription admin (and a named alternate) holds `Resource Policy Contributor` at the assignment scope. Restrict subscription `Owner` to a small break-glass set.        | Anyone with `Owner` can edit the allowlist and silently bypass the entire control.                                                   |
| **Tag the assignment with the change reference**| Use the assignment's `description` (or `metadata`) field to record the approval ticket / decision link for the current state of `allowedModels`.                                  | This is your only audit trail for *"why does the allowlist look like this today?"*.                                                  |
| **Monitor the Activity Log**                    | Alert on `Microsoft.Authorization/policyAssignments/write` events on this assignment. Every event should map back to an approval.                                                 | Detects out-of-band edits (someone editing in the portal instead of via `approve-model.ps1`).                                        |
| **Break-glass procedure**                       | Document in advance: who can disable the policy in an incident, what time window, what post-incident review is required.                                                          | When an outage forces a bypass, you do not want to be inventing process on the fly.                                                  |
| **Quarterly allowlist review**                  | Re-read every entry in `allowedModels` against (a) the originating approval and (b) the Azure OpenAI deprecation calendar.                                                        | Approvals expire, models get retired, and stale entries are how production drift accumulates.                                        |

> Revocation does **not** delete already-deployed resources. It only blocks
> new ones. Decommissioning an existing deployment is a separate, manual step
> that lives in the operations runbook, not in this policy.

---

## 11. Phases 1–3 — direction of travel

Phase 0 deliberately covers only the control-plane allowlist on a single
subscription. The table below shows where this design is going, so the Phase 0
work can be judged against the longer arc.

| Phase                  | Layer                                          | Tooling                                                                                                                          | Outcome                                                                                                                                            |
| ---------------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Phase 0** *(this doc)* | Control plane / one subscription             | Azure Policy custom initiative; `Az` PowerShell                                                                                  | Default-deny AI model deployments; one approved model per ticket.                                                                                  |
| **Phase 1**            | Control plane / multiple subscriptions         | Same initiative, hosted at **Management Group** scope; one subscription-scoped assignment per subscription with its own allowlist | Single source of truth across the estate; per-subscription approvals; same JSON files.                                                             |
| **Phase 2**            | Data plane / runtime                           | Azure API Management (v2 SKU) with GenAI policies; Azure Firewall + NSGs + Private Endpoints                                     | All AI inference flows through a central gateway; per-team token quotas; content safety; third-party LLMs (OpenAI.com, Anthropic, Gemini) cannot be reached except through the gateway. |
| **Phase 3**            | Operations                                     | Approval-workflow integration (ServiceNow / Jira / ADO); Azure Monitor dashboards; automated drift detection; formal break-glass | Day-2 operations are repeatable, auditable, and do not depend on individual engineers.                                                             |

### Phase 1 mechanics (preview)

The structural change from Phase 0 to Phase 1 is small:

1. Create / use a management group that contains all in-scope subscriptions.
2. Re-publish the **definitions and initiative at the management group scope**
   — swap the `<SUBSCRIPTION_ID>` placeholder in `policyDefinitionId` for the
   MG path. One source of truth replaces N copies.
3. **Assignments stay at the subscription scope**, one per subscription, each
   with its own `allowedModels` array. (Per-subscription allowlists are *not*
   achievable from a single MG assignment — Azure Policy overrides cannot
   relax a `Deny` for a child scope.)
4. Add per-subscription assignment files (e.g.
   `assignments/sub-prod-1-baseline-deny.json`) and roll them out one
   subscription at a time using the same straight-to-Deny pattern as Phase 0.

### What Phase 0 does not cover, and where it returns

| Concern                                                       | Delivered by                                                                                                |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Block creation of new Cognitive Services accounts             | Optional in Phase 0 ([policies/deny-cogsvc-account-kinds.json](policies/deny-cogsvc-account-kinds.json)); standard in Phase 1 |
| Cover Azure ML online + batch endpoints                       | Phase 1                                                                                                     |
| Multi-subscription rollout / Management Group hierarchy       | Phase 1                                                                                                     |
| Stop runtime inference calls to deployed models               | Phase 2                                                                                                     |
| Stop apps from calling third-party LLMs (OpenAI.com etc.)     | Phase 2                                                                                                     |
| Token-level cost control / content safety / semantic caching  | Phase 2                                                                                                     |
| Automated approval workflow tooling                           | Phase 3                                                                                                     |
| FinOps cost-attribution dashboards                            | Phase 3                                                                                                     |
| Formal break-glass procedure                                  | Phase 3 *(informal procedure required in Phase 0, see §10)*                                                 |

---

## 12. Risks & mitigations

| Risk                                                                       | Mitigation                                                                                                                          |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Going straight to Deny surprises existing teams in the test sub.           | Phase 0 deliberately ignores existing deployments — they keep running. Only **new** create/update attempts are blocked. Announce the cutover date before flipping. |
| Existing deployments show as non-compliant in the Compliance blade.        | Expected by design — treat as informational, not actionable, in Phase 0.                                                            |
| Microsoft renames or retires a model (e.g. `gpt-4`).                       | We don't version-pin in Phase 0. The §10 quarterly allowlist review catches retirements against the Azure OpenAI deprecation calendar. |
| Built-in policies overlap and double-deny.                                 | We do **not** assign Microsoft's built-in "approved models" preview policy. Our custom initiative is authoritative.                  |
| Someone deploys via ARM/Bicep with `properties.model.name` missing.        | Policy treats a missing model name as a non-allowlisted value → denied. Verified by the Phase 0 drill.                              |
| Subscription `Owner` silently edits the allowlist.                         | §10 RBAC restriction + Activity Log alert detect and prevent this.                                                                  |
| Definitions live in one subscription in Phase 0 — what if that sub is deleted? | Acceptable Phase 0 risk (it's the test sub). Phase 1 moves definitions to the management group, removing the single-sub dependency. |

---

## 13. Phase 0 decisions (locked)

These are the decisions taken to keep Phase 0 as small as possible. Anything
not listed here is deferred to Phase 1+.

| #   | Question                                          | Decision                                                                                                          |
| --- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 1   | Which subscription is the test subscription?      | Parameterized — passed as `-SubscriptionId` to every script. The **subscription admin** runs Phase 0.             |
| 2   | Who is the AI Governance Board?                   | Not required in Phase 0. The subscription admin (or their delegate) approves model requests.                      |
| 3   | Audit-mode soak before flipping to Deny?          | No. Go **straight to Deny** in the test subscription.                                                             |
| 4   | Grandfather already-deployed models?              | No. **Ignore existing deployments.** The policy governs **new** create/update requests only.                      |
| 5   | Delivery mechanism for assignment changes?        | **`Az` PowerShell** from a controlled workstation. No CI/CD pipeline in Phase 0.                                  |
| 6   | Block parent Cognitive Services account creation? | No (default). Available as opt-in via [policies/deny-cogsvc-account-kinds.json](policies/deny-cogsvc-account-kinds.json); becomes standard in Phase 1. |
