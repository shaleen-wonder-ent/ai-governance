# AI Model Governance — Phase 0

Blanket-deny **all** Azure AI model deployments in a subscription, with a per-model approval allowlist. Start small (one test subscription, no management group), expand later.

- **New here?** Read [design.md](design.md) for the architecture, rollout plan, and ops guardrails.
- **Want to try it in a subscription?** Follow [RUNBOOK.md](RUNBOOK.md) — portal-first, end-to-end walkthrough with a PowerShell alternative for every step.
- **Contributing?** This repo is protection-locked — see [SECURITY.md](SECURITY.md) for the PR + CODEOWNER approval rules.

## Layout

```
design.md                                  ← architecture, rollout plan, ops guardrails, roadmap
policies/
  deny-cogsvc-model-deployments.json       ← custom policy: Azure OpenAI / AI Foundry model deployments
  deny-mlw-serverless-endpoints.json       ← custom policy: Azure ML / Foundry MaaS (serverless) endpoints
  initiative-ai-model-governance.json      ← initiative bundling both
  deny-cogsvc-account-kinds.json           ← (optional, stricter mode) block Cognitive Services account creation
assignments/
  sub-test-baseline-deny.json              ← empty allowlist = deny all
  sub-test-after-gpt4o-approval.json       ← same assignment after gpt-4o approved
scripts/
  deploy-initiative.ps1                    ← publish definitions + initiative to the subscription
  assign-to-subscription.ps1               ← assign initiative to the subscription
  approve-model.ps1                        ← add an approved model to an assignment
```

## Phase 0 in 5 commands (single test subscription)

```powershell
# 1. Publish definitions + initiative at the test subscription
./scripts/deploy-initiative.ps1 -SubscriptionId <TEST_SUB_ID>

# 2. Assign with empty allowlist (= deny all)
./scripts/assign-to-subscription.ps1 `
    -SubscriptionId <TEST_SUB_ID> `
    -AssignmentFile assignments/sub-test-baseline-deny.json

# 3. Prove it's blocked — attempt any model deployment, expect RequestDisallowedByPolicy

# 4. Approval lands for gpt-4o — add the model to the allowlist
./scripts/approve-model.ps1 `
    -SubscriptionId <TEST_SUB_ID> `
    -ModelIdentifier OpenAI/gpt-4o

# 5. Re-attempt — gpt-4o deploys; every other model still blocked
```

## What's not in Phase 0

Multi-subscription rollout via a management group is **Phase 1**; runtime
controls (APIM GenAI policies + egress) are **Phase 2**; ops maturity
(approval-workflow integration, FinOps, formal break-glass) is **Phase 3**.
See the roadmap in [design.md](design.md#11-phases-13--direction-of-travel). The
JSON files are already shaped so Phase 1 is a placeholder swap
(`<SUBSCRIPTION_ID>` → MG path), not a redesign.
