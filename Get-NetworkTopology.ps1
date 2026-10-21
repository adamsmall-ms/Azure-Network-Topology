<##
.SYNOPSIS
    Azure Network Topology Generator for AED/ESME (PowerShell) [Beta]

.DESCRIPTION
    Discovers Azure VNet topology and produces schema-v3.0 JSON
    compatible with the AED ESME architecture diagram renderer.

    Captures VNets, vWAN hubs, subnets (with enrichment: service endpoints,
    PE/PLS network policies, delegations), peerings, gateways, ExpressRoute
    circuits, VPN sites, and on-premises connections.

    Cross-platform: runs on Windows (PowerShell 7+), macOS (pwsh 7+),
    Linux (pwsh 7+), and Azure Cloud Shell (PowerShell).
    Requires PowerShell 7.0 or later.

.PARAMETER Title
    Diagram title (prompted if omitted)

.PARAMETER VNetId
    Optional starting VNet ARM resource ID (skips interactive VNet selection)

.PARAMETER VHubId
    Optional starting Virtual Hub ARM resource ID (skips interactive selection)

.PARAMETER Subscription
    Subscription ID or name (skips subscription selection)

.PARAMETER ResourceGroup
    Resource group name (skips RG selection)

.PARAMETER Output
    Output file path (default: topology.<title>.<timestamp>.json)

.PARAMETER Baseline
    Previous topology JSON file to preserve user edits from and increment
    topologyVersion. Preserves _layout positions, OnPremises edits, x-aed-*
    tags, and user-created OnPremises sites across re-discovery.

.EXAMPLE
    ./Get-NetworkTopology.ps1
    ./Get-NetworkTopology.ps1 -Title "My Network" -Subscription "xxxx" -ResourceGroup "rg-hub"
    ./Get-NetworkTopology.ps1 -VNetId "/subscriptions/.../providers/Microsoft.Network/virtualNetworks/vnet-hub"
    ./Get-NetworkTopology.ps1 -VNetId "/subscriptions/.../vnet-hub" -Baseline ./topology.v1.json
    ./Get-NetworkTopology.ps1 -Title merge file1.json file2.json -o merged.json

.NOTES
    Dependencies: Azure CLI 2.50+
    The script checks for these automatically and will prompt to
    install any missing tools or log in to Azure if needed.
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Title = "",
    [string]$VNetId = "",
    [string]$VHubId = "",
    [string]$Subscription = "",
    [string]$ResourceGroup = "",
    [string]$Output = "",
    [string]$Baseline = ""
)

$ErrorActionPreference = "Stop"

# ── Constants ────────────────────────────────────────────────────────────────
$script:ScriptVersion = "0.5.0-beta"
$script:SchemaVersion = "3.0"
$script:GeneratorName = "aed-esme-networking/powershell"
$script:MaxRetries = 3
$script:RetryBaseDelay = 2

# ── Resolve Azure CLI executable ─────────────────────────────────────────────
# On Windows, Start-Job may not resolve bare "az" through PATHEXT.  Pre-resolve
# the full path so every call site (including background jobs) uses it.
$script:AzExe = "az"
if ($env:OS -eq 'Windows_NT') {
    $azExePath = Get-Command "az.exe" -ErrorAction SilentlyContinue
    if ($azExePath) {
        $script:AzExe = $azExePath.Source
    } else {
        $azCmdPath = Get-Command "az.cmd" -ErrorAction SilentlyContinue
        if ($azCmdPath) {
            $script:AzExe = $azCmdPath.Source
        }
    }
}

# ── Error accumulation (global) ──────────────────────────────────────────────
$script:DiscoveryErrors = [System.Collections.ArrayList]::new()

# ── Log file (global) ───────────────────────────────────────────────────────
$script:LogFileHandle = $null
$script:LogFilePath = ""
$script:AnsiRegex = [regex]::new('\x1b\[[0-9;]*m')

function Open-LogFile {
    param([string]$Path)
    $script:LogFilePath = $Path
    $script:LogFileHandle = [System.IO.StreamWriter]::new($Path, $false, [System.Text.Encoding]::UTF8)
    $script:LogFileHandle.AutoFlush = $true
}

function Close-LogFile {
    if ($script:LogFileHandle) {
        $script:LogFileHandle.Close()
        $script:LogFileHandle = $null
    }
}

function Write-LogToFile {
    param([string]$Msg)
    if (-not $script:LogFileHandle) { return }
    $utcTs = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")
    $localTs = (Get-Date -Format "HH:mm:ss")
    $tzAbbr = [System.TimeZoneInfo]::Local.StandardName
    # Try to get abbreviated TZ; fall back to ID
    if ([string]::IsNullOrWhiteSpace($tzAbbr)) { $tzAbbr = [System.TimeZoneInfo]::Local.Id }
    $cleanMsg = $script:AnsiRegex.Replace($Msg, "")
    $script:LogFileHandle.WriteLine("[$utcTs / $localTs $tzAbbr] $cleanMsg")
}

# ── Logging ──────────────────────────────────────────────────────────────────
$script:UseColor = [System.Console]::IsOutputRedirected -eq $false -and
                   [System.Console]::IsErrorRedirected -eq $false -and
                   -not $env:NO_COLOR

function Get-Esc { if ($script:UseColor) { return [char]27 } else { return "" } }

$script:E = Get-Esc
$script:C_RESET   = if ($script:UseColor) { "$($script:E)[0m"  } else { "" }
$script:C_DIM     = if ($script:UseColor) { "$($script:E)[2m"  } else { "" }
$script:C_BOLD    = if ($script:UseColor) { "$($script:E)[1m"  } else { "" }
$script:C_CYAN    = if ($script:UseColor) { "$($script:E)[36m" } else { "" }
$script:C_YELLOW  = if ($script:UseColor) { "$($script:E)[33m" } else { "" }
$script:C_RED     = if ($script:UseColor) { "$($script:E)[31m" } else { "" }
$script:C_GREEN   = if ($script:UseColor) { "$($script:E)[32m" } else { "" }
$script:C_BLUE    = if ($script:UseColor) { "$($script:E)[34m" } else { "" }
$script:C_MAGENTA = if ($script:UseColor) { "$($script:E)[35m" } else { "" }
$script:C_WHITE   = if ($script:UseColor) { "$($script:E)[97m" } else { "" }

function Write-LogInfo     { param([string]$Msg) Write-Host "$($script:C_DIM)  $Msg$($script:C_RESET)"; Write-LogToFile "  $Msg" }
function Write-LogDetail   { param([string]$Msg) Write-Host "$($script:C_DIM)      $Msg$($script:C_RESET)"; Write-LogToFile "      $Msg" }
function Write-LogSubstep  { param([string]$Msg) Write-Host "$($script:C_DIM)$($script:C_CYAN)          $Msg$($script:C_RESET)"; Write-LogToFile "          $Msg" }
function Write-LogFound    { param([string]$Msg) Write-Host "$($script:C_DIM)$($script:C_GREEN)              $Msg$($script:C_RESET)"; Write-LogToFile "              $Msg" }
function Write-LogWarn     { param([string]$Msg) Write-Host "$($script:C_YELLOW)  ▲ $Msg$($script:C_RESET)"; Write-LogToFile "  WARN: $Msg" }
function Write-LogError    { param([string]$Msg) Write-Host "$($script:C_RED)  ✖ $Msg$($script:C_RESET)"; Write-LogToFile "  ERROR: $Msg" }
function Write-LogStep     { param([string]$Msg) $ts = Get-Date -Format 'HH:mm:ss'; Write-Host "" ; Write-Host "$($script:C_DIM)[$ts]$($script:C_RESET) $($script:C_BOLD)$($script:C_CYAN)── $Msg ──$($script:C_RESET)"; Write-LogToFile "── $Msg ──" }
function Write-LogResource { param([string]$Msg) $ts = Get-Date -Format 'HH:mm:ss'; Write-Host "" ; Write-Host "$($script:C_DIM)[$ts]$($script:C_RESET) $($script:C_GREEN)$($script:C_BOLD)  ● $Msg$($script:C_RESET)"; Write-LogToFile "  ● $Msg" }
function Write-LogQueue    { param([string]$Msg) Write-Host "$($script:C_BLUE)              ↳ queued $Msg$($script:C_RESET)"; Write-LogToFile "              ↳ queued $Msg" }

# ── Spinner ──────────────────────────────────────────────────────────────────
$script:SpinnerJob = $null
function Start-Spinner {
    param([string]$Message = "Loading…")
    if (-not [System.Console]::IsOutputRedirected -and -not $env:NO_COLOR) {
        $script:SpinnerJob = Start-Job -ScriptBlock {
            param($msg)
            $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
            $i = 0
            while ($true) {
                $f = $frames[$i % $frames.Count]
                [Console]::Error.Write("`r  $f $msg")
                Start-Sleep -Milliseconds 100
                $i++
            }
        } -ArgumentList $Message
    } else {
        Write-LogInfo $Message
    }
}
function Stop-Spinner {
    if ($null -ne $script:SpinnerJob) {
        Stop-Job $script:SpinnerJob -ErrorAction SilentlyContinue
        Remove-Job $script:SpinnerJob -Force -ErrorAction SilentlyContinue
        $script:SpinnerJob = $null
        if (-not [System.Console]::IsOutputRedirected) {
            [Console]::Error.Write("`r$(' ' * 60)`r")
        }
    }
}

function Write-LogAlert {
    param([string[]]$Lines)
    Write-Host ""
    Write-Host "$($script:C_RED)$($script:C_BOLD)  ╔══════════════════════════════════════════════════$($script:C_RESET)"
    Write-Host "$($script:C_RED)$($script:C_BOLD)  ║  ⚠  $($Lines[0])$($script:C_RESET)"
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        Write-Host "$($script:C_RED)  ║     $($Lines[$i])$($script:C_RESET)"
    }
    Write-Host "$($script:C_RED)$($script:C_BOLD)  ╚══════════════════════════════════════════════════$($script:C_RESET)"
}

# ── Validation ───────────────────────────────────────────────────────────────
function Test-ArmResourceId {
    param([string]$Id)
    return $Id -match "^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[^/]+/providers/"
}

function Test-SubscriptionGuid {
    param([string]$Id)
    return $Id -match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
}

function Get-ArmBasename {
    param([string]$ArmId)
    return ($ArmId -split "/")[-1]
}

function Get-SubscriptionFromId {
    param([string]$ArmId)
    if ($ArmId -match "^/subscriptions/([^/]+)/") { return $Matches[1] }
    return ""
}

function Get-ResourceGroupFromId {
    param([string]$ArmId)
    if ($ArmId -match "^/subscriptions/[^/]+/resourceGroups/([^/]+)/") { return $Matches[1] }
    return ""
}

# ── Azure CLI wrapper ───────────────────────────────────────────────────────
function Invoke-AzCli {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [int]$TimeoutSeconds = 0
    )
    $cmd = @($script:AzExe) + $Arguments + @("--output", "json")
    try {
        if ($TimeoutSeconds -gt 0) {
            $job = Start-Job -ScriptBlock {
                param($c)
                $null | & $c[0] $c[1..($c.Count-1)] 2>$null
            } -ArgumentList @(,$cmd)
            if (Wait-Job $job -Timeout $TimeoutSeconds) {
                $rawOutput = Receive-Job $job
                Remove-Job $job -Force -ErrorAction SilentlyContinue
                $exitCode = 0
            } else {
                Write-Host "  $($script:C_YELLOW)  ⚠ Command timed out after ${TimeoutSeconds}s — skipping$($script:C_RESET)"
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -Force -ErrorAction SilentlyContinue
                return $null
            }
        } else {
            $rawOutput = $null | & $cmd[0] $cmd[1..($cmd.Count-1)] 2>$null
            $exitCode = $LASTEXITCODE
        }
        if ($exitCode -ne 0) { return $null }
        if ([string]::IsNullOrWhiteSpace($rawOutput)) { return $null }
        return $rawOutput | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Invoke-AzCliRaw {
    param([string[]]$Arguments)
    $cmd = @($script:AzExe) + $Arguments + @("--output", "json")
    try {
        $allOutput = $null | & $cmd[0] $cmd[1..($cmd.Count-1)] 2>&1
        $exitCode = $LASTEXITCODE
        $stdout = @($allOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
        $stderr = @($allOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
        return @{ Output = $stdout; ExitCode = $exitCode; Stderr = $stderr }
    }
    catch {
        return @{ Output = $null; ExitCode = 1; Stderr = $_.Exception.Message }
    }
}

function Invoke-AzCliText {
    param([string[]]$Arguments)
    $cmd = @($script:AzExe) + $Arguments + @("--output", "tsv")
    try {
        $rawOutput = $null | & $cmd[0] $cmd[1..($cmd.Count-1)] 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($rawOutput | Out-String).Trim()
    }
    catch {
        return $null
    }
}

function Test-IsAccessDenied {
    param([string]$StderrText)
    if ([string]::IsNullOrWhiteSpace($StderrText)) { return $false }
    return ($StderrText -match '(?i)(AuthorizationFailed|403|Forbidden|does not have authorization|Authorization_RequestDenied)')
}

function Invoke-WithRetry {
    param(
        [string]$Label,
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [string]$ErrorScope = "",
        [int]$MaxRetries = $script:MaxRetries,
        [int]$TimeoutSeconds = 0
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-LogDetail "  ↳ $Label (attempt $attempt/$MaxRetries)…"

        $resultObj = Invoke-AzCli -Arguments $Arguments -AllowFailure -TimeoutSeconds $TimeoutSeconds

        # On first failure, check for Access Denied via raw stderr capture
        if ($null -eq $resultObj -and $attempt -eq 1) {
            $rawCheck = Invoke-AzCliRaw -Arguments $Arguments
            if (Test-IsAccessDenied $rawCheck.Stderr) {
                $errMsg = "Access Denied: $Label"
                if (-not [string]::IsNullOrWhiteSpace($ErrorScope)) {
                    [void]$script:DiscoveryErrors.Add([ordered]@{ scope = $ErrorScope; error = $errMsg; category = "Access Denied" })
                }
                Write-LogWarn "Access Denied — skipping retries for: $Label"
                return $null
            }
        }

        if ($null -ne $resultObj) { return $resultObj }
        # AllowFailure without ErrorScope = optional call, don't retry
        if ($AllowFailure -and [string]::IsNullOrWhiteSpace($ErrorScope)) { return $null }
        if ($attempt -eq $MaxRetries) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorScope)) {
                $errMsg = "Failed after $MaxRetries retries: $Label"
                [void]$script:DiscoveryErrors.Add([ordered]@{ scope = $ErrorScope; error = $errMsg; category = "API Failure" })
                Write-LogWarn "Non-fatal: $errMsg"
                return $null
            }
            Write-LogError "Failed after $MaxRetries retries: $Label"
            return $null
        }
        $delay = $script:RetryBaseDelay * [Math]::Pow(2, $attempt - 1)
        Write-LogWarn "$Label — attempt $attempt failed, retrying in ${delay}s…"
        Start-Sleep -Seconds $delay
    }
    return $null
}

function Invoke-GraphQueryPaginated {
    param(
        [string]$Label,
        [string]$Query,
        [string]$Subscription,
        [string]$ErrorScope = "",
        [string]$IdField = "id"
    )

    # Windows safety: cmd.exe interprets newline-pipe sequences (\n|) inside
    # multi-line Kusto queries as shell pipes when invoked via az.cmd.  Flatten
    # the query to a single line — Kusto treats whitespace as insignificant.
    if ($env:OS -eq 'Windows_NT') {
        $Query = ($Query -replace '\s+', ' ').Trim()
    }

    $allData = [System.Collections.ArrayList]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skipToken = $null
    $page = 0

    while ($true) {
        $page++
        $pageArgs = @("graph", "query", "-q", $Query, "--subscriptions", $Subscription, "--first", "500")
        if (-not [string]::IsNullOrWhiteSpace($skipToken)) {
            $pageArgs += @("--skip-token", $skipToken)
        }

        # Retry loop for Resource Graph queries
        $result = $null
        for ($attempt = 1; $attempt -le $script:MaxRetries; $attempt++) {
            $result = Invoke-AzCli -Arguments $pageArgs -AllowFailure
            if ($null -ne $result) { break }
            if ($attempt -eq $script:MaxRetries) {
                if (-not [string]::IsNullOrWhiteSpace($ErrorScope)) {
                    $errMsg = "Failed after $($script:MaxRetries) retries: $Label (page $page)"
                    [void]$script:DiscoveryErrors.Add([ordered]@{ scope = $ErrorScope; error = $errMsg })
                    Write-LogWarn "Non-fatal: $errMsg"
                } else {
                    Write-LogWarn "$Label (page $page) — failed after $($script:MaxRetries) retries"
                }
                break
            }
            $delay = $script:RetryBaseDelay * [Math]::Pow(2, $attempt - 1)
            Write-LogWarn "$Label (page $page) — attempt $attempt failed, retrying in ${delay}s…"
            Start-Sleep -Seconds $delay
        }
        if ($null -eq $result) { break }

        $pageData = @(Get-Prop $result "data" @())
        foreach ($item in $pageData) {
            $itemId = Get-Prop $item $IdField ""
            if (-not [string]::IsNullOrWhiteSpace($itemId) -and -not $seenIds.Contains($itemId)) {
                [void]$seenIds.Add($itemId)
                [void]$allData.Add($item)
            }
        }

        $skipToken = Get-Prop $result "`$skipToken" ""
        if ([string]::IsNullOrWhiteSpace($skipToken)) {
            $skipToken = Get-Prop $result "skipToken" ""
        }
        if ([string]::IsNullOrWhiteSpace($skipToken)) { break }
    }

    if ($page -gt 1) {
        Write-LogInfo "Pagination: retrieved $($allData.Count) resources across $page pages for $Label"
    }

    # Warn when result count hits an exact page-size boundary — may indicate a
    # missing filter or unexpected truncation.
    if ($allData.Count -in @(100, 500, 1000)) {
        Write-LogWarn "Query returned exactly $($allData.Count) results for '$Label' — possible pagination/filter issue"
    }

    return @($allData)
}

