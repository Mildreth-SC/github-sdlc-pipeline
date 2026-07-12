# Configura environments, branch protection, rulesets y seguridad nativa.
# Uso: .\scripts\setup-github.ps1 [-Repo owner/name]
# Requiere: gh autenticado con scope repo
#
# Variables opcionales:
#   $env:QA_LEAD, $env:TECH_LEAD, $env:SECURITY_LEAD  (logins de GitHub)

param(
  [string]$Repo = ""
)

$ErrorActionPreference = "Stop"

function Write-JsonFile([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 12 -Compress
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

if (-not $Repo) {
  $Repo = gh repo view --json nameWithOwner -q .nameWithOwner
}

$Owner = $Repo.Split("/")[0]
Write-Host "==> Repositorio: $Repo"

# --- Environments -----------------------------------------------------------
Write-Host "==> Creando environments..."

$tmp = Join-Path $env:TEMP "env-dev.json"
Write-JsonFile $tmp (@{
  wait_timer = 0
  prevent_self_review = $false
  reviewers = @()
  deployment_branch_policy = @{
    protected_branches = $false
    custom_branch_policies = $true
  }
})
gh api --method PUT "repos/$Repo/environments/development" --input $tmp | Out-Null
gh api --method POST "repos/$Repo/environments/development/deployment-branch-policies" -f name=develop -F type=branch 2>$null | Out-Null

$QaLead = if ($env:QA_LEAD) { $env:QA_LEAD } else { $Owner }
$QaId = [int](gh api "users/$QaLead" --jq .id)
$tmp = Join-Path $env:TEMP "env-cert.json"
Write-JsonFile $tmp (@{
  wait_timer = 0
  prevent_self_review = $true
  reviewers = @(@{ type = "User"; id = $QaId })
  deployment_branch_policy = @{
    protected_branches = $false
    custom_branch_policies = $true
  }
})
gh api --method PUT "repos/$Repo/environments/certification" --input $tmp | Out-Null
gh api --method POST "repos/$Repo/environments/certification/deployment-branch-policies" -f name=staging -F type=branch 2>$null | Out-Null

$TechLead = if ($env:TECH_LEAD) { $env:TECH_LEAD } else { $Owner }
$SecLead = if ($env:SECURITY_LEAD) { $env:SECURITY_LEAD } else { $Owner }
$TechId = [int](gh api "users/$TechLead" --jq .id)
$SecId = [int](gh api "users/$SecLead" --jq .id)

if ($TechId -eq $SecId) {
  Write-Warning "TECH_LEAD y SECURITY_LEAD son el mismo usuario. Configura 2 reviewers distintos después."
  $reviewers = @(@{ type = "User"; id = $TechId })
} else {
  $reviewers = @(
    @{ type = "User"; id = $TechId },
    @{ type = "User"; id = $SecId }
  )
}

$tmp = Join-Path $env:TEMP "env-prod.json"
Write-JsonFile $tmp (@{
  wait_timer = 10
  prevent_self_review = $true
  reviewers = $reviewers
  deployment_branch_policy = @{
    protected_branches = $false
    custom_branch_policies = $true
  }
})
gh api --method PUT "repos/$Repo/environments/production" --input $tmp | Out-Null
gh api --method POST "repos/$Repo/environments/production/deployment-branch-policies" -f name=main -F type=branch 2>$null | Out-Null

Write-Host "    OK environments"

# --- Branch protection ------------------------------------------------------
Write-Host "==> Aplicando branch protection..."

function Set-BranchProtection {
  param([string]$Branch, [hashtable]$Payload)
  $tmp = Join-Path $env:TEMP "bp-$Branch.json"
  Write-JsonFile $tmp $Payload
  gh api --method PUT "repos/$Repo/branches/$Branch/protection" --input $tmp | Out-Null
}

Set-BranchProtection -Branch develop -Payload @{
  required_status_checks = @{
    strict = $true
    contexts = @("Build & Lint", "Pruebas unitarias", "CodeQL (SAST rápido)")
  }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $false
    required_approving_review_count = 1
    require_last_push_approval = $false
  }
  restrictions = $null
  required_linear_history = $false
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
}

Set-BranchProtection -Branch staging -Payload @{
  required_status_checks = @{
    strict = $true
    contexts = @("Pruebas de integración", "Escaneo de dependencias (SCA)")
  }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $true
    required_approving_review_count = 2
    require_last_push_approval = $false
  }
  restrictions = $null
  required_linear_history = $false
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
}

