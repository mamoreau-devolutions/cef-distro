# Talks to GitHub Copilot's cloud agent and code review with a user token
# (COPILOT_TOKEN): agent tasks and Copilot reviews do not accept GITHUB_TOKEN.
param(
    [Parameter(Mandatory)][ValidateSet('StartTask', 'WaitTask', 'RequestReview', 'WaitReview')][string]$Action,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    # StartTask: the task and the branch it starts from.
    [string]$Prompt,
    [string]$BaseRef,
    [string]$Model,
    # WaitTask
    [string]$TaskId,
    # RequestReview, WaitReview
    [int]$PullRequest,
    [string]$Since,
    [int]$TimeoutMinutes = 240
)

$ErrorActionPreference = 'Stop'
if (-not $env:COPILOT_TOKEN) {
    throw 'COPILOT_TOKEN is not set: add the COPILOT_AGENT_TOKEN secret (a fine-grained token of a Copilot user; see README)'
}
$headers = @{
    Authorization = "Bearer $env:COPILOT_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
}

function Invoke-GitHub([string]$Method, [string]$Path, $Body) {
    $request = @{ Method = $Method; Uri = "https://api.github.com/$Path"; Headers = $headers; TimeoutSec = 60 }
    if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 5; $request.ContentType = 'application/json' }
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-RestMethod @request }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($attempt -ge 5 -or ($status -ne 429 -and $status -lt 500)) { throw }
            Start-Sleep -Seconds (30 * $attempt)
        }
    }
}

function Set-Output([string]$Name, [string]$Value) {
    Write-Host "$Name=$Value"
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

switch ($Action) {
    'StartTask' {
        $body = [ordered]@{ prompt = $Prompt; base_ref = $BaseRef; create_pull_request = $false }
        if ($Model) { $body.model = $Model }
        $task = Invoke-GitHub 'POST' "agents/repos/$Repository/tasks" $body
        Write-Host "Started Copilot task $($task.html_url)"
        Set-Output 'task_id' $task.id
        Set-Output 'task_url' $task.html_url
    }
    'WaitTask' {
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $finished = @('completed', 'failed', 'timed_out', 'cancelled', 'idle', 'waiting_for_user')
        do {
            Start-Sleep -Seconds 60
            $task = Invoke-GitHub 'GET' "agents/repos/$Repository/tasks/$TaskId" $null
            Write-Host "$(Get-Date -Format u) task state: $($task.state)"
        } while ($task.state -notin $finished -and (Get-Date) -lt $deadline)
        $branch = @($task.artifacts | Where-Object type -eq 'branch' | ForEach-Object { $_.data.head_ref }) +
            @($task.sessions | ForEach-Object head_ref) | Where-Object { $_ } | Select-Object -Last 1
        foreach ($session in @($task.sessions)) {
            if ($session.usage) { Write-Host "Session usage: $($session.usage.amount) $($session.usage.type)" }
            if ($session.error) { Write-Host "Session error: $($session.error.message)" }
        }
        Set-Output 'state' $task.state
        Set-Output 'branch' $branch
        if ($task.state -notin @('completed', 'idle', 'waiting_for_user')) { throw "Copilot task ended in state $($task.state)" }
        if (-not $branch) { throw 'Copilot task finished without a branch' }
    }
    'RequestReview' {
        $review = Invoke-GitHub 'POST' "repos/$Repository/pulls/$PullRequest/copilot-code-review" @{ review_effort = 'balanced' }
        Write-Host "Requested a Copilot review: $($review.state)"
    }
    'WaitReview' {
        $since = [datetime]::Parse($Since).ToUniversalTime()
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        do {
            Start-Sleep -Seconds 60
            $reviews = @(Invoke-GitHub 'GET' "repos/$Repository/pulls/$PullRequest/reviews?per_page=100" $null)
            $review = $reviews | Where-Object {
                $_.user.login -match 'copilot' -and $_.submitted_at -and ([datetime]$_.submitted_at).ToUniversalTime() -ge $since
            } | Select-Object -Last 1
        } while (-not $review -and (Get-Date) -lt $deadline)
        if (-not $review) { throw "No Copilot review within $TimeoutMinutes minutes" }
        Write-Host "Copilot review by $($review.user.login): $($review.state) $($review.html_url)"
        Set-Output 'review_state' $review.state
        Set-Output 'review_url' $review.html_url
        if ($review.state -ne 'APPROVED') { throw "Copilot did not approve the rebased patches ($($review.state))" }
    }
}