# ── Safe property access helper ──────────────────────────────────────────────
function Get-Prop {
    param($Object, [string]$Path, $Default = "")
    $current = $Object
    foreach ($segment in $Path -split "\.") {
        if ($null -eq $current) { return $Default }
        if ($segment -match "^\[(\d+)\]$") {
            $idx = [int]$Matches[1]
            if ($current -is [array] -and $idx -lt $current.Count) {
                $current = $current[$idx]
            } else { return $Default }
        } else {
            try { $current = $current.$segment } catch { return $Default }
        }
        if ($null -eq $current) { return $Default }
    }
    return $current
}

# ── Sleep Prevention ─────────────────────────────────────────────────────────
$script:CaffeinateProcess = $null
$script:SleepPreventionActive = $false

function Test-InteractiveSession {
    # Skip for SSH sessions and Azure Cloud Shell
    if ($env:SSH_CONNECTION -or $env:SSH_CLIENT) { return $false }
    if ($env:ACC_CLOUD) { return $false }  # Azure Cloud Shell
    try {
        return [System.Environment]::UserInteractive
    } catch {
        return $true
    }
}

function Start-SleepPrevention {
    if (-not (Test-InteractiveSession)) { return }

    $choice = Read-Host "Prevent this machine from sleeping during discovery? [Y/n/q=exit]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "Y" }
    if ($choice -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
    if ($choice -notmatch "^[Yy]$") { return }

    if ($env:OS -eq 'Windows_NT') {
        # Windows: SetThreadExecutionState — built-in Win32 API
        try {
            $code = @"
using System;
using System.Runtime.InteropServices;
public class SleepPrevention {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
}
"@
            if (-not ([System.Management.Automation.PSTypeName]'SleepPrevention').Type) {
                Add-Type -TypeDefinition $code
            }
            [SleepPrevention]::SetThreadExecutionState(
                [SleepPrevention]::ES_CONTINUOUS -bor [SleepPrevention]::ES_SYSTEM_REQUIRED
            ) | Out-Null
            $script:SleepPreventionActive = $true
            Write-LogInfo "Sleep prevention active (SetThreadExecutionState)  ✓"
        } catch {
            Write-LogWarn "Could not set sleep prevention — continuing without it."
        }
    } elseif ($IsMacOS) {
        # macOS: caffeinate ships with every macOS
        $caffPath = Get-Command "caffeinate" -ErrorAction SilentlyContinue
        if ($caffPath) {
            try {
                $script:CaffeinateProcess = Start-Process -FilePath "caffeinate" `
                    -ArgumentList "-i -s -w $PID" `
                    -NoNewWindow -PassThru
                $script:SleepPreventionActive = $true
                Write-LogInfo "Sleep prevention active (caffeinate)  ✓"
            } catch {
                Write-LogWarn "Could not start caffeinate — continuing without sleep prevention."
            }
        } else {
            Write-LogWarn "caffeinate not found — sleep prevention unavailable."
        }
    } else {
        Write-LogDetail "Sleep prevention not needed on this platform."
    }
}

function Stop-SleepPrevention {
    if (-not $script:SleepPreventionActive) { return }
    if ($env:OS -eq 'Windows_NT') {
        try {
            if (([System.Management.Automation.PSTypeName]'SleepPrevention').Type) {
                [SleepPrevention]::SetThreadExecutionState(
                    [SleepPrevention]::ES_CONTINUOUS
                ) | Out-Null
            }
        } catch {}
    }
    if ($null -ne $script:CaffeinateProcess -and -not $script:CaffeinateProcess.HasExited) {
        try { $script:CaffeinateProcess.Kill() } catch {}
    }
    $script:SleepPreventionActive = $false
}

# ── Prerequisites ────────────────────────────────────────────────────────────
function Test-Prerequisites {
    Write-LogStep "Checking Prerequisites"

    # PowerShell version
    $psVer = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-LogError "PowerShell 7.0 or later is required (current: $psVer)."
        Write-LogDetail "Install from: https://aka.ms/powershell-release?tag=stable"
        exit 1
    }
    Write-LogInfo "PowerShell $psVer ($($PSVersionTable.PSEdition))  ✓"

    # Azure CLI
    $azVersionJson = Invoke-AzCli -Arguments @("version") -AllowFailure
    if ($null -eq $azVersionJson) {
        Write-LogError "Azure CLI (az) is not installed or not in PATH."
        Write-LogDetail "Install via:"
        Write-LogDetail "  Windows:       winget install Microsoft.AzureCLI"
        Write-LogDetail "  macOS:         brew install azure-cli"
        Write-LogDetail "  Debian/Ubuntu: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        Write-LogDetail "  pip:           pip install azure-cli"
        Write-LogDetail "  Azure Cloud Shell: pre-installed"
        exit 1
    }
    $azVer = Get-Prop $azVersionJson "azure-cli" "unknown"
    Write-LogInfo "Azure CLI $azVer  ✓"

    # Azure CLI minimum version check
    $minAzVersion = "2.60.0"
    try {
        $curParts = $azVer.Split('.') | ForEach-Object { [int]$_ }
        $minParts = $minAzVersion.Split('.') | ForEach-Object { [int]$_ }
        $tooOld = $false
        for ($vi = 0; $vi -lt $minParts.Count; $vi++) {
            $c = if ($vi -lt $curParts.Count) { $curParts[$vi] } else { 0 }
            if ($c -lt $minParts[$vi]) { $tooOld = $true; break }
            if ($c -gt $minParts[$vi]) { break }
        }
        if ($tooOld) {
            Write-LogWarn "Azure CLI $azVer is older than recommended minimum $minAzVersion."
            Write-LogDetail "Older versions may have bugs with resource queries or interactive prompts."
            Write-LogDetail "Update via: az upgrade"
            $contChoice = Read-Host "Continue anyway? [y/N/q=exit]"
            if ([string]::IsNullOrWhiteSpace($contChoice)) { $contChoice = "N" }
            if ($contChoice -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
            if ($contChoice -notmatch "^[Yy]$") {
                Write-LogInfo "Exiting. Please update Azure CLI and try again."
                exit 1
            }
        }
    } catch {
        # Can't parse version — skip check
    }

    # Azure CLI config: suppress interactive prompts (survey/telemetry)
    # On Windows, az.cmd blocks on stdin if these aren't set, causing hangs.
    if ($env:OS -eq 'Windows_NT') {
        $azConfigDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME ".azure" }
        $azConfigFile = Join-Path $azConfigDir "config"
        $needsConfig = $false
        if (Test-Path $azConfigFile) {
            try {
                $configText = (Get-Content $azConfigFile -Raw).ToLower()
                if ($configText -notmatch "collect_telemetry") { $needsConfig = $true }
            } catch { $needsConfig = $true }
        } else {
            $needsConfig = $true
        }

        if ($needsConfig) {
            Write-LogWarn "Azure CLI telemetry/survey prompts are not configured."
            Write-LogDetail "On Windows, unconfigured prompts can cause the script to hang."
            $cfgChoice = Read-Host "Allow this script to disable interactive prompts? [Y/n/q=exit]"
            if ([string]::IsNullOrWhiteSpace($cfgChoice)) { $cfgChoice = "Y" }
            if ($cfgChoice -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
            if ($cfgChoice -match "^[Yy]$") {
                Write-LogInfo "Configuring Azure CLI: disabling interactive prompts…"
                $null | & $script:AzExe config set core.collect_telemetry=false core.survey_message=false core.only_show_errors=true 2>$null
                Write-LogInfo "Azure CLI prompts disabled  ✓"
            } else {
                Write-LogWarn "Skipped — the script may hang if az CLI prompts for input."
                Write-LogDetail "You can manually run: az config set core.collect_telemetry=false core.survey_message=false"
            }
        }
    }

    # Azure login check
    $account = Invoke-AzCli -Arguments @("account", "show") -AllowFailure
    if ($null -eq $account) {
        Write-LogWarn "You are not logged into Azure."
        $loginChoice = Read-Host "Would you like to log in now? [Y/n/q=exit]"
        if ([string]::IsNullOrWhiteSpace($loginChoice)) { $loginChoice = "Y" }
        if ($loginChoice -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }

        if ($loginChoice -match "^[Yy]$") {
            $tenantId = Read-Host "Tenant ID (leave blank for default, q=exit)"
            if ($tenantId -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
            if (-not [string]::IsNullOrWhiteSpace($tenantId)) {
                Write-LogInfo "Logging in to tenant $tenantId..."
                & $script:AzExe login --tenant $tenantId --output none 2>$null
            } else {
                Write-LogInfo "Logging in to default tenant…"
                & $script:AzExe login --output none 2>$null
            }

            $account = Invoke-AzCli -Arguments @("account", "show") -AllowFailure
            if ($null -eq $account) {
                Write-LogError "Login failed. Please run 'az login' manually."
                exit 2
            }
        } else {
            Write-LogError "Azure login is required. Run 'az login' to authenticate."
            exit 2
        }
    }

    $currentSub    = Get-Prop $account "name"
    $currentSubId  = Get-Prop $account "id"
    $currentTenant = Get-Prop $account "tenantId"
    $currentUser   = Get-Prop $account "user.name"
    Write-LogInfo "Logged in as: $currentUser"
    Write-LogInfo "Tenant:       $currentTenant"
    Write-LogInfo "Subscription: $currentSub"

    # Offer to switch tenant/subscription or continue with current
    $switchChoice = Read-Host "Continue with this tenant and subscription? [Y/n/q=exit]"
    if ([string]::IsNullOrWhiteSpace($switchChoice)) { $switchChoice = "Y" }
    if ($switchChoice -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }

    if ($switchChoice -notmatch "^[Yy]$") {
        # List available tenants (use az account list for tenant display names)
        Write-LogStep "Switch Tenant"
        Start-Spinner "Fetching available tenants…"
        $subsForTenants = Invoke-AzCli -Arguments @("account", "list", "--query", "[].{tenantId:tenantId, tenantDisplayName:tenantDisplayName}") -AllowFailure -TimeoutSeconds 30
        Stop-Spinner
        # Deduplicate by tenantId, pick first non-empty display name
        $tenantMap = @{}
        if ($null -ne $subsForTenants) {
            if ($subsForTenants -isnot [array]) { $subsForTenants = @($subsForTenants) }
            foreach ($s in $subsForTenants) {
                $tid = Get-Prop $s "tenantId" ""
                $tname = Get-Prop $s "tenantDisplayName" ""
                if (-not [string]::IsNullOrWhiteSpace($tid)) {
                    if (-not $tenantMap.ContainsKey($tid) -or ([string]::IsNullOrWhiteSpace($tenantMap[$tid]) -and -not [string]::IsNullOrWhiteSpace($tname))) {
                        $tenantMap[$tid] = $tname
                    }
                }
            }
        }
        $tenants = @($tenantMap.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ tenantId = $_.Key; displayName = $_.Value } })
        if ($tenants.Count -gt 0) {
            Write-LogInfo "Available tenants:"
            for ($i = 0; $i -lt $tenants.Count; $i++) {
                $tId = $tenants[$i].tenantId
                $tName = $tenants[$i].displayName
                $marker = if ($tId -eq $currentTenant) { " (current)" } else { "" }
                $label = if (-not [string]::IsNullOrWhiteSpace($tName)) { "$tName  [$tId]" } else { "[$tId]" }
                Write-Host "  $($i+1)) $label$marker"
            }
            Write-Host "  0) Enter a Tenant ID manually"
            Write-Host "  q) Exit"
            $tChoice = Read-Host "Tenant [0-$($tenants.Count), q=exit]"
            if ($tChoice -match "^[Qq]$") {
                Write-LogInfo "Exiting."
                exit 0
            } elseif ($tChoice -match "^\d+$" -and [int]$tChoice -ge 1 -and [int]$tChoice -le $tenants.Count) {
                $newTenant = $tenants[[int]$tChoice - 1].tenantId
                Write-LogInfo "Logging in to tenant $newTenant (this may open a browser for MFA)..."
                & $script:AzExe login --tenant $newTenant --output none
                $verify = Invoke-AzCli -Arguments @("account", "show") -AllowFailure
                if ($null -eq $verify) {
                    Write-LogError "Login to new tenant failed."
                    exit 2
                }
                Write-LogInfo "Switched successfully."
                $account = $verify
                $currentSub = Get-Prop $account "name"
                $currentSubId = Get-Prop $account "id"
            } elseif ($tChoice -eq "0") {
                $newTenant = Read-Host "Enter Tenant ID (q=exit)"
                if ($newTenant -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
                if (-not [string]::IsNullOrWhiteSpace($newTenant)) {
                    Write-LogInfo "Logging in to tenant $newTenant (this may open a browser for MFA)..."
                    & $script:AzExe login --tenant $newTenant --output none
                    $verify = Invoke-AzCli -Arguments @("account", "show") -AllowFailure
                    if ($null -eq $verify) {
                        Write-LogError "Login to new tenant failed."
                        exit 2
                    }
                    Write-LogInfo "Switched successfully."
                    $account = $verify
                    $currentSub = Get-Prop $account "name"
                    $currentSubId = Get-Prop $account "id"
                } else {
                    Write-LogWarn "No tenant ID provided — continuing with current tenant."
                }
            } else {
                Write-LogWarn "Invalid selection — continuing with current tenant."
            }
        } else {
            # Fallback: no tenant list available, ask manually
            $newTenant = Read-Host "Enter the Tenant ID to switch to (q=exit)"
            if ($newTenant -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
            if (-not [string]::IsNullOrWhiteSpace($newTenant)) {
                Write-LogInfo "Logging in to tenant $newTenant (this may open a browser for MFA)..."
                & $script:AzExe login --tenant $newTenant --output none
                $verify = Invoke-AzCli -Arguments @("account", "show") -AllowFailure
                if ($null -eq $verify) {
                    Write-LogError "Login to new tenant failed."
                    exit 2
                }
                Write-LogInfo "Switched successfully."
                $account = $verify
                $currentSub = Get-Prop $account "name"
                $currentSubId = Get-Prop $account "id"
            } else {
                Write-LogWarn "No tenant ID provided — continuing with current tenant."
            }
        }
    }

    # Store accepted subscription for later use
    $script:AcceptedSubId = $currentSubId
    $script:AcceptedSubName = $currentSub

    # Ensure resource-graph extension
    $extCheck = Invoke-AzCli -Arguments @("extension", "show", "--name", "resource-graph") -AllowFailure
    if ($null -eq $extCheck) {
        Write-LogWarn "The 'resource-graph' Azure CLI extension is required but not installed."
        $extChoice = Read-Host "Install it now? [Y/n/q=exit]"
        if ([string]::IsNullOrWhiteSpace($extChoice)) { $extChoice = "Y" }
        if ($extChoice -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
        if ($extChoice -match "^[Yy]$") {
            Write-LogInfo "Installing 'resource-graph' extension…"
            $null | & $script:AzExe extension add --name resource-graph --yes --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-LogInfo "Extension 'resource-graph' installed  ✓"
            } else {
                Write-LogError "Failed to install 'resource-graph' extension."
                Write-LogDetail "Install manually: az extension add --name resource-graph"
                exit 1
            }
        } else {
            Write-LogError "The 'resource-graph' extension is required for this script."
            Write-LogDetail "Install manually: az extension add --name resource-graph"
            exit 1
        }
    }

    Write-LogInfo "Prerequisites satisfied  ✓"
    return $account
}

# ── Interactive selection helpers ────────────────────────────────────────────
function Read-Selection {
    param([string]$Prompt, [int]$Max)
    while ($true) {
        $choice = Read-Host $Prompt
        if ($choice -match "^[Qq]$") {
            Write-LogInfo "Exiting."
            exit 0
        }
        if ($choice -match "^\d+$" -and [int]$choice -ge 1 -and [int]$choice -le $Max) {
            return [int]$choice
        }
        Write-Host "  Enter a number between 1 and $Max (or 'q' to exit)."
    }
}

function Select-Subscription {
    Write-LogStep "Select Azure Subscription"
    $subs = Invoke-WithRetry "List subscriptions" @("account", "list", "--query", "[?state=='Enabled']")
    if (-not $subs -or $subs.Count -eq 0) {
        Write-LogError "No enabled subscriptions found."
        exit 1
    }
    # Ensure array
    if ($subs -isnot [array]) { $subs = @($subs) }

    for ($i = 0; $i -lt $subs.Count; $i++) {
        Write-Host "  $($i+1)) $($subs[$i].name)  [$($subs[$i].id)]"
    }
    $idx = Read-Selection "Subscription [1-$($subs.Count)]" $subs.Count
    $sub = $subs[$idx - 1]
    Write-LogInfo "Selected: $($sub.name) ($($sub.id))"
    return @{ Id = $sub.id; Name = $sub.name }
}

function Select-ResourceGroup {
    param([string]$SubId)
    Write-LogStep "Select Resource Group"
    $rgs = Invoke-WithRetry "List resource groups" @("group", "list", "--subscription", $SubId)
    if (-not $rgs -or $rgs.Count -eq 0) {
        Write-LogError "No resource groups found."
        exit 1
    }
    if ($rgs -isnot [array]) { $rgs = @($rgs) }

    for ($i = 0; $i -lt $rgs.Count; $i++) {
        Write-Host "  $($i+1)) $($rgs[$i].name)  ($(Get-Prop $rgs[$i] 'location'))"
    }
    $idx = Read-Selection "Resource Group [1-$($rgs.Count)]" $rgs.Count
    $name = $rgs[$idx - 1].name
    Write-LogInfo "Selected: $name"
    return $name
}

function Select-VNet {
    param([string]$SubId, [string]$RgName)
    Write-LogStep "Select Starting Network"
    Write-LogInfo "Discovery crawls outward from the selected network, following peerings, hub connections, and vWAN links."

    Write-LogDetail "Querying VNets in resource group '$RgName'…"
    $vnets = Invoke-WithRetry "List VNets" @("network", "vnet", "list", "--subscription", $SubId, "--resource-group", $RgName)
    if ($null -eq $vnets) { $vnets = @() }; if ($vnets -isnot [array]) { $vnets = @($vnets) }
    Write-LogDetail "Found $($vnets.Count) VNet(s)"

    Write-LogDetail "Querying Virtual Hubs in resource group '$RgName'…"
    $vhubs = Invoke-WithRetry "List vHubs" @("network", "vhub", "list", "--subscription", $SubId, "--resource-group", $RgName) -AllowFailure -TimeoutSeconds 60
    if ($null -eq $vhubs) { $vhubs = @() }; if ($vhubs -isnot [array]) { $vhubs = @($vhubs) }
    Write-LogDetail "Found $($vhubs.Count) Virtual Hub(s)"

    $total = $vnets.Count + $vhubs.Count
    if ($total -eq 0) {
        Write-LogWarn "No VNets or Virtual Hubs found in '$RgName'."
        exit 1
    }

    if ($vnets.Count -gt 0) {
        Write-Host "  VNets:"
        for ($i = 0; $i -lt $vnets.Count; $i++) {
            $prefixes = (Get-Prop $vnets[$i] "addressSpace.addressPrefixes" @()) -join ", "
            Write-Host "    $($i+1)) $($vnets[$i].name)  [$prefixes]"
        }
    }
    if ($vhubs.Count -gt 0) {
        Write-Host "  Virtual Hubs:"
        for ($i = 0; $i -lt $vhubs.Count; $i++) {
            $num = $vnets.Count + $i + 1
            $prefix = Get-Prop $vhubs[$i] "addressPrefix" ""
            $loc = Get-Prop $vhubs[$i] "location" ""
            Write-Host "    $num) $($vhubs[$i].name)  [$prefix] ($loc)"
        }
    }

    Write-Host "  0) All VNets and Virtual Hubs in $RgName"
    Write-Host "  q) Exit"
    $choice = Read-Host "Select [0-$total, q=exit] (0=all)"
    if ($choice -match "^[Qq]$") {
        Write-LogInfo "Exiting."
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "0") {
        # Large environment warning
        Write-LogWarn "'All' mode will discover every VNet and Virtual Hub in this"
        Write-LogWarn "resource group, including all peered networks across subscriptions."
        Write-LogWarn "In large environments this can take a very long time."
        Write-LogWarn "Consider selecting a specific VNet or vHub as an entry point instead."
        $confirm = Read-Host "  Continue with 'All' mode? [y/N/q=exit]"
        if ($confirm -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
        if ($confirm -notmatch "^[Yy]$") {
            Write-LogInfo "Cancelled. Please select a specific resource."
            Write-Host ""
            return Select-VNet -SubId $SubId -RgName $RgName
        }
        Write-LogInfo "Will discover all VNets and Virtual Hubs in $RgName"
        return @{ Id = ""; Type = "All" }
    }
    if ($choice -match "^\d+$") {
        $idx = [int]$choice
        if ($idx -ge 1 -and $idx -le $vnets.Count) {
            $v = $vnets[$idx - 1]
            Write-LogInfo "Starting from VNet: $($v.name)"
            return @{ Id = $v.id; Type = "Microsoft.Network/virtualNetworks" }
        }
        if ($idx -gt $vnets.Count -and $idx -le $total) {
            $h = $vhubs[$idx - $vnets.Count - 1]
            Write-LogInfo "Starting from vHub: $($h.name)"
            return @{ Id = $h.id; Type = "Microsoft.Network/virtualHubs" }
        }
    }
    Write-Host "  Invalid selection."
    return Select-VNet -SubId $SubId -RgName $RgName
}

function Read-DiagramTitle {
    param([string]$Existing)
    if (-not [string]::IsNullOrWhiteSpace($Existing)) { return $Existing }
    $title = Read-Host "Diagram title (q=exit)"
    if ($title -match "^[Qq]$") { Write-LogInfo "Exiting."; exit 0 }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "Azure Network Topology — $((Get-Date -Format 'yyyy-MM-dd'))"
    }
    return $title
}

# ── vWAN Hub detection ───────────────────────────────────────────────────────
function Test-VHubVNetId {
    param([string]$ArmId)
    $lower = $ArmId.ToLower()
    $vnetName = Get-ArmBasename $lower
    if ($lower -match "^/subscriptions/[^/]*/resourcegroups/([^/]*)/") {
        $rgName = $Matches[1]
    } else { return $false }
    return $vnetName.StartsWith("hv_") -and $rgName.StartsWith("rg_")
}

function Test-VHubResourceId {
    param([string]$ArmId)
    return $ArmId.ToLower().Contains("microsoft.network/virtualhubs/")
}

function Resolve-VHubIdFromVNet {
    param([string]$VNetId)
    $subId = Get-SubscriptionFromId $VNetId
    $vnetName = Get-ArmBasename $VNetId

    # Strip HV_ prefix
    $withoutPrefix = $vnetName -replace "^[Hh][Vv]_", ""
    # Strip trailing _<guid>
    $hubNameGuess = $withoutPrefix -replace "_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", ""
    if ([string]::IsNullOrWhiteSpace($hubNameGuess)) { $hubNameGuess = $withoutPrefix }

    Write-LogSubstep "Resolving vHub '$hubNameGuess'..."

    # Approach 1: Resource Graph by name (same subscription)
    if (-not [string]::IsNullOrWhiteSpace($hubNameGuess)) {
        $query = "Resources | where type =~ 'microsoft.network/virtualhubs' and name =~ '$hubNameGuess' | project id, name"
        $result = Invoke-WithRetry "Find vHub by name (same sub)" @("graph", "query", "-q", $query, "--subscriptions", $subId, "--first", "10") -AllowFailure
        $data = @()
        if ($null -ne $result) { $data = @(Get-Prop $result "data" @()) }
        if ($data.Count -gt 0) {
            Write-LogFound "Resolved → $($data[0].id)"
            return $data[0].id
        }

        # Cross-subscription
        Write-LogSubstep "Not in local subscription — searching cross-subscription..."
        $result = Invoke-WithRetry "Find vHub by name (all subs)" @("graph", "query", "-q", $query, "--first", "10") -AllowFailure
        $data = @()
        if ($null -ne $result) { $data = @(Get-Prop $result "data" @()) }
        if ($data.Count -gt 0) {
            Write-LogFound "Resolved (cross-subscription) → $(Get-ArmBasename $data[0].id)"
            return $data[0].id
        }
    }

    # Approach 2: List all vHubs, match by name
    $vhubList = Invoke-WithRetry "List vHubs" @("network", "vhub", "list", "--subscription", $subId) -AllowFailure -TimeoutSeconds 30
    if ($null -eq $vhubList) { $vhubList = @() }; if ($vhubList -isnot [array]) { $vhubList = @($vhubList) }

    foreach ($h in $vhubList) {
        if ($h.name -and $h.name.ToLower() -eq $hubNameGuess.ToLower()) {
            Write-LogFound "Resolved → $(Get-ArmBasename $h.id)"
            return $h.id
        }
    }

    # Approach 3: Single vHub in subscription
    if ($vhubList.Count -eq 1) {
        Write-LogFound "Single vHub in subscription → $(Get-ArmBasename $vhubList[0].id)"
        return $vhubList[0].id
    }

    Write-LogSubstep "Could not resolve vHub from managed VNet"
    return $null
}

# ── Discovery functions ─────────────────────────────────────────────────────
function Resolve-SubnetId {
    param($Resource, [string]$TypeLower)
    $props = $Resource.properties
    if ($null -eq $props) { return "" }

    # NOTE: @() wrapping is required on all Get-Prop calls that return arrays.
    # PowerShell's pipeline unwraps single-element arrays to scalar objects,
    # causing -is [array] checks to fail and silently dropping resources.
    if ($TypeLower -like "*networkinterfaces*") {
        $ip = @(Get-Prop $props "ipConfigurations")
        if ($ip.Count -gt 0) {
            return Get-Prop $ip[0] "properties.subnet.id" ""
        }
        return ""
    }
    if ($TypeLower -like "*applicationgateways*") {
        $gw = @(Get-Prop $props "gatewayIPConfigurations")
        if ($gw.Count -gt 0) {
            return Get-Prop $gw[0] "properties.subnet.id" ""
        }
        return ""
    }
    if ($TypeLower -like "*privateendpoints*") {
        return Get-Prop $props "subnet.id" ""
    }
    if ($TypeLower -like "*loadbalancers*") {
        $fes = @(Get-Prop $props "frontendIPConfigurations" @())
        foreach ($fe in $fes) {
            $sid = Get-Prop $fe "properties.subnet.id" ""
            if (-not [string]::IsNullOrWhiteSpace($sid)) { return $sid }
        }
        return ""
    }
    if ($TypeLower -like "*azurefirewalls*" -or $TypeLower -like "*virtualnetworkgateways*" -or
        $TypeLower -like "*bastionhosts*" -or $TypeLower -like "*natgateways*" -or
        $TypeLower -like "*dnsresolvers*") {
        $ip = @(Get-Prop $props "ipConfigurations")
        if ($ip.Count -gt 0) {
            return Get-Prop $ip[0] "properties.subnet.id" ""
        }
        return ""
    }
    return ""
}

function Get-ResourceSubType {
    param($Resource, [string]$TypeLower, [string]$SubnetName)
    $props = $Resource.properties
    if ($null -eq $props) { return "" }

    if ($TypeLower -like "*virtualnetworkgateways*") { return Get-Prop $props "gatewayType" "" }
    if ($TypeLower -like "*applicationgateways*")    { return Get-Prop $props "sku.tier" "" }
    if ($TypeLower -like "*privateendpoints*") {
        $conns = @(Get-Prop $props "privateLinkServiceConnections" @())
        foreach ($c in $conns) {
            $groups = @(Get-Prop $c "properties.groupIds" @())
            if ($groups.Count -gt 0) { return $groups[0] }
        }
        return ""
    }
    if ($TypeLower -like "*loadbalancers*") {
        $fes = @(Get-Prop $props "frontendIPConfigurations" @())
        foreach ($fe in $fes) {
            if (Get-Prop $fe "properties.publicIPAddress" $null) { return "Public" }
        }
        return "Internal"
    }
    if ($TypeLower -like "*dnsresolvers*") {
        if ($SubnetName.ToLower() -like "*inbound*")  { return "Inbound" }
        if ($SubnetName.ToLower() -like "*outbound*") { return "Outbound" }
        return ""
    }
    return ""
}

function Get-PublicIps {
    param($Resource, [string]$TypeLower)
    $props = $Resource.properties
    $pipIds = @()
    if ($TypeLower -like "*virtualnetworkgateways*" -or $TypeLower -like "*azurefirewalls*" -or $TypeLower -like "*bastionhosts*") {
        $ipCfgs = @(Get-Prop $props "ipConfigurations" @())
        foreach ($cfg in $ipCfgs) {
            $pipId = Get-Prop $cfg "properties.publicIPAddress.id" ""
            if (-not [string]::IsNullOrWhiteSpace($pipId)) { $pipIds += $pipId }
        }
    } elseif ($TypeLower -like "*applicationgateways*") {
        $fes = @(Get-Prop $props "frontendIPConfigurations" @())
        foreach ($fe in $fes) {
            $pipId = Get-Prop $fe "properties.publicIPAddress.id" ""
            if (-not [string]::IsNullOrWhiteSpace($pipId)) { $pipIds += $pipId }
        }
    }
    $ips = @()
    foreach ($pipId in $pipIds) {
        $ip = Invoke-AzCliText @("network", "public-ip", "show", "--ids", $pipId, "--query", "ipAddress")
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $ips += $ip }
    }
    return $ips
}

function Discover-VNet {
    param([string]$VNetId)

    $vnetJson = Invoke-WithRetry "Get VNet $(Get-ArmBasename $VNetId)" @("network", "vnet", "show", "--ids", $VNetId) -AllowFailure
    if ($null -eq $vnetJson) { $vnetJson = [PSCustomObject]@{} }

    $vnetName = Get-Prop $vnetJson "name" (Get-ArmBasename $VNetId)
    $addressPrefixes = @(Get-Prop $vnetJson "addressSpace.addressPrefixes" @())
    $location = Get-Prop $vnetJson "location" "unknown"
    $rg = Get-Prop $vnetJson "resourceGroup" "unknown"
    $dnsServers = @(Get-Prop $vnetJson "dhcpOptions.dnsServers" @())

    # ── Subnets ──
    $subnets = [System.Collections.ArrayList]::new()
    $rawSubnets = @(Get-Prop $vnetJson "subnets" @())
    foreach ($s in $rawSubnets) {
        $sname = Get-Prop $s "name" ""
        $sprefix = Get-Prop $s "addressPrefix" ""
        if ([string]::IsNullOrWhiteSpace($sprefix)) {
            $ap = @(Get-Prop $s "addressPrefixes" @())
            if ($ap.Count -gt 0) { $sprefix = $ap -join ", " } else { $sprefix = "unknown" }
        }
        $subnetObj = [ordered]@{
            id = (Get-Prop $s "id" $sname); name = $sname; addressPrefix = $sprefix; resources = @()
        }
        $nsgRef = Get-Prop $s "networkSecurityGroup.id" ""
        if (-not [string]::IsNullOrWhiteSpace($nsgRef)) { $subnetObj["nsg"] = [ordered]@{ id = $nsgRef; name = Get-ArmBasename $nsgRef } }
        $rtRef = Get-Prop $s "routeTable.id" ""
        if (-not [string]::IsNullOrWhiteSpace($rtRef)) { $subnetObj["routeTable"] = [ordered]@{ id = $rtRef; name = Get-ArmBasename $rtRef } }

        # Subnet enrichment (FR-005 to FR-011)
        # Service endpoints — omit when empty
        $svcEps = @(Get-Prop $s "serviceEndpoints" @())
        if ($svcEps.Count -gt 0) {
            $subnetObj["serviceEndpoints"] = @($svcEps | ForEach-Object {
                $ep = [ordered]@{ service = (Get-Prop $_ "service" "") }
                $ps = Get-Prop $_ "provisioningState" ""
                if (-not [string]::IsNullOrWhiteSpace($ps)) { $ep["provisioningState"] = $ps }
                $ep
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.service) })
        }

        # Private endpoint network policies — omit when "Enabled" (default)
        $pePolicy = Get-Prop $s "privateEndpointNetworkPolicies" ""
        if (-not [string]::IsNullOrWhiteSpace($pePolicy) -and $pePolicy -ne "Enabled") {
            $subnetObj["privateEndpointNetworkPolicies"] = $pePolicy
        }

        # Private link service network policies — omit when "Enabled" (default)
        $plsPolicy = Get-Prop $s "privateLinkServiceNetworkPolicies" ""
        if (-not [string]::IsNullOrWhiteSpace($plsPolicy) -and $plsPolicy -ne "Enabled") {
            $subnetObj["privateLinkServiceNetworkPolicies"] = $plsPolicy
        }

        # Delegations — omit when empty
        $delegations = @(Get-Prop $s "delegations" @())
        if ($delegations.Count -gt 0) {
            $subnetObj["delegations"] = @($delegations | ForEach-Object {
                $svcName = Get-Prop $_ "serviceName" ""
                if ([string]::IsNullOrWhiteSpace($svcName)) { $svcName = Get-Prop $_ "properties.serviceName" "" }
                if (-not [string]::IsNullOrWhiteSpace($svcName)) { [ordered]@{ serviceName = $svcName } }
            } | Where-Object { $null -ne $_ })
        }

        [void]$subnets.Add($subnetObj)
    }

    # Subnet lookup
    $subnetIdx = @{}
    for ($i = 0; $i -lt $subnets.Count; $i++) { $subnetIdx[$subnets[$i].name] = $i }

    # ── Resources per subnet (via Resource Graph) ──
    $subId = Get-SubscriptionFromId $VNetId

    Write-LogSubstep "Querying subnet resources..."
    $resQuery = @"
Resources
| where type in~ (
    'microsoft.network/networkinterfaces',
    'microsoft.network/applicationgateways',
    'microsoft.network/privateendpoints',
    'microsoft.network/loadbalancers',
    'microsoft.network/azurefirewalls',
    'microsoft.network/virtualnetworkgateways',
    'microsoft.network/bastionhosts',
    'microsoft.network/natgateways',
    'microsoft.network/dnsresolvers'
)
| where properties.ipConfigurations[0].properties.subnet.id startswith '$VNetId'
    or properties.gatewayIPConfigurations[0].properties.subnet.id startswith '$VNetId'
    or properties.subnet.id startswith '$VNetId'
    or properties.ipConfigurations[0].subnet.id startswith '$VNetId'
    or properties.ipConfiguration.properties.subnet.id startswith '$VNetId'
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags
| order by type asc, name asc
"@

    $resData = @(Invoke-GraphQueryPaginated -Label "Query resources for $vnetName" -Query $resQuery -Subscription $subId -ErrorScope "subnet-resources:$vnetName")
    Write-LogFound "$($resData.Count) resource(s) found"

    # Query VMs
    $vmQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualMachines'
| where isnotnull(properties.networkProfile)
| mv-expand nic = properties.networkProfile.networkInterfaces
| project vmId=id, vmName=name, vmType=type, nicId=tolower(nic.id), location, resourceGroup, subscriptionId, tags
"@
    $vmsData = @(Invoke-GraphQueryPaginated -Label "Query VMs" -Query $vmQuery -Subscription $subId -ErrorScope "vm-query:$vnetName" -IdField "vmId")
    $vmByNic = @{}
    foreach ($vm in $vmsData) {
        $nicId = Get-Prop $vm "nicId" ""
        if (-not [string]::IsNullOrWhiteSpace($nicId)) { $vmByNic[$nicId] = $vm }
    }

    # Also query VMSS to resolve VMSS instance NICs → parent VMSS
    $vmssQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualMachineScaleSets'
| where isnotnull(properties.virtualMachineProfile.networkProfile)
| mv-expand nicCfg = properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations
| mv-expand ipCfg = nicCfg.properties.ipConfigurations
| where ipCfg.properties.subnet.id startswith '$VNetId'
| project vmssId=id, vmssName=name, location, resourceGroup, subscriptionId, tags, sku
"@
    $vmssData = @(Invoke-GraphQueryPaginated -Label "Query VMSS" -Query $vmssQuery -Subscription $subId -ErrorScope "vmss-query:$vnetName" -IdField "vmssId")
    $vmssById = @{}
    foreach ($vmss in $vmssData) {
        $vmssIdKey = (Get-Prop $vmss "vmssId" "").ToLower()
        if (-not [string]::IsNullOrWhiteSpace($vmssIdKey)) { $vmssById[$vmssIdKey] = $vmss }
    }

    # Map resources to subnets
    foreach ($res in $resData) {
        $rid = Get-Prop $res "id" ""
        $rname = Get-Prop $res "name" ""
        $rtype = Get-Prop $res "type" ""
        $rloc = Get-Prop $res "location" ""
        $rtags = Get-Prop $res "tags" @{}
        if ($null -eq $rtags) { $rtags = @{} }
        $rtypeLower = $rtype.ToLower()

        $rsubnetId = Resolve-SubnetId -Resource $res -TypeLower $rtypeLower
        if ([string]::IsNullOrWhiteSpace($rsubnetId)) { continue }

        # Validate resource actually belongs to the current VNet
        if (-not $rsubnetId.ToLower().StartsWith($VNetId.ToLower())) {
            Write-LogWarn "Skipping resource '$rname' ($rtype) — subnet '$rsubnetId' does not belong to VNet '$(Get-ArmBasename $VNetId)'"
            continue
        }

        $subnetNameForRes = Get-ArmBasename $rsubnetId
        if (-not $subnetIdx.ContainsKey($subnetNameForRes)) { continue }

        # Handle NICs → resolve to VM or VMSS
        if ($rtypeLower -like "*networkinterfaces*") {
            $vmRef = Get-Prop $res "properties.virtualMachine.id" ""
            if (-not [string]::IsNullOrWhiteSpace($vmRef)) {
                # Check if this NIC belongs to a VMSS instance
                if ($vmRef -match "(?i)/virtualMachineScaleSets/[^/]+/virtualMachines/") {
                    # Extract parent VMSS resource id
                    $parentVmssId = ($vmRef -replace "(?i)/virtualMachines/.*$", "")
                    $vmssInfo = $vmssById[$parentVmssId.ToLower()]
                    $vmssName = if ($vmssInfo) { Get-Prop $vmssInfo "vmssName" (Get-ArmBasename $parentVmssId) } else { Get-ArmBasename $parentVmssId }
                    $vmssTags = if ($vmssInfo) { Get-Prop $vmssInfo "tags" @{} } else { @{} }
                    if ($null -eq $vmssTags) { $vmssTags = @{} }
                    $vmssSku = ""
                    if ($vmssInfo) {
                        $skuObj = Get-Prop $vmssInfo "sku" @{}
                        $vmssSku = Get-Prop $skuObj "name" ""
                    }

                    $vmssResource = [ordered]@{
                        id = $parentVmssId; name = $vmssName; type = "Microsoft.Compute/virtualMachineScaleSets"
                        location = $rloc; tags = $vmssTags
                    }
                    if (-not [string]::IsNullOrWhiteSpace($vmssSku)) { $vmssResource["subType"] = $vmssSku }

                    $sIdx = $subnetIdx[$subnetNameForRes]
                    $existing = $subnets[$sIdx].resources | Where-Object { $_.id -eq $parentVmssId }
                    if (-not $existing) {
                        $subnets[$sIdx].resources = @($subnets[$sIdx].resources) + @($vmssResource)
                    }
                } else {
                    # Regular VM
                    $vmInfo = $vmByNic[$rid.ToLower()]
                    $vmName = if ($vmInfo) { Get-Prop $vmInfo "vmName" (Get-ArmBasename $vmRef) } else { Get-ArmBasename $vmRef }
                    $vmTags = if ($vmInfo) { Get-Prop $vmInfo "tags" @{} } else { @{} }
                    if ($null -eq $vmTags) { $vmTags = @{} }

                    $vmResource = [ordered]@{
                        id = $vmRef; name = $vmName; type = "Microsoft.Compute/virtualMachines"
                        location = $rloc; tags = $vmTags
                    }
                    $sIdx = $subnetIdx[$subnetNameForRes]
                    $existing = $subnets[$sIdx].resources | Where-Object { $_.id -eq $vmRef }
                    if (-not $existing) {
                        $subnets[$sIdx].resources = @($subnets[$sIdx].resources) + @($vmResource)
                    }
                }
            }
            continue
        }

        $subType = Get-ResourceSubType -Resource $res -TypeLower $rtypeLower -SubnetName $subnetNameForRes
        $publicIps = @(Get-PublicIps -Resource $res -TypeLower $rtypeLower)

        $resObj = [ordered]@{
            id = $rid; name = $rname; type = $rtype; location = $rloc; tags = $rtags
        }
        if (-not [string]::IsNullOrWhiteSpace($subType)) { $resObj["subType"] = $subType }
        if ($publicIps.Count -gt 0) { $resObj["publicIps"] = $publicIps }

        $sIdx = $subnetIdx[$subnetNameForRes]
        $existing = $subnets[$sIdx].resources | Where-Object { $_.id -eq $rid }
        if (-not $existing) {
            $subnets[$sIdx].resources = @($subnets[$sIdx].resources) + @($resObj)
        }
    }

    # ── VNet-injected / delegation-based resources ──
    # Discover resources that integrate via subnet delegation (App Service, APIM,
    # SQL MI, Container Apps Environments, Databricks, NetApp, etc.)
    Write-LogSubstep "Querying VNet-injected resources (App Service, APIM, SQL MI, etc.)..."
    $delegQuery = @"
Resources
| where type in~ (
    'microsoft.web/sites',
    'microsoft.apimanagement/service',
    'microsoft.sql/managedinstances',
    'microsoft.app/managedenvironments',
    'microsoft.containerinstance/containergroups',
    'microsoft.databricks/workspaces',
    'microsoft.netapp/netappaccounts/capacitypools/volumes',
    'microsoft.kusto/clusters'
)
| where properties.virtualNetworkSubnetId startswith '$VNetId'
    or properties.subnetId startswith '$VNetId'
    or properties.virtualNetworkConfiguration.subnetResourceId startswith '$VNetId'
    or properties.subnetIds[0].id startswith '$VNetId'
    or properties.vnetConfiguration.infrastructureSubnetId startswith '$VNetId'
    or properties.parameters.customVirtualNetworkId.value =~ '$VNetId'
    or properties.virtualNetworkConfiguration.subnetId startswith '$VNetId'
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags, kind
| order by type asc, name asc
"@

    $delegData = @(Invoke-GraphQueryPaginated -Label "Query VNet-injected resources for $vnetName" -Query $delegQuery -Subscription $subId -ErrorScope "delegated-resources:$vnetName")
    Write-LogFound "$($delegData.Count) VNet-injected resource(s) found"

    foreach ($res in $delegData) {
        $rid = Get-Prop $res "id" ""
        $rname = Get-Prop $res "name" ""
        $rtype = Get-Prop $res "type" ""
        $rloc = Get-Prop $res "location" ""
        $rtags = Get-Prop $res "tags" @{}
        $rtypeLower = $rtype.ToLower()

        # Resolve subnet ID based on resource type
        $delegSubnetId = ""
        if ($rtypeLower -like "*microsoft.web/sites*") {
            $delegSubnetId = Get-Prop $res "properties.virtualNetworkSubnetId" ""
        } elseif ($rtypeLower -like "*apimanagement*") {
            $delegSubnetId = Get-Prop $res "properties.virtualNetworkConfiguration.subnetResourceId" ""
        } elseif ($rtypeLower -like "*managedinstances*") {
            $delegSubnetId = Get-Prop $res "properties.subnetId" ""
        } elseif ($rtypeLower -like "*managedenvironments*") {
            $delegSubnetId = Get-Prop $res "properties.vnetConfiguration.infrastructureSubnetId" ""
        } elseif ($rtypeLower -like "*containergroups*") {
            $subnetIds = @(Get-Prop $res "properties.subnetIds" @())
            if ($subnetIds.Count -gt 0) {
                $delegSubnetId = Get-Prop $subnetIds[0] "id" ""
            }
        } elseif ($rtypeLower -like "*databricks*") {
            $dbricksVnet = Get-Prop $res "properties.parameters.customVirtualNetworkId.value" ""
            if (-not [string]::IsNullOrWhiteSpace($dbricksVnet)) {
                $dbricksSub = Get-Prop $res "properties.parameters.customPublicSubnetName.value" ""
                if ([string]::IsNullOrWhiteSpace($dbricksSub)) {
                    $dbricksSub = Get-Prop $res "properties.parameters.customPrivateSubnetName.value" ""
                }
                if (-not [string]::IsNullOrWhiteSpace($dbricksSub)) {
                    $delegSubnetId = "$dbricksVnet/subnets/$dbricksSub"
                }
            }
        } elseif ($rtypeLower -like "*netapp*") {
            $delegSubnetId = Get-Prop $res "properties.subnetId" ""
        } elseif ($rtypeLower -like "*kusto*") {
            $delegSubnetId = Get-Prop $res "properties.virtualNetworkConfiguration.subnetId" ""
        }

        if ([string]::IsNullOrWhiteSpace($delegSubnetId)) { continue }

        # Validate resource actually belongs to the current VNet
        if (-not $delegSubnetId.ToLower().StartsWith($VNetId.ToLower())) {
            Write-LogWarn "Skipping delegated resource '$(Get-Prop $res 'name' '')' ($(Get-Prop $res 'type' '')) — subnet '$delegSubnetId' does not belong to VNet '$(Get-ArmBasename $VNetId)'"
            continue
        }

        $delegSubnetName = Get-ArmBasename $delegSubnetId
        if (-not $subnetIdx.ContainsKey($delegSubnetName)) { continue }

        # Determine subType
        $delegSubType = ""
        if ($rtypeLower -like "*microsoft.web/sites*") {
            $dkind = (Get-Prop $res "kind" "").ToLower()
            if ($dkind -like "*functionapp*") { $delegSubType = "Function App" }
            elseif ($dkind -like "*linux*") { $delegSubType = "Linux" }
            else { $delegSubType = "Windows" }
        } elseif ($rtypeLower -like "*apimanagement*") {
            $delegSubType = Get-Prop $res "properties.sku.name" ""
        } elseif ($rtypeLower -like "*managedinstances*") {
            $delegSubType = Get-Prop $res "properties.sku.tier" ""
        } elseif ($rtypeLower -like "*managedenvironments*") {
            $delegSubType = "Container Apps"
        } elseif ($rtypeLower -like "*databricks*") {
            $delegSubType = Get-Prop $res "sku.name" ""
        } elseif ($rtypeLower -like "*netapp*") {
            $delegSubType = Get-Prop $res "properties.serviceLevel" ""
        } elseif ($rtypeLower -like "*kusto*") {
            $delegSubType = Get-Prop $res "properties.sku.name" ""
        }

        $delegResObj = [ordered]@{
            id = $rid; name = $rname; type = $rtype; location = $rloc; tags = $rtags
        }
        if (-not [string]::IsNullOrWhiteSpace($delegSubType)) { $delegResObj["subType"] = $delegSubType }

        $sIdx = $subnetIdx[$delegSubnetName]
        $existing = $subnets[$sIdx].resources | Where-Object { $_.id -eq $rid }
        if (-not $existing) {
            $subnets[$sIdx].resources = @($subnets[$sIdx].resources) + @($delegResObj)
        }
    }

    # ── Peerings ──
    $peerings = @()
    $rawPeerings = @(Get-Prop $vnetJson "virtualNetworkPeerings" @())
    foreach ($p in $rawPeerings) {
        $peerings += [ordered]@{
            name                 = Get-Prop $p "name" ""
            remoteVnetId         = Get-Prop $p "remoteVirtualNetwork.id" ""
            state                = Get-Prop $p "peeringState" "Unknown"
            allowForwardedTraffic = [bool](Get-Prop $p "allowForwardedTraffic" $false)
            allowGatewayTransit   = [bool](Get-Prop $p "allowGatewayTransit" $false)
            useRemoteGateways     = [bool](Get-Prop $p "useRemoteGateways" $false)
        }
    }

    $vnetObj = [ordered]@{
        id = $VNetId; name = $vnetName; addressSpace = $addressPrefixes
        location = $location; resourceGroup = $rg
        subnets = @($subnets); peerings = $peerings
    }
    $vnetTags = Get-Prop $vnetJson "tags" $null
    if ($null -ne $vnetTags) {
        $tagHash = @{}
        $vnetTags.PSObject.Properties | ForEach-Object { $tagHash[$_.Name] = $_.Value }
        if ($tagHash.Count -gt 0) { $vnetObj["tags"] = $tagHash }
    }
    if ($dnsServers.Count -gt 0) { $vnetObj["dnsServers"] = $dnsServers }

    return $vnetObj
}

