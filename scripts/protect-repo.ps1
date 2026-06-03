<#
.SYNOPSIS
    Applies branch protection and security hardening to the GitHub repository
    so that no change can be merged into the default branch without an explicit
    approving review from a CODEOWNER.

.DESCRIPTION
    Requires:
      - GitHub CLI (`gh`) installed and authenticated (`gh auth login`).
      - The authenticated user must have admin rights on the target repo.

    Applies:
      - Classic branch protection on `main`:
          * Require pull request with 1 approving review
          * Require CODEOWNERS review
          * Dismiss stale approvals on new commits
          * Require conversation resolution
          * Block force pushes
          * Block branch deletion
          * Enforce for admins (no bypass)
      - Repository merge-policy hardening:
          * Squash-merge only
          * Auto-delete head branches after merge
      - Actions hardening:
          * Require approval for workflows from first-time / outside contributors

.PARAMETER Owner
    GitHub user or org that owns the repo. Defaults to 'shaleen-wonder-ent'.

.PARAMETER Repo
    Repository name. Defaults to 'ai-model-governance'.

.PARAMETER Branch
    Branch to protect. Defaults to 'main'.

.EXAMPLE
    .\scripts\protect-repo.ps1
    .\scripts\protect-repo.ps1 -Owner shaleen-wonder-ent -Repo ai-model-governance
#>

[CmdletBinding()]
param(
    [string]$Owner  = 'shaleen-wonder-ent',
    [string]$Repo   = 'ai-model-governance',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

function Invoke-GhApi {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [string]$JsonBody
    )
    $args = @('api', '-X', $Method, $Path, '-H', 'Accept: application/vnd.github+json')
    if ($PSBoundParameters.ContainsKey('JsonBody') -and $JsonBody) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmp -Value $JsonBody -Encoding ascii -NoNewline
            $args += @('--input', $tmp)
            & gh @args
        }
        finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }
    else {
        & gh @args
    }
    if ($LASTEXITCODE -ne 0) {
        throw "gh api $Method $Path failed (exit $LASTEXITCODE)."
    }
}

# --- 0. Sanity: gh installed and authenticated ---
$null = Get-Command gh -ErrorAction Stop
& gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
}

Write-Host "Target repo : $Owner/$Repo" -ForegroundColor Cyan
Write-Host "Branch      : $Branch" -ForegroundColor Cyan
Write-Host ""

# --- 1. Confirm repo exists and we have admin rights ---
$repoInfo = gh api "/repos/$Owner/$Repo" -H 'Accept: application/vnd.github+json' | ConvertFrom-Json
if (-not $repoInfo.permissions.admin) {
    throw "Authenticated user does not have admin rights on $Owner/$Repo."
}
Write-Host "Verified admin access on $Owner/$Repo." -ForegroundColor Green

# --- 2. Ensure the branch exists (create empty commit if repo is bare) ---
$branchExists = $true
try {
    gh api "/repos/$Owner/$Repo/branches/$Branch" -H 'Accept: application/vnd.github+json' | Out-Null
}
catch {
    $branchExists = $false
}
if (-not $branchExists) {
    Write-Warning "Branch '$Branch' does not exist on $Owner/$Repo yet. Push at least one commit to '$Branch', then re-run this script."
    return
}

# --- 3. Apply branch protection ---
$protectionBody = @{
    required_status_checks          = $null
    enforce_admins                  = $true
    required_pull_request_reviews   = @{
        dismiss_stale_reviews             = $true
        require_code_owner_reviews        = $true
        required_approving_review_count   = 1
        require_last_push_approval        = $true
    }
    restrictions                    = $null
    required_linear_history         = $false
    allow_force_pushes              = $false
    allow_deletions                 = $false
    block_creations                 = $false
    required_conversation_resolution = $true
    lock_branch                     = $false
    allow_fork_syncing              = $false
} | ConvertTo-Json -Depth 6

Write-Host "Applying branch protection on '$Branch' ..." -ForegroundColor Cyan
Invoke-GhApi -Method PUT -Path "/repos/$Owner/$Repo/branches/$Branch/protection" -JsonBody $protectionBody | Out-Null
Write-Host "  Branch protection applied." -ForegroundColor Green

# --- 4. Tighten repo-level merge policy ---
$repoSettingsBody = @{
    allow_squash_merge        = $true
    allow_merge_commit        = $false
    allow_rebase_merge        = $false
    allow_auto_merge          = $false
    delete_branch_on_merge    = $true
    allow_update_branch       = $true
    web_commit_signoff_required = $false
} | ConvertTo-Json -Depth 4

Write-Host "Hardening repository merge settings ..." -ForegroundColor Cyan
Invoke-GhApi -Method PATCH -Path "/repos/$Owner/$Repo" -JsonBody $repoSettingsBody | Out-Null
Write-Host "  Repo merge settings updated." -ForegroundColor Green

# --- 5. Actions: require approval for first-time / outside contributors ---
$actionsBody = @{
    github_owned_allowed = $true
    verified_allowed     = $true
} | ConvertTo-Json
try {
    Invoke-GhApi -Method PUT -Path "/repos/$Owner/$Repo/actions/permissions/access" -JsonBody (@{ access_level = 'none' } | ConvertTo-Json) | Out-Null
} catch {
    Write-Warning "Could not tighten Actions access ($_). Continuing."
}
try {
    Invoke-GhApi -Method PATCH -Path "/repos/$Owner/$Repo/actions/permissions/workflow" -JsonBody (@{
        default_workflow_permissions = 'read'
        can_approve_pull_request_reviews = $false
    } | ConvertTo-Json) | Out-Null
    Write-Host "  Workflow token permissions set to read-only." -ForegroundColor Green
} catch {
    Write-Warning "Could not set default workflow permissions ($_)."
}

# Require approval for fork PR workflows from first-time contributors.
try {
    Invoke-GhApi -Method PUT -Path "/repos/$Owner/$Repo/actions/permissions/fork-pr-workflows-policy" -JsonBody (@{
        run_workflows_from_fork_pull_requests = $true
        send_write_tokens_to_workflows        = $false
        send_secrets_and_variables            = $false
        require_approval_for_fork_pr_workflows = 'first_time_contributors_new_to_github'
    } | ConvertTo-Json) | Out-Null
    Write-Host "  Fork PR workflow approval requirement applied." -ForegroundColor Green
} catch {
    Write-Warning "Could not set fork PR workflow policy ($_). You can set it manually under Settings > Actions > General."
}

Write-Host ""
Write-Host "Done. Verifying ..." -ForegroundColor Cyan
gh api "/repos/$Owner/$Repo/branches/$Branch/protection" -H 'Accept: application/vnd.github+json' |
    ConvertFrom-Json |
    Select-Object @{n='required_reviews';e={$_.required_pull_request_reviews.required_approving_review_count}},
                  @{n='codeowner_review';e={$_.required_pull_request_reviews.require_code_owner_reviews}},
                  @{n='dismiss_stale';e={$_.required_pull_request_reviews.dismiss_stale_reviews}},
                  @{n='enforce_admins';e={$_.enforce_admins.enabled}},
                  @{n='force_pushes';e={$_.allow_force_pushes.enabled}},
                  @{n='deletions';e={$_.allow_deletions.enabled}},
                  @{n='conv_resolution';e={$_.required_conversation_resolution.enabled}} |
    Format-List

Write-Host "Protection summary above. Any 'False' for enforce_admins / codeowner_review / dismiss_stale, or 'True' for force_pushes / deletions, means that control is NOT active." -ForegroundColor Yellow
