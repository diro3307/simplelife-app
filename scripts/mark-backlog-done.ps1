<#
.SYNOPSIS
  Marks the 17 SimpleLife backlog items as Done on the project board and closes the issues.

.DESCRIPTION
  For every issue in the repo carrying the -Label value (default: "requirement"), this script:
    1. Sets the project's Status field to the value of -Status (default: "Done").
    2. Closes the underlying GitHub issue (unless -NoClose is passed).

  Uses gh GraphQL to resolve project / field / item IDs in one shot.

.PARAMETER Owner
  GitHub user/org. Default: diro3307

.PARAMETER Repo
  Repo name. Default: simplelife-app

.PARAMETER ProjectNumber
  GitHub Project (v2) number. Default: 7

.PARAMETER Label
  Only process project items whose linked issue carries this label. Default: "requirement"

.PARAMETER Status
  Status single-select option to set. Default: "Done". Must be one of the options
  configured on the project's Status field (e.g. Todo / In progress / Done).

.PARAMETER NoClose
  Skip closing the underlying GitHub issues.

.PARAMETER NoStatus
  Skip the project Status field update (only close issues).

.PARAMETER DryRun
  Print every action that would be taken without calling any mutating GitHub API.

.EXAMPLE
  .\scripts\mark-backlog-done.ps1 -DryRun
  .\scripts\mark-backlog-done.ps1
  .\scripts\mark-backlog-done.ps1 -Status "In progress" -NoClose
#>
param(
    [string]$Owner = "diro3307",
    [string]$Repo = "simplelife-app",
    [int]$ProjectNumber = 7,
    [string]$Label = "requirement",
    [string]$Status = "Done",
    [switch]$NoClose,
    [switch]$NoStatus,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "    $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Write-Step "Pre-flight: gh CLI authentication"
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Bad "gh is not authenticated. Run 'gh auth login' first."
    exit 1
}
Write-Ok "gh authenticated."

$repoSlug = "$Owner/$Repo"
Write-Host "    Repo:          $repoSlug"
Write-Host "    Project:       #$ProjectNumber (owner: $Owner)"
Write-Host "    Filter label:  $Label"
Write-Host "    Target status: $Status"
Write-Host "    Close issues:  $((-not $NoClose).ToString())"
Write-Host "    Set status:    $((-not $NoStatus).ToString())"
if ($DryRun) { Write-Warn2 "DRY RUN mode - no GitHub mutations will occur." }

# ---------------------------------------------------------------------------
# 1. Resolve project node id, Status field id, target Status option id, items
# ---------------------------------------------------------------------------
Write-Step "Resolving project / field / option / item IDs via GraphQL"

$query = @"
query(`$login: String!, `$number: Int!, `$fieldName: String!) {
  user(login: `$login) {
    projectV2(number: `$number) {
      id
      field(name: `$fieldName) {
        ... on ProjectV2SingleSelectField {
          id
          name
          options { id name }
        }
      }
      items(first: 100) {
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              url
              state
              labels(first: 20) { nodes { name } }
            }
          }
        }
      }
    }
  }
}
"@

$raw = gh api graphql -f query=$query -F login=$Owner -F number=$ProjectNumber -f fieldName=Status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Bad "GraphQL query failed:"
    Write-Bad ($raw -join "`n")
    exit 1
}
$data = $raw | ConvertFrom-Json

$project = $data.data.user.projectV2
if (-not $project) { Write-Bad "Project #$ProjectNumber not found under owner '$Owner'."; exit 1 }

$projectId  = $project.id
$statusField = $project.field
if (-not $statusField) { Write-Bad "Status field not found on project."; exit 1 }
$statusFieldId = $statusField.id

$targetOption = $statusField.options | Where-Object { $_.name -eq $Status }
if (-not $targetOption) {
    $available = ($statusField.options | ForEach-Object { $_.name }) -join ", "
    Write-Bad "Status option '$Status' not found. Available: $available"
    exit 1
}
$targetOptionId = $targetOption.id

Write-Ok "project=$projectId  statusField=$statusFieldId  ${Status}=$targetOptionId"

# Filter items: must be an Issue, must carry the $Label label
$targets = @($project.items.nodes | Where-Object {
    $_.content -and
    $_.content.number -and
    $_.content.labels -and
    ($_.content.labels.nodes | Where-Object { $_.name -eq $Label })
})

if ($targets.Count -eq 0) {
    Write-Warn2 "No project items match label '$Label'. Nothing to do."
    exit 0
}
Write-Ok "$($targets.Count) item(s) match label '$Label'."

# ---------------------------------------------------------------------------
# 2. For each item: set Status (optional), close issue (optional)
# ---------------------------------------------------------------------------
$updateMutation = @"
mutation(`$project: ID!, `$item: ID!, `$field: ID!, `$option: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: `$project,
    itemId: `$item,
    fieldId: `$field,
    value: { singleSelectOptionId: `$option }
  }) {
    projectV2Item { id }
  }
}
"@

$results = New-Object System.Collections.Generic.List[object]

Write-Step "Updating items"
foreach ($t in $targets) {
    $issueNumber = $t.content.number
    $issueTitle  = $t.content.title
    $itemId      = $t.id
    $issueState  = $t.content.state
    $issueUrl    = $t.content.url

    $statusOk = $true
    $closeOk  = $true

    # --- Status field ---
    if (-not $NoStatus) {
        if ($DryRun) {
            Write-Skip "[dry-run] would set Status='$Status' on '$issueTitle' (item $itemId)"
        } else {
            $mutOut = gh api graphql -f query=$updateMutation `
                       -f project=$projectId -f item=$itemId `
                       -f field=$statusFieldId -f option=$targetOptionId 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Bad "FAILED to set Status on '$issueTitle' (#${issueNumber}):"
                Write-Bad ($mutOut -join "`n")
                $statusOk = $false
            } else {
                Write-Ok "Status='$Status' set on #$issueNumber"
            }
        }
    } else {
        Write-Skip "[skip status] #$issueNumber"
    }

    # --- Close issue ---
    if (-not $NoClose) {
        if ($issueState -eq "CLOSED") {
            Write-Skip "#$issueNumber already closed"
        } elseif ($DryRun) {
            Write-Skip "[dry-run] would close #$issueNumber '$issueTitle'"
        } else {
            $closeOut = gh issue close $issueNumber --repo $repoSlug --reason "completed" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Bad "FAILED to close #${issueNumber}:"
                Write-Bad ($closeOut -join "`n")
                $closeOk = $false
            } else {
                Write-Ok "Closed #$issueNumber"
            }
        }
    } else {
        Write-Skip "[skip close] #$issueNumber"
    }

    $results.Add([pscustomobject]@{
        Issue     = $issueNumber
        Title     = $issueTitle
        StatusSet = if ($NoStatus) { "(skipped)" } elseif ($DryRun) { "(dry-run)" } elseif ($statusOk) { "ok" } else { "FAILED" }
        Closed    = if ($NoClose)  { "(skipped)" } elseif ($DryRun) { "(dry-run)" } elseif ($issueState -eq "CLOSED") { "(already)" } elseif ($closeOk) { "ok" } else { "FAILED" }
        Url       = $issueUrl
    }) | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Summary
# ---------------------------------------------------------------------------
Write-Step "Summary"
$results | Sort-Object Issue | Format-Table -AutoSize Issue, StatusSet, Closed, Title

if ($DryRun) {
    Write-Warn2 "Dry run complete. No GitHub mutations were made."
} else {
    Write-Ok "Done. Open: https://github.com/users/$Owner/projects/$ProjectNumber"
}