# ── Discover a Virtual Hub ──────────────────────────────────────────────────
function Discover-VHub {
    param(
        [string]$VHubId,
        [string]$OriginalVNetId,
        [System.Collections.ArrayList]$ErCircuits,
        [System.Collections.ArrayList]$Lngs
    )

    $subId = Get-SubscriptionFromId $VHubId
    Write-LogDetail "Hub resource: $(Get-ArmBasename $VHubId)"

    $vhubJson = Invoke-WithRetry "Get vHub" @("network", "vhub", "show", "--ids", $VHubId) -AllowFailure
    if ($null -eq $vhubJson) { $vhubJson = [PSCustomObject]@{} }

    $vhubName       = Get-Prop $vhubJson "name" (Get-ArmBasename $VHubId)
    $location       = Get-Prop $vhubJson "location" "unknown"
    $rg             = Get-Prop $vhubJson "resourceGroup" "unknown"
    $addressPrefix  = Get-Prop $vhubJson "addressPrefix" ""
    $vwanId         = Get-Prop $vhubJson "virtualWan.id" ""

    $hubRoutingPref = Get-Prop $vhubJson "hubRoutingPreference" "ExpressRoute"
    $allowB2b       = [bool](Get-Prop $vhubJson "allowBranchToBranchTraffic" $false)
    $routingState   = Get-Prop $vhubJson "routingState" "Unknown"
    $hubSku         = Get-Prop $vhubJson "sku" "Basic"
    $hubAsn         = [int](Get-Prop $vhubJson "virtualRouterAsn" 0)
    $hubRouterIps   = @(Get-Prop $vhubJson "virtualRouterIps" @())

    $addressSpace = if (-not [string]::IsNullOrWhiteSpace($addressPrefix)) { @($addressPrefix) } else { @() }
    $hubResources = [System.Collections.ArrayList]::new()

    # ── 1. ExpressRoute Gateways ──
    Write-LogSubstep "Checking ER gateways..."
    $erGwList = Invoke-WithRetry "List vHub ER GWs" @("network", "express-route", "gateway", "list", "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -eq $erGwList) { $erGwList = @() }
    if ($erGwList -is [PSCustomObject] -and $erGwList.PSObject.Properties.Name -contains "value") { $erGwList = $erGwList.value }
    if ($erGwList -isnot [array]) { $erGwList = @($erGwList) }

    foreach ($gw in $erGwList) {
        # Skip gateways that belong to a different vHub in the same RG
        $gwVHubId = Get-Prop $gw "virtualHub.id" ""
        if (-not [string]::IsNullOrWhiteSpace($gwVHubId) -and $gwVHubId -ine $VHubId) { continue }
        $gwId   = Get-Prop $gw "id" ""
        $gwName = Get-Prop $gw "name" ""
        $gwLoc  = Get-Prop $gw "location" ""
        $scale  = [int](Get-Prop $gw "autoScaleConfiguration.bounds.min" 1)

        [void]$hubResources.Add([ordered]@{
            id = $gwId; name = $gwName; type = "Microsoft.Network/expressRouteGateways"
            subType = "ExpressRoute"; location = $gwLoc
            tags = @{ "x-aed-solution" = "core-networking" }
            metadata = @{ scaleUnits = $scale }
        })

        # ER Gateway Connections → ER Circuits
        $erConns = Invoke-WithRetry "List ER GW connections" @("network", "express-route", "gateway", "connection", "list", "--gateway-name", $gwName, "--subscription", $subId, "--resource-group", $rg) -AllowFailure
        if ($null -eq $erConns) { $erConns = @() }
        if ($erConns -is [PSCustomObject] -and $erConns.PSObject.Properties.Name -contains "value") { $erConns = $erConns.value }
        if ($erConns -isnot [array]) { $erConns = @($erConns) }

        foreach ($conn in $erConns) {
            $rawPeering = Get-Prop $conn "expressRouteCircuitPeering" ""
            $peeringId = if ($rawPeering -is [string]) { $rawPeering } else { Get-Prop $rawPeering "id" "" }
            if (-not [string]::IsNullOrWhiteSpace($peeringId)) {
                $circuitArmId = $peeringId -replace "/peerings/.*$", ""
                $circuitJson = Invoke-WithRetry "Get ER circuit" @("network", "express-route", "show", "--ids", $circuitArmId) -AllowFailure
                if ($null -ne $circuitJson -and (Get-Prop $circuitJson "name" "")) {
                    $erObj = [ordered]@{
                        id = Get-Prop $circuitJson "id" ""
                        name = Get-Prop $circuitJson "name" ""
                        location = Get-Prop $circuitJson "location" ""
                        serviceProviderName = Get-Prop $circuitJson "serviceProviderProperties.serviceProviderName" "Unknown"
                        peeringLocation = Get-Prop $circuitJson "serviceProviderProperties.peeringLocation" "Unknown"
                        bandwidthInMbps = [int](Get-Prop $circuitJson "serviceProviderProperties.bandwidthInMbps" 0)
                        skuTier = Get-Prop $circuitJson "sku.tier" "Standard"
                        skuFamily = Get-Prop $circuitJson "sku.family" "MeteredData"
                        circuitProvisioningState = Get-Prop $circuitJson "circuitProvisioningState" "Unknown"
                        serviceProviderProvisioningState = Get-Prop $circuitJson "serviceProviderProvisioningState" "Unknown"
                    }
                    $rawPeerings = @(Get-Prop $circuitJson "peerings" @())
                    if ($rawPeerings.Count -gt 0) {
                        $erObj["peerings"] = @($rawPeerings | ForEach-Object {
                            $pObj = [ordered]@{ peeringType = Get-Prop $_ "peeringType" ""; state = Get-Prop $_ "state" "" }
                            $vlan = Get-Prop $_ "vlanId" $null; if ($null -ne $vlan) { $pObj["vlanId"] = [int]$vlan }
                            $pp = Get-Prop $_ "primaryPeerAddressPrefix" ""; if ($pp) { $pObj["primaryPeerAddressPrefix"] = $pp }
                            $sp2 = Get-Prop $_ "secondaryPeerAddressPrefix" ""; if ($sp2) { $pObj["secondaryPeerAddressPrefix"] = $sp2 }
                            $asn = Get-Prop $_ "peerASN" $null; if ($null -ne $asn) { $pObj["peerASN"] = [int]$asn }
                            $advPfx = @(Get-Prop $_ "microsoftPeeringConfig.advertisedPublicPrefixes" @())
                            if ($advPfx.Count -gt 0) { $pObj["advertisedPublicPrefixes"] = $advPfx }
                            $advState = Get-Prop $_ "microsoftPeeringConfig.advertisedPublicPrefixesState" ""
                            if ($advState) { $pObj["advertisedPublicPrefixesState"] = $advState }
                            $pObj
                        })
                    }
                    [void]$ErCircuits.Add($erObj)
                }
            }
        }
    }

    # ── 2. S2S VPN Gateways ──
    Write-LogSubstep "Checking S2S VPN gateways..."
    $vpnGwList = Invoke-WithRetry "List vHub VPN GWs" @("network", "vpn-gateway", "list", "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -eq $vpnGwList) { $vpnGwList = @() }
    if ($vpnGwList -is [PSCustomObject] -and $vpnGwList.PSObject.Properties.Name -contains "value") { $vpnGwList = $vpnGwList.value }
    if ($vpnGwList -isnot [array]) { $vpnGwList = @($vpnGwList) }

    foreach ($gw in $vpnGwList) {
        # Skip gateways that belong to a different vHub in the same RG
        $gwVHubId = Get-Prop $gw "virtualHub.id" ""
        if (-not [string]::IsNullOrWhiteSpace($gwVHubId) -and $gwVHubId -ine $VHubId) { continue }
        $gwId   = Get-Prop $gw "id" ""
        $gwName = Get-Prop $gw "name" ""
        $gwLoc  = Get-Prop $gw "location" ""
        $gwScale = [int](Get-Prop $gw "vpnGatewayScaleUnit" 1)

        $vpnConns = Invoke-WithRetry "List VPN GW connections" @("network", "vpn-gateway", "connection", "list", "--gateway-name", $gwName, "--subscription", $subId, "--resource-group", $rg) -AllowFailure
        if ($null -eq $vpnConns) { $vpnConns = @() }
        if ($vpnConns -is [PSCustomObject] -and $vpnConns.PSObject.Properties.Name -contains "value") { $vpnConns = $vpnConns.value }
        if ($vpnConns -isnot [array]) { $vpnConns = @($vpnConns) }
        $s2sConnCount = $vpnConns.Count
        $s2sSiteNames = @($vpnConns | ForEach-Object { Get-Prop $_ "name" "" })

        if ($s2sConnCount -gt 0) {
            Write-LogFound "$s2sConnCount S2S VPN connection(s)"
            foreach ($vc in $vpnConns) {
                $linkConns = @(Get-Prop $vc "vpnLinkConnections" @())
                foreach ($lc in $linkConns) {
                    $siteLinkId = Get-Prop $lc "vpnSiteLink.id" ""
                    if ([string]::IsNullOrWhiteSpace($siteLinkId)) { continue }
                    $vpnSiteId = $siteLinkId -replace "/vpnSiteLinks/.*$", ""
                    $siteJson = Invoke-WithRetry "Get VPN site" @("network", "vpn-site", "show", "--ids", $vpnSiteId) -AllowFailure
                    if ($null -ne $siteJson -and (Get-Prop $siteJson "name" "")) {
                        $siteLinks = @(Get-Prop $siteJson "vpnSiteLinks" @())
                        [void]$Lngs.Add([ordered]@{
                            id = Get-Prop $siteJson "id" ""
                            name = Get-Prop $siteJson "name" ""
                            location = Get-Prop $siteJson "location" ""
                            gatewayIpAddress = if (Get-Prop $siteJson "ipAddress" "") { Get-Prop $siteJson "ipAddress" "" }
                                               elseif ($siteLinks.Count -gt 0) { Get-Prop $siteLinks[0] "ipAddress" "" }
                                               else { "" }
                            localAddressSpace = @(Get-Prop $siteJson "addressSpace.addressPrefixes" @())
                            deviceVendor = Get-Prop $siteJson "deviceProperties.deviceVendor" ""
                            deviceModel = Get-Prop $siteJson "deviceProperties.deviceModel" ""
                            linkSpeedInMbps = [int](Get-Prop $siteJson "deviceProperties.linkSpeedInMbps" 0)
                        })
                    }
                }
            }
        }

        [void]$hubResources.Add([ordered]@{
            id = $gwId; name = $gwName; type = "Microsoft.Network/vpnGateways"
            subType = "Vpn"; location = $gwLoc
            tags = @{ "x-aed-solution" = "core-networking" }
            metadata = @{ scaleUnits = $gwScale; s2sConnectionCount = $s2sConnCount; connectedSites = $s2sSiteNames }
        })
    }

    # ── 3. P2S VPN Gateways ──
    Write-LogSubstep "Checking P2S VPN gateways..."
    $p2sGwList = Invoke-WithRetry "List P2S VPN GWs" @("network", "p2s-vpn-gateway", "list", "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -eq $p2sGwList) { $p2sGwList = @() }
    if ($p2sGwList -is [PSCustomObject] -and $p2sGwList.PSObject.Properties.Name -contains "value") { $p2sGwList = $p2sGwList.value }
    if ($p2sGwList -isnot [array]) { $p2sGwList = @($p2sGwList) }

    foreach ($gw in $p2sGwList) {
        # Skip gateways that belong to a different vHub in the same RG
        $gwVHubId = Get-Prop $gw "virtualHub.id" ""
        if (-not [string]::IsNullOrWhiteSpace($gwVHubId) -and $gwVHubId -ine $VHubId) { continue }
        $configId = Get-Prop $gw "vpnServerConfiguration.id" ""
        $configName = if (-not [string]::IsNullOrWhiteSpace($configId)) { Get-ArmBasename $configId } else { "" }
        [void]$hubResources.Add([ordered]@{
            id = Get-Prop $gw "id" ""; name = Get-Prop $gw "name" ""
            type = "Microsoft.Network/p2sVpnGateways"; subType = "P2S"
            location = Get-Prop $gw "location" ""
            tags = @{ "x-aed-solution" = "core-networking" }
            metadata = @{
                scaleUnits = [int](Get-Prop $gw "vpnGatewayScaleUnit" 1)
                vpnServerConfig = $configName
                clientAddressPool = @(Get-Prop $gw "vpnClientAddressPool.addressPrefixes" @())
            }
        })
    }

    # ── 4. Azure Firewall ──
    Write-LogSubstep "Checking Azure Firewall..."
    $fwId = Get-Prop $vhubJson "azureFirewall.id" ""
    if (-not [string]::IsNullOrWhiteSpace($fwId)) {
        $fwJson = Invoke-WithRetry "Get vHub Firewall" @("network", "firewall", "show", "--ids", $fwId) -AllowFailure
        if ($null -eq $fwJson) { $fwJson = [PSCustomObject]@{} }
        [void]$hubResources.Add([ordered]@{
            id = $fwId; name = Get-Prop $fwJson "name" (Get-ArmBasename $fwId)
            type = "Microsoft.Network/azureFirewalls"; subType = "vHub"
            location = Get-Prop $fwJson "location" ""
            tags = @{ "x-aed-solution" = "core-networking" }
            metadata = @{
                sku = Get-Prop $fwJson "sku.name" "AZFW_Hub"
                tier = Get-Prop $fwJson "sku.tier" "Standard"
                firewallPolicyId = Get-Prop $fwJson "firewallPolicy.id" ""
            }
        })
    }

    # ── 5. BGP Connections (NVAs) ──
    Write-LogSubstep "Checking BGP connections (NVAs)..."
    $bgpConns = Invoke-WithRetry "List BGP connections" @("network", "vhub", "bgpconnection", "list", "--vhub-name", $vhubName, "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -eq $bgpConns) { $bgpConns = @() }; if ($bgpConns -isnot [array]) { $bgpConns = @($bgpConns) }

    foreach ($bgp in $bgpConns) {
        [void]$hubResources.Add([ordered]@{
            id = Get-Prop $bgp "id" ""; name = Get-Prop $bgp "name" ""
            type = "Microsoft.Network/virtualHubs/bgpConnections"; subType = "NVA-BGP"; location = ""
            tags = @{ "x-aed-solution" = "core-networking" }
            metadata = @{
                peerIp = Get-Prop $bgp "peerIp" ""
                peerAsn = [int](Get-Prop $bgp "peerAsn" 0)
                connectionState = Get-Prop $bgp "connectionState" "Unknown"
            }
        })
    }

    # ── 6. Routing Intent ──
    Write-LogSubstep "Checking routing intent..."
    $routingIntent = $null
    $riList = Invoke-WithRetry "List routing intents" @("network", "vhub", "routing-intent", "list", "--vhub-name", $vhubName, "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -ne $riList) {
        if ($riList -isnot [array]) { $riList = @($riList) }
        if ($riList.Count -gt 0) {
            $routingIntent = @($riList | ForEach-Object {
                [ordered]@{
                    name = Get-Prop $_ "name" ""
                    provisioningState = Get-Prop $_ "provisioningState" ""
                    routingPolicies = @((Get-Prop $_ "routingPolicies" @()) | ForEach-Object {
                        [ordered]@{ name = Get-Prop $_ "name" ""; destinations = @(Get-Prop $_ "destinations" @()); nextHop = Get-Prop $_ "nextHop" "" }
                    })
                }
            })
        }
    }

    # ── 7. Route Tables ──
    Write-LogSubstep "Checking route tables..."
    $routeTables = @()
    $rtList = Invoke-WithRetry "List hub route tables" @("network", "vhub", "route-table", "list", "--vhub-name", $vhubName, "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -ne $rtList) {
        if ($rtList -isnot [array]) { $rtList = @($rtList) }
        $routeTables = @($rtList | ForEach-Object {
            [ordered]@{
                id = Get-Prop $_ "id" ""; name = Get-Prop $_ "name" ""
                provisioningState = Get-Prop $_ "provisioningState" ""
                labels = @(Get-Prop $_ "labels" @())
                routes = @((Get-Prop $_ "routes" @()) | ForEach-Object {
                    [ordered]@{ name = Get-Prop $_ "name" ""; destinationType = Get-Prop $_ "destinationType" ""
                                destinations = @(Get-Prop $_ "destinations" @()); nextHopType = Get-Prop $_ "nextHopType" ""; nextHop = Get-Prop $_ "nextHop" "" }
                })
            }
        })
    }

    # ── Build pseudo-subnet ──
    $subnetsArr = @()
    if ($hubResources.Count -gt 0) {
        $subnetsArr = @([ordered]@{ id = "hub-resources"; name = "Hub Resources"; addressPrefix = $addressPrefix; resources = @($hubResources) })
    }

    # ── 8. Hub VNet Connections (spoke peerings) ──
    Write-LogSubstep "Checking spoke connections..."
    $peerings = [System.Collections.ArrayList]::new()
    $hubConns = Invoke-WithRetry "List vHub connections" @("network", "vhub", "connection", "list", "--vhub-name", $vhubName, "--subscription", $subId, "--resource-group", $rg) -AllowFailure
    if ($null -eq $hubConns) { $hubConns = @() }; if ($hubConns -isnot [array]) { $hubConns = @($hubConns) }
    Write-LogFound "$($hubConns.Count) spoke connection(s) found"

    foreach ($conn in $hubConns) {
        $remoteVnetId = Get-Prop $conn "remoteVirtualNetwork.id" ""
        if ([string]::IsNullOrWhiteSpace($remoteVnetId)) { continue }

        $routingCfg = Get-Prop $conn "routingConfiguration" @{}
        $assocRt = Get-ArmBasename (Get-Prop $routingCfg "associatedRouteTable.id" "")
        $propLabels = @(Get-Prop $routingCfg "propagatedRouteTables.labels" @())
        $staticRoutes = @((Get-Prop $routingCfg "vnetRoutes.staticRoutes" @()) | ForEach-Object {
            [ordered]@{ name = Get-Prop $_ "name" ""; addressPrefixes = @(Get-Prop $_ "addressPrefixes" @()); nextHopIpAddress = Get-Prop $_ "nextHopIpAddress" "" }
        })

        [void]$peerings.Add([ordered]@{
            name = Get-Prop $conn "name" ""; remoteVnetId = $remoteVnetId
            state = Get-Prop $conn "provisioningState" "Unknown"
            allowForwardedTraffic = [bool](Get-Prop $conn "allowHubToRemoteVnetTransit" $false)
            allowGatewayTransit = [bool](Get-Prop $conn "allowRemoteVnetToUseHubVnetGateways" $false)
            useRemoteGateways = $false
            _hubConnectionMetadata = [ordered]@{
                enableInternetSecurity = [bool](Get-Prop $conn "enableInternetSecurity" $false)
                associatedRouteTable = $assocRt; propagatedLabels = $propLabels; staticRoutes = $staticRoutes
            }
        })
    }

    # ── 9. Inter-hub peerings ──
    $interhubPeers = @()
    if (-not [string]::IsNullOrWhiteSpace($vwanId)) {
        Write-LogSubstep "Checking vWAN inter-hub links..."
        $vwanJson = Invoke-WithRetry "Get vWAN" @("network", "vwan", "show", "--ids", $vwanId) -AllowFailure
        if ($null -ne $vwanJson) {
            $siblingHubs = @(Get-Prop $vwanJson "virtualHubs" @())
            foreach ($hubRef in $siblingHubs) {
                $siblingId = Get-Prop $hubRef "id" ""
                if ([string]::IsNullOrWhiteSpace($siblingId) -or $siblingId.ToLower() -eq $VHubId.ToLower()) { continue }
                $siblingName = Get-ArmBasename $siblingId
                Write-LogFound "Sibling hub: $siblingName"
                $interhubPeers += [ordered]@{ hubId = $siblingId; hubName = $siblingName }
                [void]$peerings.Add([ordered]@{
                    name = "interhub-$siblingName"; remoteVnetId = $siblingId; state = "Connected"
                    allowForwardedTraffic = $true; allowGatewayTransit = $true; useRemoteGateways = $false
                    _isInterHubPeering = $true
                })
                Write-LogFound "Linked → $siblingName"
            }
        }
    }

    $result = [ordered]@{
        id = $OriginalVNetId; name = $vhubName; addressSpace = $addressSpace
        location = $location; resourceGroup = $rg
        subnets = $subnetsArr; peerings = @($peerings)
        _isVirtualHub = $true; _vhubResourceId = $VHubId
        _hubConfig = [ordered]@{
            sku = $hubSku; routingPreference = $hubRoutingPref; routingState = $routingState
            allowBranchToBranchTraffic = $allowB2b; virtualRouterAsn = $hubAsn; virtualRouterIps = $hubRouterIps
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($vwanId)) { $result["_vwanId"] = $vwanId }
    $vhubTags = Get-Prop $vhubJson "tags" $null
    if ($null -ne $vhubTags) {
        $tagHash = @{}
        $vhubTags.PSObject.Properties | ForEach-Object { $tagHash[$_.Name] = $_.Value }
        if ($tagHash.Count -gt 0) { $result["tags"] = $tagHash }
    }
    if ($null -ne $routingIntent) { $result._hubConfig["routingIntent"] = $routingIntent }
    if ($routeTables.Count -gt 0) { $result._hubConfig["routeTables"] = $routeTables }
    if ($interhubPeers.Count -gt 0) { $result._hubConfig["interhubPeers"] = $interhubPeers }

    return $result
}

# ── On-Premises synthesis ────────────────────────────────────────────────────
function Build-OnPremises {
    <#
    .SYNOPSIS
    Synthesise on-premises site entries from ER circuit private peerings.
    Each AzurePrivatePeering with a peerASN produces one on-prem site keyed
    by (circuitId, peerASN). Falls back to one site per circuit when no ASN.
    #>
    param(
        [array]$ErCircuits,
        [array]$Lngs
    )
    $sites = [System.Collections.ArrayList]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($circuit in $ErCircuits) {
        $circuitId = Get-Prop $circuit "id" ""
        $provider = Get-Prop $circuit "serviceProviderName" ""
        $peeringLoc = Get-Prop $circuit "peeringLocation" ""
        if ([string]::IsNullOrWhiteSpace($peeringLoc)) { $peeringLoc = Get-Prop $circuit "location" "" }
        $peerings = @(if ($circuit.peerings) { $circuit.peerings } else { @() })

        $privatePeerings = @($peerings | Where-Object {
            $pt = Get-Prop $_ "peeringType" ""
            $asn = $_.peerASN
            ($pt -ieq "AzurePrivatePeering") -and ($null -ne $asn)
        })

        if ($privatePeerings.Count -gt 0) {
            foreach ($p in $privatePeerings) {
                $asn = $p.peerASN
                $key = "$($circuitId)|asn-$asn"
                if ($seen.Contains($key)) { continue }
                [void]$seen.Add($key)

                $locSlug = if ([string]::IsNullOrWhiteSpace($peeringLoc)) { "unknown" } else { $peeringLoc.ToLower().Replace(" ", "-") }
                $siteId = "onprem-asn-$asn-$locSlug"
                $name = "ASN $asn"
                if (-not [string]::IsNullOrWhiteSpace($peeringLoc)) { $name += " `u{2013} $peeringLoc" }
                if (-not [string]::IsNullOrWhiteSpace($provider) -and $provider -ne "Unknown") { $name += " ($provider)" }

                $site = [ordered]@{
                    id                  = $siteId
                    name                = $name
                    location            = $peeringLoc
                    circuitId           = $circuitId
                    peerASN             = $asn
                }
                if (-not [string]::IsNullOrWhiteSpace($provider) -and $provider -ne "Unknown") {
                    $site["serviceProviderName"] = $provider
                }
                [void]$sites.Add($site)
            }
        } else {
            # Fallback: no ASN — one site per circuit
            $key = $circuitId
            if ($seen.Contains($key)) { continue }
            [void]$seen.Add($key)

            $locSlug = if ([string]::IsNullOrWhiteSpace($peeringLoc)) { "unknown" } else { $peeringLoc.ToLower().Replace(" ", "-") }
            $cName = Get-Prop $circuit "name" "unknown"
            $siteId = "onprem-circuit-$locSlug-$cName"
            $name = if ([string]::IsNullOrWhiteSpace($peeringLoc)) { $cName } else { $peeringLoc }
            if (-not [string]::IsNullOrWhiteSpace($provider) -and $provider -ne "Unknown") { $name += " ($provider)" }

            $site = [ordered]@{
                id                  = $siteId
                name                = $name
                location            = $peeringLoc
                circuitId           = $circuitId
            }
            if (-not [string]::IsNullOrWhiteSpace($provider) -and $provider -ne "Unknown") {
                $site["serviceProviderName"] = $provider
            }
            [void]$sites.Add($site)
        }
    }

    return @($sites)
}

# ── External connectivity ────────────────────────────────────────────────────
function Discover-ExternalConnectivity {
    param(
        [string]$VNetId,
        [System.Collections.ArrayList]$ErCircuits,
        [System.Collections.ArrayList]$LngsList,
        [System.Collections.ArrayList]$GwConnections
    )
    $subId = Get-SubscriptionFromId $VNetId
    $rgName = Get-ResourceGroupFromId $VNetId
    $vnetName = Get-ArmBasename $VNetId

    # ExpressRoute circuits
    $erJson = Invoke-WithRetry "List ER circuits" @("network", "express-route", "list", "--subscription", $subId, "--resource-group", $rgName) -AllowFailure -ErrorScope "vnet/$vnetName/er-circuits"
    if ($null -ne $erJson) {
        if ($erJson -isnot [array]) { $erJson = @($erJson) }
        foreach ($circuit in $erJson) {
            $erObj = [ordered]@{
                id = Get-Prop $circuit "id" ""; name = Get-Prop $circuit "name" ""
                location = Get-Prop $circuit "location" ""
                serviceProviderName = Get-Prop $circuit "serviceProviderProperties.serviceProviderName" "Unknown"
                peeringLocation = Get-Prop $circuit "serviceProviderProperties.peeringLocation" "Unknown"
                bandwidthInMbps = [int](Get-Prop $circuit "serviceProviderProperties.bandwidthInMbps" 0)
                skuTier = Get-Prop $circuit "sku.tier" "Standard"
                skuFamily = Get-Prop $circuit "sku.family" "MeteredData"
                circuitProvisioningState = Get-Prop $circuit "circuitProvisioningState" "Unknown"
                serviceProviderProvisioningState = Get-Prop $circuit "serviceProviderProvisioningState" "Unknown"
            }
            $rawPeerings = @(Get-Prop $circuit "peerings" @())
            if ($rawPeerings.Count -gt 0) {
                $erObj["peerings"] = @($rawPeerings | ForEach-Object {
                    $pObj = [ordered]@{ peeringType = Get-Prop $_ "peeringType" ""; state = Get-Prop $_ "state" "" }
                    $vlan = Get-Prop $_ "vlanId" $null; if ($null -ne $vlan) { $pObj["vlanId"] = [int]$vlan }
                    $pp = Get-Prop $_ "primaryPeerAddressPrefix" ""; if ($pp) { $pObj["primaryPeerAddressPrefix"] = $pp }
                    $sp2 = Get-Prop $_ "secondaryPeerAddressPrefix" ""; if ($sp2) { $pObj["secondaryPeerAddressPrefix"] = $sp2 }
                    $asn = Get-Prop $_ "peerASN" $null; if ($null -ne $asn) { $pObj["peerASN"] = [int]$asn }
                    $advPfx = @(Get-Prop $_ "microsoftPeeringConfig.advertisedPublicPrefixes" @())
                    if ($advPfx.Count -gt 0) { $pObj["advertisedPublicPrefixes"] = $advPfx }
                    $advState = Get-Prop $_ "microsoftPeeringConfig.advertisedPublicPrefixesState" ""
                    if ($advState) { $pObj["advertisedPublicPrefixesState"] = $advState }
                    $pObj
                })
            }
            [void]$ErCircuits.Add($erObj)
        }
    }

    # Local Network Gateways
    $lngJson = Invoke-WithRetry "List LNGs" @("network", "local-gateway", "list", "--subscription", $subId, "--resource-group", $rgName) -AllowFailure -ErrorScope "vnet/$vnetName/lngs"
    if ($null -ne $lngJson) {
        if ($lngJson -isnot [array]) { $lngJson = @($lngJson) }
        foreach ($lng in $lngJson) {
            [void]$LngsList.Add([ordered]@{
                id = Get-Prop $lng "id" ""; name = Get-Prop $lng "name" ""
                location = Get-Prop $lng "location" ""
                gatewayIpAddress = Get-Prop $lng "gatewayIpAddress" "Unknown"
                localAddressSpace = @(Get-Prop $lng "localNetworkAddressSpace.addressPrefixes" @())
            })
        }
    }

    # ── VPN/ER Gateway Connections (GH #35 fix) ──
    # Primary: az CLI list in the VNet's RG
    $connJson = Invoke-WithRetry "List GW connections" @("network", "vpn-connection", "list", "--subscription", $subId, "--resource-group", $rgName) -AllowFailure -ErrorScope "vnet/$vnetName/gw-connections"

    # Fallback: Resource Graph query if CLI returned nothing
    if ($null -eq $connJson -or ($connJson -is [array] -and $connJson.Count -eq 0)) {
        Write-LogDetail "CLI returned no connections for $rgName — trying Resource Graph fallback…"
        $graphQuery = @"
Resources
| where type =~ 'microsoft.network/connections'
| where resourceGroup =~ '$rgName'
    or properties.virtualNetworkGateway1.id contains '$VNetId'
| project id, name, type, resourceGroup,
    connectionType = tostring(properties.connectionType),
    gatewayId = tostring(properties.virtualNetworkGateway1.id),
    circuitId = tostring(properties.peer.id),
    localNetworkGatewayId = tostring(properties.localNetworkGateway2.id),
    connectionStatus = tostring(properties.connectionStatus),
    routingWeight = toint(properties.routingWeight)
"@
        $graphConns = Invoke-GraphQueryPaginated "Query connections for $vnetName" $graphQuery $subId -ErrorScope "vnet/$vnetName/gw-connections-graph"
        foreach ($c in $graphConns) {
            [void]$GwConnections.Add([ordered]@{
                id = Get-Prop $c "id" ""; name = Get-Prop $c "name" ""
                connectionType = Get-Prop $c "connectionType" "Unknown"
                gatewayId = Get-Prop $c "gatewayId" ""
                circuitId = Get-Prop $c "circuitId" ""
                localNetworkGatewayId = Get-Prop $c "localNetworkGatewayId" ""
                connectionStatus = Get-Prop $c "connectionStatus" "Unknown"
                routingWeight = [int](Get-Prop $c "routingWeight" 0)
            })
        }
        if ($graphConns.Count -gt 0) {
            Write-LogFound "$($graphConns.Count) connection(s) found via Resource Graph fallback"
        }
    } else {
        if ($connJson -isnot [array]) { $connJson = @($connJson) }
        foreach ($conn in $connJson) {
            [void]$GwConnections.Add([ordered]@{
                id = Get-Prop $conn "id" ""; name = Get-Prop $conn "name" ""
                connectionType = Get-Prop $conn "connectionType" "Unknown"
                gatewayId = Get-Prop $conn "virtualNetworkGateway1.id" ""
                circuitId = Get-Prop $conn "peer.id" ""
                localNetworkGatewayId = Get-Prop $conn "localNetworkGateway2.id" ""
                connectionStatus = Get-Prop $conn "connectionStatus" "Unknown"
                routingWeight = [int](Get-Prop $conn "routingWeight" 0)
            })
        }
        Write-LogFound "$($connJson.Count) connection(s) found"
    }
}

# ── Connected-component builder (union-find) ────────────────────────────────
function Build-ConnectedComponents {
    param([string[]]$Ids)
    $parent = @{}; $idMap = @{}
    foreach ($vid in $Ids) {
        $lower = $vid.ToLower()
        $parent[$lower] = $lower
        $idMap[$lower] = $vid
    }

    function Find-Root { param([string]$x)
        while ($parent[$x] -ne $x) { $parent[$x] = $parent[$parent[$x]]; $x = $parent[$x] }
        return $x
    }
    function Union-Nodes { param([string]$a, [string]$b)
        $ra = Find-Root $a; $rb = Find-Root $b
        if ($ra -ne $rb) { $parent[$ra] = $rb }
    }

    foreach ($vid in $Ids) {
        $vidLower = $vid.ToLower()
        if (Test-VHubResourceId $vid) {
            Write-LogInfo "  Scanning hub connections for $(Get-ArmBasename $vid)…"
            $vhubName = Get-ArmBasename $vid; $vhubSub = Get-SubscriptionFromId $vid; $vhubRg = Get-ResourceGroupFromId $vid
            $hubConnIds = Invoke-WithRetry "List vHub connections for $vhubName" @(
                "network", "vhub", "connection", "list",
                "--vhub-name", $vhubName, "--subscription", $vhubSub, "--resource-group", $vhubRg,
                "--query", "[].remoteVirtualNetwork.id"
            ) -AllowFailure
            if ($null -eq $hubConnIds) { $hubConnIds = @() }; if ($hubConnIds -isnot [array]) { $hubConnIds = @($hubConnIds) }
            foreach ($peer in $hubConnIds) {
                if ($peer -is [string]) {
                    $peerLower = $peer.ToLower()
                    if ($parent.ContainsKey($peerLower)) { Union-Nodes $vidLower $peerLower }
                }
            }
        } else {
            Write-LogInfo "  Scanning peerings for $(Get-ArmBasename $vid)…"
            $peerIds = Invoke-WithRetry "Peek VNet peerings" @(
                "network", "vnet", "show", "--ids", $vid,
                "--query", "virtualNetworkPeerings[].remoteVirtualNetwork.id"
            ) -AllowFailure
            if ($null -eq $peerIds) { $peerIds = @() }; if ($peerIds -isnot [array]) { $peerIds = @($peerIds) }
            foreach ($peer in $peerIds) {
                if ($peer -is [string]) {
                    $peerLower = $peer.ToLower()
                    if ($parent.ContainsKey($peerLower)) { Union-Nodes $vidLower $peerLower }
                }
            }
        }
    }

    $groups = @{}
    foreach ($vid in $Ids) {
        $root = Find-Root $vid.ToLower()
        if (-not $groups.ContainsKey($root)) { $groups[$root] = @() }
        $groups[$root] += $vid
    }
    return @($groups.Values)
}

# ── Merge Engine (T213/T216) ────────────────────────────────────────────────

# OnPremises user-editable fields that should survive re-discovery
$script:OnPremUserFields = @("name", "description", "ipRanges", "notes")

function Merge-UserEdits {
    <#
    .SYNOPSIS
        Apply user-authored content from baseline onto target, matched by ARM resource ID.
    .DESCRIPTION
        Merge rules:
          - _layout: copy from baseline to matching resource
          - OnPremises name, description, ipRanges, notes: copy from baseline
          - x-aed-* tags: overlay onto target (baseline wins on conflict)
          - Non-x-aed-* tags: always from target
          - Orphaned baseline resources: drop silently, log warning
          - New target resources: keep as-is
          - OnPremises entries in baseline with no match in target: preserve (append)
          - topologyVersion: increment from baseline
    #>
    param(
        [hashtable]$BaselineData,
        [hashtable]$TargetData
    )

    $summary = @{
        applied_layouts   = 0
        merged_edits      = 0
        merged_tags       = 0
        preserved_onprem  = 0
        orphaned          = 0
        new_resources     = 0
    }

    # Build baseline indexes (keyed by lowercase ARM ID)
    $baselineById = @{}
    foreach ($collection in @("vnets", "expressRouteCircuits")) {
        foreach ($item in @($BaselineData[$collection])) {
            if ($null -ne $item -and $item.id) {
                $baselineById[$item.id.ToLower()] = $item
            }
        }
    }

    $baselineOnpremById = @{}
    foreach ($site in @($BaselineData["onPremises"])) {
        if ($null -ne $site -and $site.id) {
            $baselineOnpremById[$site.id.ToLower()] = $site
        }
    }

    # Build target ID set
    $targetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($collection in @("vnets", "expressRouteCircuits")) {
        foreach ($item in @($TargetData[$collection])) {
            if ($null -ne $item -and $item.id) { [void]$targetIds.Add($item.id.ToLower()) }
        }
    }
    foreach ($site in @($TargetData["onPremises"])) {
        if ($null -ne $site -and $site.id) { [void]$targetIds.Add($site.id.ToLower()) }
    }

    # Apply layouts and x-aed-* tags to VNets and ER circuits
    foreach ($collection in @("vnets", "expressRouteCircuits")) {
        foreach ($item in @($TargetData[$collection])) {
            if ($null -eq $item -or -not $item.id) { continue }
            $key = $item.id.ToLower()
            $baselineItem = $baselineById[$key]
            if ($null -eq $baselineItem) {
                $summary.new_resources++
                continue
            }

            # _layout
            if ($baselineItem.ContainsKey("_layout")) {
                $item["_layout"] = $baselineItem["_layout"]
                $summary.applied_layouts++
            }

            # x-aed-* tags: overlay from baseline
            $baselineTags = if ($baselineItem.ContainsKey("tags")) { $baselineItem["tags"] } else { @{} }
            $aedTags = @{}
            foreach ($k in @($baselineTags.Keys)) {
                if ($k.StartsWith("x-aed-")) { $aedTags[$k] = $baselineTags[$k] }
            }
            if ($aedTags.Count -gt 0) {
                if (-not $item.ContainsKey("tags")) { $item["tags"] = @{} }
                foreach ($k in $aedTags.Keys) { $item["tags"][$k] = $aedTags[$k] }
                $summary.merged_tags++
            }
        }
    }

    # Apply layouts, user edits, and x-aed-* tags to onPremises
    $matchedOnpremIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($site in @($TargetData["onPremises"])) {
        if ($null -eq $site -or -not $site.id) { continue }
        $key = $site.id.ToLower()
        $baselineSite = $baselineOnpremById[$key]
        if ($null -eq $baselineSite) {
            $summary.new_resources++
            continue
        }
        [void]$matchedOnpremIds.Add($key)

        # _layout
        if ($baselineSite.ContainsKey("_layout")) {
            $site["_layout"] = $baselineSite["_layout"]
            $summary.applied_layouts++
        }

        # User-editable fields
        $edited = $false
        foreach ($field in $script:OnPremUserFields) {
            if ($baselineSite.ContainsKey($field) -and $baselineSite[$field]) {
                $site[$field] = $baselineSite[$field]
                $edited = $true
            }
        }
        if ($edited) { $summary.merged_edits++ }
    }

    # Preserve user-created onPremises from baseline not in target
    foreach ($key in $baselineOnpremById.Keys) {
        if (-not $matchedOnpremIds.Contains($key) -and -not $targetIds.Contains($key)) {
            if (-not $TargetData.ContainsKey("onPremises")) { $TargetData["onPremises"] = @() }
            $TargetData["onPremises"] += $baselineOnpremById[$key]
            $summary.preserved_onprem++
        }
    }

    # Count orphaned
    foreach ($key in $baselineById.Keys) {
        if (-not $targetIds.Contains($key)) {
            $summary.orphaned++
            Write-LogWarn "Orphaned baseline resource (removed from Azure): $($baselineById[$key].name ?? $key)"
        }
    }

    # topologyVersion: increment from baseline
    $prev = $BaselineData["topologyVersion"]
    if ($null -ne $prev -and $prev -is [int] -and $prev -ge 1) {
        $TargetData["topologyVersion"] = $prev + 1
    }

    return $summary
}

function Union-Resources {
    <#
    .SYNOPSIS
        Add resources from overlay that don't already exist in base (by ARM ID).
    #>
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )

    foreach ($collection in @("vnets", "expressRouteCircuits")) {
        $existingIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($Base[$collection])) {
            if ($null -ne $item -and $item.id) { [void]$existingIds.Add($item.id.ToLower()) }
        }
        foreach ($item in @($Overlay[$collection])) {
            if ($null -ne $item -and $item.id -and -not $existingIds.Contains($item.id.ToLower())) {
                if (-not $Base.ContainsKey($collection)) { $Base[$collection] = @() }
                $Base[$collection] += $item
                [void]$existingIds.Add($item.id.ToLower())
            }
        }
    }

    # connections — deduplicate by sourceVNet+targetVNet
    $existingConnKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in @($Base["connections"])) {
        if ($null -eq $c) { continue }
        $ck = "$($c.sourceVNet.id)|$($c.targetVNet.id)".ToLower()
        [void]$existingConnKeys.Add($ck)
    }
    foreach ($c in @($Overlay["connections"])) {
        if ($null -eq $c) { continue }
        $ck = "$($c.sourceVNet.id)|$($c.targetVNet.id)".ToLower()
        if (-not $existingConnKeys.Contains($ck)) {
            if (-not $Base.ContainsKey("connections")) { $Base["connections"] = @() }
            $Base["connections"] += $c
            [void]$existingConnKeys.Add($ck)
        }
    }

    # localNetworkGateways, gatewayConnections, onPremises
    foreach ($collection in @("localNetworkGateways", "gatewayConnections", "onPremises")) {
        $existingIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($Base[$collection])) {
            if ($null -ne $item -and $item.id) { [void]$existingIds.Add($item.id.ToLower()) }
        }
        foreach ($item in @($Overlay[$collection])) {
            if ($null -ne $item -and $item.id -and -not $existingIds.Contains($item.id.ToLower())) {
                if (-not $Base.ContainsKey($collection)) { $Base[$collection] = @() }
                $Base[$collection] += $item
                [void]$existingIds.Add($item.id.ToLower())
            }
        }
    }
}

function Invoke-MergeFiles {
    <#
    .SYNOPSIS
        Merge multiple topology files left-to-right and write result.
    #>
    param(
        [string[]]$FilePaths,
        [string]$OutputPath
    )

    if ($FilePaths.Count -lt 2) {
        Write-LogError "merge requires at least 2 input files"
        exit 1
    }

    # Load base
    Write-LogInfo "Loading base: $($FilePaths[0])"
    $result = Get-Content -Path $FilePaths[0] -Raw | ConvertFrom-Json -AsHashtable

    # Overlay each subsequent file
    for ($i = 1; $i -lt $FilePaths.Count; $i++) {
        $stepNum = $i + 1
        Write-LogInfo "Merging file $stepNum/$($FilePaths.Count): $($FilePaths[$i])"
        $overlay = Get-Content -Path $FilePaths[$i] -Raw | ConvertFrom-Json -AsHashtable

        # Union resources
        Union-Resources -Base $result -Overlay $overlay

        # Apply user edits from overlay
        $summary = Merge-UserEdits -BaselineData $overlay -TargetData $result

        Write-LogInfo "  Step $i`: layouts=$($summary.applied_layouts), edits=$($summary.merged_edits), tags=$($summary.merged_tags), preserved_onprem=$($summary.preserved_onprem), orphaned=$($summary.orphaned), new=$($summary.new_resources)"
    }

    # Write output
    $jsonString = $result | ConvertTo-Json -Depth 30 -Compress:$false
    [System.IO.File]::WriteAllText($OutputPath, "$jsonString`n", [System.Text.Encoding]::UTF8)

    Write-LogInfo "Merged $($FilePaths.Count) files → $OutputPath"
}

# ── Full discovery + emit ────────────────────────────────────────────────────
function Invoke-DiscoverAndEmit {
    param(
        [string]$DiagramTitle,
        [string]$ScopeResourceId,
        [string]$ScopeResourceType,
        [string]$OutputFile,
        [string[]]$SeedIds,
        [string]$SubId,
        [string]$SubName,
        [int]$TopologyVersion = 1,
        [System.Diagnostics.Stopwatch]$StartTimer = $null,
        [hashtable]$BaselineData = $null
    )

    # Resolve to absolute path (relative paths + [System.IO.File]::WriteAllText
    # resolve against [Environment]::CurrentDirectory, which may differ from $PWD on Windows)
    if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile = Join-Path (Get-Location).Path $OutputFile
    }

    $allVnets = [System.Collections.ArrayList]::new()
    $allConnections = [System.Collections.ArrayList]::new()
    $erCircuits = [System.Collections.ArrayList]::new()
    $lngsList = [System.Collections.ArrayList]::new()
    $gwConnections = [System.Collections.ArrayList]::new()

    # BFS
    $queue = [System.Collections.Queue]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($vid in $SeedIds) { $queue.Enqueue($vid); [void]$seen.Add($vid) }

    Write-LogInfo "Starting traversal from $($SeedIds.Count) seed network(s)…"
    $vnetCounter = 0

    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        $remaining = $queue.Count
        $vnetCounter++

        if (Test-VHubResourceId $currentId) {
            Write-LogStep "Processing VNet ${vnetCounter}: $(Get-ArmBasename $currentId) (vWAN Hub)  [$remaining in queue]"
            $vnetObj = Discover-VHub -VHubId $currentId -OriginalVNetId $currentId -ErCircuits $erCircuits -Lngs $lngsList
        }
        elseif (Test-VHubVNetId $currentId) {
            Write-LogStep "Processing VNet ${vnetCounter}: $(Get-ArmBasename $currentId) (vWAN Hub VNet)  [$remaining in queue]"
            $vhubResourceId = Resolve-VHubIdFromVNet $currentId

            if ($null -ne $vhubResourceId -and -not [string]::IsNullOrWhiteSpace($vhubResourceId)) {
                if ($seen.Contains($vhubResourceId)) {
                    Write-LogDetail "Already discovered — skipping duplicate"
                    continue
                }
                $vnetObj = Discover-VHub -VHubId $vhubResourceId -OriginalVNetId $currentId -ErCircuits $erCircuits -Lngs $lngsList
            } else {
                Write-LogAlert @(
                    "ACCESS DENIED — $(Get-ArmBasename $currentId)",
                    "Could not resolve the Virtual Hub behind this managed VNet.",
                    "The hub may be in a subscription you don't have access to.",
                    "A placeholder will be added to the topology."
                )
                $vnetObj = [ordered]@{
                    id = $currentId; name = Get-ArmBasename $currentId; addressSpace = @()
                    location = "unknown"; resourceGroup = "unknown"
                    subnets = @(); peerings = @()
                    _isVirtualHub = $true; _accessDenied = $true
                }
            }
        }
        else {
            Write-LogStep "Processing VNet ${vnetCounter}: $(Get-ArmBasename $currentId)  [$remaining in queue]"
            $vnetObj = Discover-VNet -VNetId $currentId
            Discover-ExternalConnectivity -VNetId $currentId -ErCircuits $erCircuits -LngsList $lngsList -GwConnections $gwConnections
        }

        [void]$allVnets.Add($vnetObj)

        # Mark vHub ARM ID as seen
        $vhubRid = $vnetObj["_vhubResourceId"]
        if (-not [string]::IsNullOrWhiteSpace($vhubRid)) { [void]$seen.Add($vhubRid) }

        # Enqueue unseen peered VNets
        foreach ($p in $vnetObj.peerings) {
            $peerId = $p.remoteVnetId
            if ([string]::IsNullOrWhiteSpace($peerId)) { continue }
            if ($seen.Contains($peerId)) { continue }
            [void]$seen.Add($peerId)
            $queue.Enqueue($peerId)
            if (Test-VHubResourceId $peerId) {
                Write-LogQueue "Linked vWAN Hub: $(Get-ArmBasename $peerId)"
            } else {
                Write-LogQueue "Peered network: $(Get-ArmBasename $peerId)"
            }
        }
    }

    # ── Build connections ──
    Write-Host "" ; Write-Host "$($script:C_GREEN)$($script:C_BOLD)  ● Assembling peering connections…$($script:C_RESET)"
    Write-LogToFile "  ● Assembling peering connections…"
    $connSet = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($vnet in $allVnets) {
        $viId = $vnet.id
        foreach ($p in $vnet.peerings) {
            $pRemote = $p.remoteVnetId
            if ([string]::IsNullOrWhiteSpace($pRemote)) { continue }
            $pair = @($viId.ToLower(), $pRemote.ToLower()) | Sort-Object
            $key = "$($pair[0])|$($pair[1])"
            if ($connSet.Contains($key)) { continue }
            [void]$connSet.Add($key)
            [void]$allConnections.Add([ordered]@{
                sourceId = $viId; targetId = $pRemote
                relationship = "VNet peering"; direction = "undirected"
                metadata = [ordered]@{ peeringName = $p.name; state = $p.state }
            })
        }
    }

    # ── Deduplicate external resources ──
    function Get-UniqueById { param([System.Collections.ArrayList]$Items)
        $seenIds = [System.Collections.Generic.HashSet[string]]::new()
        $result = @()
        foreach ($item in $Items) {
            $iid = $item.id
            if (-not $seenIds.Contains($iid)) { [void]$seenIds.Add($iid); $result += $item }
        }
        return $result
    }
    $erCircuitsArr = @(Get-UniqueById $erCircuits)
    $lngsArr       = @(Get-UniqueById $lngsList)
    $gwConnsArr    = @(Get-UniqueById $gwConnections)

    # ── Validate ER circuit ↔ VNet gateway linkage (T141/T143, GH #35) ──
    if ($erCircuitsArr.Count -gt 0 -and $gwConnsArr.Count -gt 0) {
        $erIdsLower = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $erCircuitsArr) { if ($c.id) { [void]$erIdsLower.Add($c.id) } }
        $erConnCount = 0
        foreach ($gc in $gwConnsArr) {
            $cid = $gc.circuitId
            if (-not [string]::IsNullOrWhiteSpace($cid) -and $erIdsLower.Contains($cid)) { $erConnCount++ }
        }
        if ($erConnCount -gt 0) {
            Write-LogFound "$erConnCount ER circuit(s) linked to VNet gateway(s) via connections"
        } else {
            Write-LogWarn "Found $($erCircuitsArr.Count) ER circuit(s) but no gateway connections reference them — ER ↔ gateway linkage may be incomplete"
        }
    } elseif ($erCircuitsArr.Count -gt 0 -and $gwConnsArr.Count -eq 0) {
        Write-LogWarn "Found $($erCircuitsArr.Count) ER circuit(s) but no gateway connections — ER ↔ gateway linkage missing"
    }

    # ── Enrich VNets with Private DNS Zone links ──
    Write-LogSubstep "Querying Private DNS Zone virtual network links…"
    $dnsZoneQuery = @"
