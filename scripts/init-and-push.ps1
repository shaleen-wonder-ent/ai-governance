<#
.SYNOPSIS
    Initializes this workspace as a git repository and pushes it to the new
    GitHub repository before branch protection is enabled.

.DESCRIPTION
    Run this BEFORE protect-repo.ps1 if the new GitHub repository is empty
    (no main branch yet). After the initial push, branch protection can be
    applied to 'main' and all future changes must go through a Pull Request.

    Requires:
      - git installed
      - gh CLI authenticated (`gh auth login`)
      - You are the owner / have push rights on the target repo

.PARAMETER Owner
    GitHub user or org. Defaults to 'shaleen-wonder-ent'.

.PARAMETER Repo
    Repository name. Defaults to 'ai-model-governance'.

.PARAMETER Branch
    Default branch to create. Defaults to 'main'.

.EXAMPLE
    .\scripts\init-and-push.ps1
#>

[CmdletBinding()]
param(
    [string]$Owner  = 'shaleen-wonder-ent',
    [string]$Repo   = 'ai-model-governance',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
Push-Location $workspace
try {
    $null = Get-Command git -ErrorAction Stop
    $null = Get-Command gh  -ErrorAction Stop

    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI not authenticated. Run 'gh auth login' first."
    }

    if (-not (Test-Path '.git')) {
        Write-Host "Initializing git repository in $workspace ..." -ForegroundColor Cyan
        git init -b $Branch | Out-Null
    } else {
        Write-Host "Existing git repository detected." -ForegroundColor Yellow
    }

    if (-not (Test-Path '.gitignore')) {
        @(
            '# OS / editor',
            '.DS_Store',
            'Thumbs.db',
            '.vscode/',
            '',
            '# Local secrets / state',
            '*.env',
            '*.local.json',
            '*.pem',
            '*.pfx',
            ''
        ) -join "`n" | Set-Content -Path .gitignore -Encoding ascii
    }

    git add -A | Out-Null
    if ((git status --porcelain) -ne $null) {
        git commit -m "Initial commit: AI model governance policies + repo protection" | Out-Null
    } else {
        Write-Host "No changes to commit." -ForegroundColor Yellow
    }

    $remoteUrl = "https://github.com/$Owner/$Repo.git"
    $existingRemote = (git remote) 2>$null
    if ($existingRemote -notcontains 'origin') {
        git remote add origin $remoteUrl
    } else {
        git remote set-url origin $remoteUrl
    }

    Write-Host "Pushing '$Branch' to $remoteUrl ..." -ForegroundColor Cyan
    git push -u origin $Branch
    Write-Host "Push complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step: run .\scripts\protect-repo.ps1 to lock down '$Branch'." -ForegroundColor Cyan
}
finally {
    Pop-Location
}