Set-BranchProtection -Branch main -Payload @{
  required_status_checks = @{
    strict = $true
    contexts = @(
      "Suite completa de pruebas",
      "SAST completo (CodeQL)",
      "Escaneo de dependencias (bloqueante)",
      "Escaneo de secretos",
      "Escaneo de imagen Docker"
    )
  }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $true
    required_approving_review_count = 2
    require_last_push_approval = $true
  }
  restrictions = $null
  required_linear_history = $true
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
  required_signatures = $true
}

Write-Host "    OK branch protection"

# --- Seguridad --------------------------------------------------------------
Write-Host "==> Activando seguridad nativa..."
try { gh api --method PUT "repos/$Repo/vulnerability-alerts" | Out-Null; Write-Host "    Dependabot alerts: ON" } catch { Write-Host "    Dependabot alerts: skip" }
try { gh api --method PUT "repos/$Repo/automated-security-fixes" | Out-Null; Write-Host "    Dependabot security updates: ON" } catch { Write-Host "    Dependabot security updates: skip" }

$tmp = Join-Path $env:TEMP "sec.json"
Write-JsonFile $tmp (@{
  security_and_analysis = @{
    secret_scanning = @{ status = "enabled" }
    secret_scanning_push_protection = @{ status = "enabled" }
    dependabot_security_updates = @{ status = "enabled" }
  }
})
try { gh api --method PATCH "repos/$Repo" --input $tmp | Out-Null; Write-Host "    Secret scanning: ON" } catch { Write-Host "    Secret scanning: skip" }

# --- Ruleset ----------------------------------------------------------------
Write-Host "==> Ruleset main..."
$existing = gh api "repos/$Repo/rulesets" --jq '.[] | select(.name=="main-production-gates") | .id' 2>$null
if (-not $existing) {
  $tmp = Join-Path $env:TEMP "ruleset.json"
  Write-JsonFile $tmp (@{
    name = "main-production-gates"
    target = "branch"
    enforcement = "active"
    conditions = @{
      ref_name = @{
        include = @("refs/heads/main")
        exclude = @()
      }
    }
    rules = @(
      @{ type = "deletion" },
      @{ type = "non_fast_forward" },
      @{
        type = "pull_request"
        parameters = @{
          required_approving_review_count = 2
          dismiss_stale_reviews_on_push = $true
          require_code_owner_review = $true
          require_last_push_approval = $true
          required_review_thread_resolution = $true
        }
      },
      @{
        type = "required_status_checks"
        parameters = @{
          strict_required_status_checks_policy = $true
          required_status_checks = @(
            @{ context = "Suite completa de pruebas" },
            @{ context = "SAST completo (CodeQL)" },
            @{ context = "Escaneo de dependencias (bloqueante)" },
            @{ context = "Escaneo de secretos" },
            @{ context = "Escaneo de imagen Docker" }
          )
        }
      }
    )
    bypass_actors = @()
  })
  gh api --method POST "repos/$Repo/rulesets" --input $tmp | Out-Null
  Write-Host "    Ruleset creado"
} else {
  Write-Host "    Ruleset ya existe (id=$existing)"
}

Write-Host ""
Write-Host "==> Setup completado para $Repo"
Write-Host "Agrega secretos DEV_/CERT_/PROD_DEPLOY_TOKEN en cada environment."
Write-Host "Actualiza CODEOWNERS y reviewers reales (QA/Tech/Seguridad)."
Write-Host "En main: Restrict who can push → bot CI + admins (UI)."