Resources
| where type =~ 'microsoft.network/privatednszones/virtualnetworklinks'
| extend vnetId = tolower(tostring(properties.virtualNetwork.id))
| extend zoneName = tostring(split(id, '/')[8])
| project vnetId, zoneName, registrationEnabled = tobool(properties.registrationEnabled)
"@
    $dnsZoneLinks = @(Invoke-GraphQueryPaginated -Label "Query Private DNS Zone links" -Query $dnsZoneQuery -Subscription $SubId -ErrorScope "private-dns-zone-links")
    Write-LogFound "$($dnsZoneLinks.Count) DNS zone link(s) found"

    # Build lookup: lowercase vnetId → list of zone objects
    $dnsZonesByVnet = @{}
    foreach ($link in $dnsZoneLinks) {
        $vid = (Get-Prop $link "vnetId" "").ToLower()
        if ([string]::IsNullOrWhiteSpace($vid)) { continue }
        $zoneObj = [ordered]@{ name = Get-Prop $link "zoneName" "" }
        if ((Get-Prop $link "registrationEnabled" $false) -eq $true) {
            $zoneObj["registrationEnabled"] = $true
        }
        if (-not $dnsZonesByVnet.ContainsKey($vid)) { $dnsZonesByVnet[$vid] = @() }
        $dnsZonesByVnet[$vid] += $zoneObj
    }

    # Attach to VNet objects
    foreach ($vnet in $allVnets) {
        $zones = $dnsZonesByVnet[$vnet.id.ToLower()]
        if ($zones -and $zones.Count -gt 0) {
            $vnet["privateDnsZones"] = @($zones | Sort-Object { $_.name })
        }
    }

    # ── Assemble topology JSON ──
    $generatedAt = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")

    $topology = [ordered]@{
        schemaVersion    = $script:SchemaVersion
        topologyVersion  = $TopologyVersion
        generatedAt      = $generatedAt
        title            = $DiagramTitle
        generator        = $script:GeneratorName
        scope         = [ordered]@{
            subscriptionId       = $SubId
            subscriptionName     = $SubName
            startingResourceId   = $ScopeResourceId
            startingResourceType = $ScopeResourceType
        }
        vnets         = @($allVnets)
        connections   = @($allConnections)
    }

    if ($erCircuitsArr.Count -gt 0) { $topology["expressRouteCircuits"] = $erCircuitsArr }
    if ($lngsArr.Count -gt 0)       { $topology["localNetworkGateways"] = $lngsArr }
    if ($gwConnsArr.Count -gt 0)    { $topology["gatewayConnections"] = $gwConnsArr }

    # ── Synthesise on-premises sites from ER circuits + LNGs ──
    $onPremisesArr = @(Build-OnPremises -ErCircuits $erCircuitsArr -Lngs $lngsArr)
    if ($onPremisesArr.Count -gt 0) { $topology["onPremises"] = $onPremisesArr }

    if ($script:DiscoveryErrors.Count -gt 0) { $topology["_warnings"] = @($script:DiscoveryErrors) }

    # ── Merge user edits from baseline (T213) ──
    if ($null -ne $BaselineData) {
        Write-LogStep "Merging Baseline User Edits"
        $mergeSummary = Merge-UserEdits -BaselineData $BaselineData -TargetData $topology
        Write-LogInfo "Layouts applied: $($mergeSummary.applied_layouts)"
        Write-LogInfo "OnPremises edits merged: $($mergeSummary.merged_edits)"
        Write-LogInfo "x-aed-* tags merged: $($mergeSummary.merged_tags)"
        if ($mergeSummary.preserved_onprem -gt 0) {
            Write-LogInfo "User-created OnPremises preserved: $($mergeSummary.preserved_onprem)"
        }
        if ($mergeSummary.orphaned -gt 0) {
            Write-LogWarn "Orphaned baseline resources: $($mergeSummary.orphaned)"
        }
        Write-LogInfo "New resources (no baseline match): $($mergeSummary.new_resources)"
    }

    # ── Write output ──
    $jsonString = $topology | ConvertTo-Json -Depth 30 -Compress:$false
    [System.IO.File]::WriteAllText($OutputFile, $jsonString, [System.Text.Encoding]::UTF8)

    $vnetCount = $allVnets.Count
    $connCount = $allConnections.Count
    $erCount   = $erCircuitsArr.Count
    $lngCount  = $lngsArr.Count
    $onPremCount = $onPremisesArr.Count

    Write-LogStep "Results"
    # ── Results table ──
    $rw = 23
    function Write-ResultRow {
        param([string]$Label, [string]$Value)
        Write-Host "$($script:C_BOLD)$($script:C_CYAN)  │$($script:C_RESET) $($script:C_WHITE)$($Label.PadRight(16))$($script:C_RESET) $($script:C_BOLD)$($script:C_CYAN)│$($script:C_RESET) $($Value.PadRight($rw)) $($script:C_BOLD)$($script:C_CYAN)│$($script:C_RESET)"
        Write-LogToFile "  $($Label.PadRight(16)) $Value"
    }
    Write-Host "$($script:C_BOLD)$($script:C_CYAN)  ┌──────────────────┬─────────────────────────┐$($script:C_RESET)"
    Write-ResultRow "Title" $DiagramTitle
    Write-ResultRow "Networks" "$vnetCount"
    Write-ResultRow "Connections" "$connCount"
    if ($erCount -gt 0)  { Write-ResultRow "ER Circuits" "$erCount" }
    if ($lngCount -gt 0) { Write-ResultRow "Local Gateways" "$lngCount" }
    if ($onPremCount -gt 0) { Write-ResultRow "On-Premises" "$onPremCount" }
    # Duration row
    if ($null -ne $StartTimer) {
        $elapsed = $StartTimer.Elapsed
        $mins = [int][Math]::Floor($elapsed.TotalMinutes)
        $secs = $elapsed.Seconds
        $durationStr = if ($mins -gt 0) { "${mins}m $($secs.ToString('00'))s" } else { "${secs}s" }
        Write-ResultRow "Duration" $durationStr
    }
    $warnCount = $script:DiscoveryErrors.Count
    if ($warnCount -gt 0) { Write-ResultRow "Warnings" "$warnCount" }
    Write-Host "$($script:C_BOLD)$($script:C_CYAN)  └──────────────────┴─────────────────────────┘$($script:C_RESET)"
    $fullOutputPath = $OutputFile
    Write-Host "$($script:C_WHITE)  $('Output:'.PadRight(16))$($script:C_RESET) $fullOutputPath"
    Write-LogToFile "  $('Output:'.PadRight(16)) $fullOutputPath"
    if (-not [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        $fullLogPath = Resolve-Path $script:LogFilePath -ErrorAction SilentlyContinue
        Write-Host "$($script:C_WHITE)  $('Log:'.PadRight(16))$($script:C_RESET) $fullLogPath"
        Write-LogToFile "  $('Log:'.PadRight(16)) $fullLogPath"
    }

    if ($warnCount -gt 0) {
        Write-Host ""
        # Group errors by category
        $byCategory = @{}
        foreach ($err in $script:DiscoveryErrors) {
            $cat = if ($err.ContainsKey("category")) { $err["category"] } else { "Other" }
            if (-not $byCategory.ContainsKey($cat)) { $byCategory[$cat] = @() }
            $byCategory[$cat] += $err
        }
        $catCount = $byCategory.Keys.Count
        Write-LogWarn "Completed with $warnCount error(s) in $catCount category/categories:"
        foreach ($cat in ($byCategory.Keys | Sort-Object)) {
            $catErrors = $byCategory[$cat]
            Write-LogWarn "  [$cat] ($($catErrors.Count)):"
            foreach ($e in $catErrors) {
                $scope = $e["scope"]; $message = $e["error"]
                if ([string]::IsNullOrWhiteSpace($message)) { $message = $e["message"] }
                Write-LogWarn "    - ${scope}: $message"
            }
        }
    }

    Write-Host ""
    Write-Host "$($script:C_BOLD)$($script:C_CYAN)  Next Steps:$($script:C_RESET)"
    Write-Host "$($script:C_DIM)  1. Load the output file into the Azure Network Topology Viewer.$($script:C_RESET)"
    Write-Host "$($script:C_DIM)  2. The initial layout may look messy — drag nodes to arrange them.$($script:C_RESET)"
    Write-Host "$($script:C_DIM)  3. Save the file — positions are persisted and restored on reload.$($script:C_RESET)"
    Write-Host "$($script:C_DIM)  4. Use 'Export as PNG' to capture the current view.$($script:C_RESET)"

    return $OutputFile
}

# ── Banner ───────────────────────────────────────────────────────────────────
function Show-Banner {
    $W = 60
    $bar = "═" * ($W + 4)
    function Write-BannerLine {
        param([string]$Text, [string]$Color = "")
        $pad = " " * ($W - $Text.Length)
        Write-Host "$($script:C_BOLD)$($script:C_CYAN)  ║$($script:C_RESET)  $Color$Text$($script:C_RESET)$pad  $($script:C_BOLD)$($script:C_CYAN)║$($script:C_RESET)"
    }
    Write-Host ""
    Write-Host "$($script:C_BOLD)$($script:C_CYAN)  ╔$bar╗$($script:C_RESET)"
    Write-BannerLine ""
    Write-BannerLine "  ▄▀█ █▀▀ █▀▄   █▀▀ █▀ █▀▄▀█ █▀▀" "$($script:C_BOLD)$($script:C_GREEN)"
    Write-BannerLine "  █▀█ ██▄ █▄▀   ██▄ ▄█ █ ▀ █ ██▄" "$($script:C_BOLD)$($script:C_GREEN)"
    Write-BannerLine ""
    Write-BannerLine "  Azure Network Topology Generator" "$($script:C_BOLD)$($script:C_WHITE)"
    Write-BannerLine "  v$($script:ScriptVersion)  ·  Schema v$($script:SchemaVersion)  ·  powershell" $script:C_DIM
    Write-BannerLine "  Author: johnfern@" $script:C_DIM
    Write-BannerLine ""
    Write-Host "$($script:C_BOLD)$($script:C_CYAN)  ╚$bar╝$($script:C_RESET)"
}

# ── Main ─────────────────────────────────────────────────────────────────────
function Main {
    Show-Banner
    $startingVNetId = if (-not [string]::IsNullOrWhiteSpace($VHubId)) { $VHubId } else { $VNetId }
    $startingVNetType = "Microsoft.Network/virtualNetworks"
    if (-not [string]::IsNullOrWhiteSpace($VHubId)) { $startingVNetType = "Microsoft.Network/virtualHubs" }

    $subId = $Subscription
    $subName = ""
    $rgName = $ResourceGroup
    $diagramTitle = $Title

    # Prerequisites
    Test-Prerequisites | Out-Null

    # Sleep prevention
    Start-SleepPrevention

    # Step 1: Subscription
    if (-not [string]::IsNullOrWhiteSpace($subId)) {
        if (Test-SubscriptionGuid $subId) {
            $subName = Invoke-AzCliText @("account", "show", "--subscription", $subId, "--query", "name")
            if ([string]::IsNullOrWhiteSpace($subName)) { $subName = $subId }
        } else {
            $subName = $subId
            $resolved = Invoke-AzCliText @("account", "show", "--subscription", $subName, "--query", "id")
            if ([string]::IsNullOrWhiteSpace($resolved)) {
                Write-LogError "Could not resolve subscription: $subName"
                exit 1
            }
            $subId = $resolved
        }
        Write-LogInfo "Using subscription: $subName ($subId)"
    }

    # Step 2: Direct VNet/vHub ID
    if (-not [string]::IsNullOrWhiteSpace($startingVNetId)) {
        if (-not (Test-ArmResourceId $startingVNetId)) {
            Write-LogError "Invalid resource ID: $startingVNetId"
            exit 1
        }
        $subId = Get-SubscriptionFromId $startingVNetId
        $rgName = Get-ResourceGroupFromId $startingVNetId
        $subName = Invoke-AzCliText @("account", "show", "--subscription", $subId, "--query", "name")
        if ([string]::IsNullOrWhiteSpace($subName)) { $subName = $subId }
        Write-LogInfo "Direct mode: $startingVNetId"
    }

    # Step 3: Interactive selection
    if ([string]::IsNullOrWhiteSpace($subId)) {
        if (-not [string]::IsNullOrWhiteSpace($script:AcceptedSubId)) {
            $subId = $script:AcceptedSubId
            $subName = $script:AcceptedSubName
            Write-LogInfo "Using subscription: $subName ($subId)"
        } else {
            $sel = Select-Subscription
            $subId = $sel.Id; $subName = $sel.Name
        }
    }
    if ([string]::IsNullOrWhiteSpace($rgName)) {
        $rgName = Select-ResourceGroup -SubId $subId
    }
    if ([string]::IsNullOrWhiteSpace($startingVNetId)) {
        $sel = Select-VNet -SubId $subId -RgName $rgName
        $startingVNetId = $sel.Id; $startingVNetType = $sel.Type
    }

    # Step 4: Title
    $diagramTitle = Read-DiagramTitle -Existing $diagramTitle
    Write-LogInfo "Title: $diagramTitle"

    # Step 5: Build scope
    $scopeResourceId = if (-not [string]::IsNullOrWhiteSpace($startingVNetId)) { $startingVNetId } else { "/subscriptions/$subId/resourceGroups/$rgName" }
    $scopeResourceType = if (-not [string]::IsNullOrWhiteSpace($startingVNetId)) { $startingVNetType } else { "ResourceGroup" }

    # Step 6: Collect VNet IDs
    Write-LogStep "Discovering Network Topology"

    $vnetIds = @()
    if (-not [string]::IsNullOrWhiteSpace($startingVNetId)) {
        $vnetIds = @($startingVNetId)
    } else {
        $allVnets = Invoke-WithRetry "List VNets" @("network", "vnet", "list", "--subscription", $subId, "--resource-group", $rgName, "--query", "[].id") -AllowFailure
        if ($null -ne $allVnets) { if ($allVnets -isnot [array]) { $allVnets = @($allVnets) }; $vnetIds += $allVnets }

        $allVhubs = Invoke-WithRetry "List vHubs" @("network", "vhub", "list", "--subscription", $subId, "--resource-group", $rgName, "--query", "[].id") -AllowFailure -TimeoutSeconds 30
        if ($null -ne $allVhubs) { if ($allVhubs -isnot [array]) { $allVhubs = @($allVhubs) }; $vnetIds += $allVhubs }
    }

    if ($vnetIds.Count -eq 0) {
        Write-LogError "No VNets or Virtual Hubs to discover."
        exit 1
    }

    # Step 7: Resolve topology version from baseline
    $topologyVersion = 1
    $baselineData = $null
    if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
        if (Test-Path $Baseline) {
            try {
                $baselineData = Get-Content -Path $Baseline -Raw | ConvertFrom-Json -AsHashtable
                $prevVersion = $baselineData["topologyVersion"]
                if ($null -ne $prevVersion -and $prevVersion -is [int] -and $prevVersion -ge 1) {
                    $topologyVersion = $prevVersion + 1
                }
                Write-LogInfo "Baseline topology version $prevVersion → new version $topologyVersion"
                Write-LogInfo "Baseline merge enabled — user edits will be preserved"
            } catch {
                Write-LogWarn "Could not read baseline file '$Baseline': $($_.Exception.Message) — defaulting to version 1"
                $baselineData = $null
            }
        } else {
            Write-LogWarn "Could not read baseline file '$Baseline' — file not found, defaulting to version 1"
        }
    }

    # Step 8: Discover
    $titleSlug = ($diagramTitle.ToLower() -replace " ", "-") -replace "[^a-z0-9._-]", ""
    $ts = (Get-Date -AsUTC -Format "yyyyMMdd-HHmmss")

    # Open persistent log file (same directory as output, .log extension)
    $logFileName = "topology.$titleSlug.$ts.log"
    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        $outDir = Split-Path $Output -Parent
        if (-not [string]::IsNullOrWhiteSpace($outDir) -and (Test-Path $outDir)) {
            $logFileName = Join-Path $outDir $logFileName
        }
    }
    Open-LogFile $logFileName

    # Retroactively write prerequisite context to log file
    $pyVer = "$($PSVersionTable.PSVersion)"
    $azVerJson = & az version --output json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $azVer = if ($azVerJson) { $azVerJson.'azure-cli' } else { "unknown" }
    $acct = & az account show --output json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    Write-LogToFile "── Generator ──"
    Write-LogToFile "  v$($script:ScriptVersion)  ·  Schema v$($script:SchemaVersion)  ·  powershell"
    Write-LogToFile "  PowerShell $pyVer  ·  Azure CLI $azVer"
    if ($acct) {
        Write-LogToFile "  User:         $($acct.user.name)"
        Write-LogToFile "  Tenant:       $($acct.tenantId)"
        Write-LogToFile "  Subscription: $($acct.name) ($($acct.id))"
    }
    if (-not [string]::IsNullOrWhiteSpace($startingVNetId)) {
        Write-LogToFile "  Resource:     $startingVNetId"
    }
    Write-LogToFile "  Title:        $diagramTitle"
    Write-LogToFile ""
    Write-LogInfo "Log file: $(Resolve-Path $logFileName -ErrorAction SilentlyContinue)"

    # Capture start time for duration reporting
    $scriptTimer = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not [string]::IsNullOrWhiteSpace($startingVNetId) -or $vnetIds.Count -eq 1) {
        $outFile = if (-not [string]::IsNullOrWhiteSpace($Output)) { $Output } else { "topology.$titleSlug.$ts.json" }
        Invoke-DiscoverAndEmit -DiagramTitle $diagramTitle -ScopeResourceId $scopeResourceId -ScopeResourceType $scopeResourceType `
            -OutputFile $outFile -SeedIds $vnetIds -SubId $subId -SubName $subName -TopologyVersion $topologyVersion -StartTimer $scriptTimer -BaselineData $baselineData
    } else {
        Write-LogStep "Scanning peerings to identify network groups"
        $components = Build-ConnectedComponents -Ids $vnetIds
        Write-LogInfo "Found $($components.Count) network group(s) across $($vnetIds.Count) VNet(s)"

        for ($ci = 0; $ci -lt $components.Count; $ci++) {
            $comp = $components[$ci]
            $rootId = $comp[0]
            $rootName = Get-ArmBasename $rootId

            if ($components.Count -eq 1) {
                $compOut = if (-not [string]::IsNullOrWhiteSpace($Output)) { $Output } else { "topology.$titleSlug.$ts.json" }
                $compTitle = $diagramTitle
            } else {
                $baseName = if (-not [string]::IsNullOrWhiteSpace($Output)) { $Output -replace "\.json$", "" } else { "topology.$titleSlug.$ts" }
                $compOut = "$baseName.$($ci+1).$rootName.json"
                $compTitle = "$diagramTitle ($rootName)"
            }

            Write-LogStep "Group $($ci+1)/$($components.Count) — $rootName ($($comp.Count) network(s) in local RG)"
            Invoke-DiscoverAndEmit -DiagramTitle $compTitle -ScopeResourceId $rootId -ScopeResourceType "Microsoft.Network/virtualNetworks" `
                -OutputFile $compOut -SeedIds @($rootId) -SubId $subId -SubName $subName -TopologyVersion $topologyVersion -StartTimer $scriptTimer -BaselineData $baselineData
        }
    }

    Write-LogStep "Complete"
    Close-LogFile
}

# ── Entry point ──────────────────────────────────────────────────────────────
# Detect merge subcommand: pwsh Get-NetworkTopology.ps1 merge file1 file2 -o output
if ($args.Count -gt 0 -or ($Title -eq "merge" -and [string]::IsNullOrWhiteSpace($VNetId))) {
    # If Title == "merge" and no VNetId, treat as merge subcommand
    # Remaining args in $args after param binding: the file paths and -o flag
    if ($Title -eq "merge") {
        # Parse merge args from remaining $args
        $mergeFiles = @()
        $mergeOutput = ""
        $i = 0
        while ($i -lt $args.Count) {
            if ($args[$i] -eq "-o" -or $args[$i] -eq "--output") {
                if ($i + 1 -lt $args.Count) { $mergeOutput = $args[$i + 1]; $i += 2 } else { $i++ }
            } else {
                $mergeFiles += $args[$i]; $i++
            }
        }
        # Use -Output param if -o not found in args
        if ([string]::IsNullOrWhiteSpace($mergeOutput) -and -not [string]::IsNullOrWhiteSpace($Output)) {
            $mergeOutput = $Output
        }
        if ($mergeFiles.Count -lt 2) {
            Write-Host "  ✖ merge requires at least 2 input files" -ForegroundColor Red
            exit 1
        }
        if ([string]::IsNullOrWhiteSpace($mergeOutput)) {
            Write-Host "  ✖ merge requires -o / --output" -ForegroundColor Red
            exit 1
        }
        # Validate files exist
        foreach ($f in $mergeFiles) {
            if (-not (Test-Path $f)) { Write-Host "  ✖ File not found: $f" -ForegroundColor Red; exit 1 }
        }
        Show-Banner
        Write-LogStep "Merge Topology Files"
        Write-LogInfo "Input files: $($mergeFiles.Count)"
        for ($fi = 0; $fi -lt $mergeFiles.Count; $fi++) {
            Write-LogInfo "  $($fi + 1). $($mergeFiles[$fi])"
        }
        Write-LogInfo "Output: $mergeOutput"
        Invoke-MergeFiles -FilePaths $mergeFiles -OutputPath $mergeOutput
        Write-LogStep "Complete"
        Write-LogInfo "Output: $(Resolve-Path $mergeOutput -ErrorAction SilentlyContinue)"
        exit 0
    }
}

try {
    Main
} finally {
    Close-LogFile
    Stop-SleepPrevention
}
