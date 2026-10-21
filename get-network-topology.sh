#!/usr/bin/env bash
# get-network-topology.sh — Azure Network Topology Generator for AED/ESME [Beta]
#
# Discovers Azure VNet topology and produces schema-v3.0 JSON
# compatible with the AED ESME architecture diagram renderer.
#
# Captures VNets, vWAN hubs, subnets (with enrichment: service endpoints,
# PE/PLS network policies, delegations), peerings, gateways, ExpressRoute
# circuits, VPN sites, and on-premises connections.
#
# Usage:
#   ./get-network-topology.sh [OPTIONS]
#   ./get-network-topology.sh merge <file1> <file2> [<fileN>...] -o <output>
#
# Options:
#   --title <TITLE>           Diagram title (prompted if omitted)
#   --vnet-id <ARM_ID>        Optional starting VNet ARM resource ID (skips interactive VNet selection)
#   --vhub-id <ARM_ID>        Optional starting Virtual Hub ARM resource ID (skips interactive selection)
#   --subscription <ID>       Subscription ID or name (skips subscription selection)
#   --resource-group <NAME>   Resource group name (skips RG selection)
#   --output <FILE>           Output file path (default: topology.<title>.<timestamp>.json)
#   --baseline <FILE>         Previous topology JSON to preserve user edits from
#   --help                    Show this help message
#
# Subcommands:
#   merge                     Merge multiple topology files offline (no Azure login)
#
# Topology Versioning:
#   Each output includes a topologyVersion field (default: 1). Pass --baseline
#   with a prior topology JSON to auto-increment the version counter and
#   preserve all user-authored content (_layout positions, OnPremises edits,
#   x-aed-* tags, user-created OnPremises sites).
#
# Dependencies: az (Azure CLI 2.50+), jq (1.6+), bash (4.0+)
#   The script checks for these automatically and will prompt to
#   install any missing tools or log in to Azure if needed.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="0.5.0-beta"
readonly SCHEMA_VERSION="3.0"
readonly GENERATOR_NAME="aed-esme-networking/bash"
readonly MAX_RETRIES=3
readonly RETRY_BASE_DELAY=2

# ── Error accumulation (global) ──────────────────────────────────────────────
DISCOVERY_ERRORS=()

# ── Log file (global) ────────────────────────────────────────────────────────
_LOG_FILE=""

_log_to_file() {
    [[ -z "$_LOG_FILE" ]] && return
    local utc_ts local_ts tz_abbr
    utc_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local_ts=$(date +"%H:%M:%S")
    tz_abbr=$(date +"%Z")
    # Strip ANSI codes
    local clean_msg
    clean_msg=$(printf '%s' "$*" | sed 's/\x1b\[[0-9;]*m//g')
    printf '[%s / %s %s] %s\n' "$utc_ts" "$local_ts" "$tz_abbr" "$clean_msg" >> "$_LOG_FILE"
}

_log_file_open() {
    _LOG_FILE="$1"
    : > "$_LOG_FILE"
}

# ── Temp file tracking & cleanup ─────────────────────────────────────────────
_TEMP_FILES=()

_register_temp() {
    _TEMP_FILES+=("$1")
}

_cleanup_temp_files() {
    for f in ${_TEMP_FILES[@]+"${_TEMP_FILES[@]}"}; do
        rm -f "$f" 2>/dev/null || true
    done
}

# ── Logging ──────────────────────────────────────────────────────────────────
# Colors (respects NO_COLOR convention and non-tty output)
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _C_RESET=$'\033[0m'
    _C_DIM=$'\033[2m'
    _C_BOLD=$'\033[1m'
    _C_CYAN=$'\033[36m'
    _C_YELLOW=$'\033[33m'
    _C_RED=$'\033[31m'
    _C_GREEN=$'\033[32m'
    _C_BLUE=$'\033[34m'
    _C_MAGENTA=$'\033[35m'
    _C_WHITE=$'\033[97m'
else
    _C_RESET="" _C_DIM="" _C_BOLD="" _C_CYAN="" _C_YELLOW=""
    _C_RED="" _C_GREEN="" _C_BLUE="" _C_WHITE="" _C_MAGENTA=""
fi

# Log hierarchy:
#   log_step      ── Section Header ──                     bold cyan
#   log_resource    ● VNet: my-vnet                        green (blank line before)
#   log_detail        subnet: default                      dim white (6-space indent)
#   log_substep          Checking ER gateways...           dim cyan (10-space indent)
#   log_found              2 resource(s) found             dim green (14-space indent)
#   log_queue              ↳ queued Peered: vnet-02        blue (14-space indent)
#   log_dequeue     ▸ Processing from queue: vnet-02       magenta
#   log_info      general info                             dim white
#   log_warn      ▲ warning                                yellow
#   log_error     ✖ error                                  red
#   log_alert     ╔══ boxed alert                          bold red

log_info()     { printf "${_C_DIM}  %s${_C_RESET}\n" "$*" >&2; _log_to_file "  $*"; }
log_detail()   { printf "${_C_DIM}      %s${_C_RESET}\n" "$*" >&2; _log_to_file "      $*"; }
log_substep()  { printf "${_C_DIM}${_C_CYAN}          %s${_C_RESET}\n" "$*" >&2; _log_to_file "          $*"; }
log_found()    { printf "${_C_DIM}${_C_GREEN}              %s${_C_RESET}\n" "$*" >&2; _log_to_file "              $*"; }
log_warn()     { printf "${_C_YELLOW}  ▲ %s${_C_RESET}\n" "$*" >&2; _log_to_file "  WARN: $*"; }
log_error()    { printf "${_C_RED}  ✖ %s${_C_RESET}\n" "$*" >&2; _log_to_file "  ERROR: $*"; }
log_step()     { printf "\n${_C_DIM}[$(date +%H:%M:%S)]${_C_RESET} ${_C_BOLD}${_C_CYAN}── %s ──${_C_RESET}\n" "$*" >&2; _log_to_file "── $* ──"; }
log_resource() { printf "\n${_C_DIM}[$(date +%H:%M:%S)]${_C_RESET} ${_C_GREEN}${_C_BOLD}  ● %s${_C_RESET}\n" "$*" >&2; _log_to_file "  ● $*"; }
log_queue()    { printf "${_C_BLUE}              ↳ queued %s${_C_RESET}\n" "$*" >&2; _log_to_file "              ↳ queued $*"; }
log_dequeue()  { printf "${_C_MAGENTA}    ▸ Processing: %s${_C_RESET}\n" "$*" >&2; _log_to_file "    ▸ Processing: $*"; }
log_alert() {
    printf "\n${_C_RED}${_C_BOLD}  ╔══════════════════════════════════════════════════${_C_RESET}\n" >&2
    printf "${_C_RED}${_C_BOLD}  ║  ⚠  %s${_C_RESET}\n" "$1" >&2
    local all_lines="$1"
    shift
    for line in "$@"; do
        printf "${_C_RED}  ║     %s${_C_RESET}\n" "$line" >&2
        all_lines="$all_lines | $line"
    done
    printf "${_C_RED}${_C_BOLD}  ╚══════════════════════════════════════════════════${_C_RESET}\n" >&2
    _log_to_file "  ALERT: $all_lines"
}

# Spinner — runs in the background while a long-running command executes.
# Usage:  start_spinner "Loading…"  ;  <long command>  ;  stop_spinner
_SPINNER_PID=""
start_spinner() {
    local msg="${1:-Loading…}"
    if [[ ! -t 2 ]] || [[ -n "${NO_COLOR:-}" ]]; then
        log_info "$msg"
        return
    fi
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r${_C_DIM}  %s %s${_C_RESET}" "${frames[$((i % ${#frames[@]}))]}" "$msg" >&2
            i=$((i + 1))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null
}
stop_spinner() {
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null
        _SPINNER_PID=""
        printf "\r\033[K" >&2
    fi
}

# ── Validation ───────────────────────────────────────────────────────────────
validate_arm_resource_id() {
    [[ "$1" =~ ^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[^/]+/providers/ ]]
}

validate_subscription_guid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ── Sleep Prevention ─────────────────────────────────────────────────────────
CAFFEINATE_PID=""

is_interactive_session() {
    # Skip for SSH sessions and Azure Cloud Shell
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]] && return 1
    [[ -n "${ACC_CLOUD:-}" ]] && return 1  # Azure Cloud Shell
    [[ -t 0 ]]  # stdin is a terminal
}

start_sleep_prevention() {
    is_interactive_session || return 0

    read -rp "Prevent this machine from sleeping during discovery? [Y/n/q=exit]: " sp_choice
    sp_choice="${sp_choice:-Y}"
    if [[ "$sp_choice" =~ ^[Qq]$ ]]; then log_info "Exiting."; exit 0; fi
    if [[ ! "$sp_choice" =~ ^[Yy]$ ]]; then return 0; fi

    case "$(uname -s)" in
        Darwin)
            # macOS: caffeinate ships with every macOS
            if command -v caffeinate &>/dev/null; then
                caffeinate -i -s -w $$ &
                CAFFEINATE_PID=$!
                log_info "Sleep prevention active (caffeinate)  ✓"
            else
                log_warn "caffeinate not found — sleep prevention unavailable."
            fi
            ;;
        Linux)
            # Linux: systemd-inhibit if available (desktops only, servers don't sleep)
            if command -v systemd-inhibit &>/dev/null; then
                log_detail "Sleep prevention not typically needed on Linux servers."
            fi
            ;;
        *)
            log_detail "Sleep prevention not available on this platform."
            ;;
    esac
}

stop_sleep_prevention() {
    if [[ -n "$CAFFEINATE_PID" ]]; then
        kill "$CAFFEINATE_PID" 2>/dev/null || true
        wait "$CAFFEINATE_PID" 2>/dev/null || true
        CAFFEINATE_PID=""
    fi
}

# ── Prerequisites ────────────────────────────────────────────────────────────
check_prerequisites() {
    log_step "Checking Prerequisites"

    local missing=()

    # ── bash version ──
    if (( BASH_VERSINFO[0] < 4 )); then
        log_warn "bash 4.0+ is recommended (found ${BASH_VERSION})."
        log_detail "'All VNets' mode with multiple connected components requires bash 4+."
        log_detail "macOS ships bash 3.x — install a newer version via:"
        log_detail "  brew install bash"
        log_detail "Then run:  /opt/homebrew/bin/bash $0"
    fi
    log_info "bash ${BASH_VERSION}  ✓"

    # ── jq ──
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
        log_error "jq is not installed."
        log_detail "Install via:"
        log_detail "  macOS:         brew install jq"
        log_detail "  Debian/Ubuntu: sudo apt-get install jq"
        log_detail "  Azure Cloud Shell: pre-installed"
    else
        local jq_ver
        jq_ver=$(jq --version 2>/dev/null | sed 's/jq-//')
        log_info "jq ${jq_ver}  ✓"
    fi

    # ── Azure CLI ──
    if ! command -v az &>/dev/null; then
        missing+=("az")
        log_error "Azure CLI (az) is not installed."
        log_detail "Install via:"
        log_detail "  macOS:         brew install azure-cli"
        log_detail "  Debian/Ubuntu: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        log_detail "  Windows:       winget install Microsoft.AzureCLI"
        log_detail "  Azure Cloud Shell: pre-installed"
    else
        local az_ver
        az_ver=$(az version --output json 2>/dev/null | jq -r '."azure-cli" // "unknown"')
        log_info "Azure CLI ${az_ver}  ✓"

        # Azure CLI minimum version check
        local min_az_version="2.60.0"
        local too_old=false
        if [[ "$az_ver" != "unknown" ]]; then
            local IFS='.'
            read -ra cur_parts <<< "$az_ver"
            read -ra min_parts <<< "$min_az_version"
            IFS=' '
            for vi in 0 1 2; do
                local c=${cur_parts[$vi]:-0}
                local m=${min_parts[$vi]:-0}
                if (( c < m )); then too_old=true; break; fi
                if (( c > m )); then break; fi
            done
        fi
        if $too_old; then
            log_warn "Azure CLI ${az_ver} is older than recommended minimum ${min_az_version}."
            log_detail "Older versions may have bugs with resource queries or interactive prompts."
            log_detail "Update via: az upgrade"
            read -rp "Continue anyway? [y/N/q=exit]: " cont_choice
            cont_choice="${cont_choice:-N}"
            if [[ "$cont_choice" =~ ^[Qq]$ ]]; then log_info "Exiting."; exit 0; fi
            if [[ ! "$cont_choice" =~ ^[Yy]$ ]]; then
                log_info "Exiting. Please update Azure CLI and try again."
                exit 1
            fi
        fi
    fi

    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Azure CLI config: suppress interactive prompts (survey/telemetry)
    # On Windows/WSL, az may block on stdin if these aren't set.
    local az_config_dir="${AZURE_CONFIG_DIR:-$HOME/.azure}"
    local az_config_file="${az_config_dir}/config"
    local needs_config=false
    if [[ -f "$az_config_file" ]]; then
        if ! grep -qi "collect_telemetry" "$az_config_file" 2>/dev/null; then
            needs_config=true
        fi
    else
        needs_config=true
    fi

    if $needs_config; then
        log_warn "Azure CLI telemetry/survey prompts are not configured."
        log_detail "Unconfigured prompts can cause the script to hang on some platforms."
        read -rp "Allow this script to disable interactive prompts? [Y/n/q=exit]: " cfg_choice
        cfg_choice="${cfg_choice:-Y}"
        if [[ "$cfg_choice" =~ ^[Qq]$ ]]; then log_info "Exiting."; exit 0; fi
        if [[ "$cfg_choice" =~ ^[Yy]$ ]]; then
            log_info "Configuring Azure CLI: disabling interactive prompts…"
            az config set core.collect_telemetry=false core.survey_message=false core.only_show_errors=true 2>/dev/null
            log_info "Azure CLI prompts disabled  ✓"
        else
            log_warn "Skipped — the script may hang if az CLI prompts for input."
            log_detail "You can manually run: az config set core.collect_telemetry=false core.survey_message=false"
        fi
    fi

    # ── Azure login check ──
    local account_json
    if ! account_json=$(az account show --output json 2>/dev/null); then
        log_warn "You are not logged into Azure."
        read -rp "Would you like to log in now? [Y/n/q=exit]: " login_choice
        login_choice="${login_choice:-Y}"
        if [[ "$login_choice" =~ ^[Qq]$ ]]; then
            log_info "Exiting."
            exit 0
        fi

        if [[ "$login_choice" =~ ^[Yy]$ ]]; then
            read -rp "Tenant ID (leave blank for default, q=exit): " tenant_id
            if [[ "$tenant_id" =~ ^[Qq]$ ]]; then
                log_info "Exiting."
                exit 0
            fi
            if [[ -n "$tenant_id" ]]; then
                log_info "Logging in to tenant ${tenant_id}..."
                az login --tenant "$tenant_id" --output none
            else
                log_info "Logging in to default tenant…"
                az login --output none
            fi

            # Verify login succeeded
            if ! account_json=$(az account show --output json 2>/dev/null); then
                log_error "Login failed. Please run 'az login' manually."
                exit 2
            fi
        else
            log_error "Azure login is required. Run 'az login' to authenticate."
            exit 2
        fi
    fi

    local current_sub current_sub_id current_tenant current_user
    current_sub=$(printf '%s' "$account_json" | jq -r '.name')
    current_sub_id=$(printf '%s' "$account_json" | jq -r '.id')
    current_tenant=$(printf '%s' "$account_json" | jq -r '.tenantId')
    current_user=$(printf '%s' "$account_json" | jq -r '.user.name')
    log_info "Logged in as: $current_user"
    log_info "Tenant:       $current_tenant"
    log_info "Subscription: $current_sub"

    # ── Offer to switch tenant/subscription or continue with current ──
    read -rp "Continue with this tenant and subscription? [Y/n/q=exit]: " switch_choice
    switch_choice="${switch_choice:-Y}"
    if [[ "$switch_choice" =~ ^[Qq]$ ]]; then
        log_info "Exiting."
        exit 0
    fi

    if [[ ! "$switch_choice" =~ ^[Yy]$ ]]; then
        # List available tenants (use az account list for tenant display names)
        log_step "Switch Tenant"
        start_spinner "Fetching available tenants…"
        local subs_for_tenants
        subs_for_tenants=$(invoke_with_retry "List subs for tenants" --max-retries 1 \
            az account list --query "[].{tenantId:tenantId, tenantDisplayName:tenantDisplayName}" --output json || echo '[]')
        stop_spinner
        # Deduplicate by tenantId, pick first non-null display name
        local tenants_json
        tenants_json=$(printf '%s' "$subs_for_tenants" | jq '[group_by(.tenantId) | .[] | {tenantId: .[0].tenantId, displayName: ([.[] | select(.tenantDisplayName != null) | .tenantDisplayName] | first // "")}]')
        local tenant_count
        tenant_count=$(printf '%s' "$tenants_json" | jq 'length')

        if (( tenant_count > 0 )); then
            log_info "Available tenants:"
            for (( t = 0; t < tenant_count; t++ )); do
                local t_id t_name t_marker="" t_label
                t_id=$(printf '%s' "$tenants_json" | jq -r ".[$t].tenantId")
                t_name=$(printf '%s' "$tenants_json" | jq -r ".[$t].displayName // \"\"")
                [[ "$t_id" == "$current_tenant" ]] && t_marker=" (current)"
                if [[ -n "$t_name" ]]; then
                    t_label="$t_name  [$t_id]"
                else
                    t_label="[$t_id]"
                fi
                printf '  %d) %s%s\n' "$((t + 1))" "$t_label" "$t_marker" >&2
            done
            echo "  0) Enter a Tenant ID manually" >&2
            echo "  q) Exit" >&2
            local t_choice
            read -rp "Tenant [0-$tenant_count, q=exit]: " t_choice
            if [[ "$t_choice" =~ ^[Qq]$ ]]; then
                log_info "Exiting."
                exit 0
            elif [[ "$t_choice" =~ ^[0-9]+$ ]] && (( t_choice >= 1 && t_choice <= tenant_count )); then
                local new_tenant_id
                new_tenant_id=$(printf '%s' "$tenants_json" | jq -r ".[$((t_choice - 1))].tenantId")
                log_info "Logging in to tenant ${new_tenant_id} (this may open a browser for MFA)..."
                az login --tenant "$new_tenant_id" --output none
                if ! account_json=$(az account show --output json 2>/dev/null); then
                    log_error "Login to new tenant failed."
                    exit 2
                fi
                log_info "Switched successfully."
                current_sub=$(printf '%s' "$account_json" | jq -r '.name')
                current_sub_id=$(printf '%s' "$account_json" | jq -r '.id')
            elif [[ "$t_choice" == "0" ]]; then
                read -rp "Enter Tenant ID (q=exit): " new_tenant_id
                if [[ "$new_tenant_id" =~ ^[Qq]$ ]]; then
                    log_info "Exiting."
                    exit 0
                fi
                if [[ -n "$new_tenant_id" ]]; then
                    log_info "Logging in to tenant ${new_tenant_id} (this may open a browser for MFA)..."
                    az login --tenant "$new_tenant_id" --output none
                    if ! account_json=$(az account show --output json 2>/dev/null); then
                        log_error "Login to new tenant failed."
                        exit 2
                    fi
                    log_info "Switched successfully."
                    current_sub=$(printf '%s' "$account_json" | jq -r '.name')
                    current_sub_id=$(printf '%s' "$account_json" | jq -r '.id')
                else
                    log_warn "No tenant ID provided — continuing with current tenant."
                fi
            else
                log_warn "Invalid selection — continuing with current tenant."
            fi
        else
            # Fallback: no tenant list available, ask manually
            read -rp "Enter the Tenant ID to switch to (q=exit): " new_tenant_id
            if [[ "$new_tenant_id" =~ ^[Qq]$ ]]; then
                log_info "Exiting."
                exit 0
            fi
            if [[ -n "$new_tenant_id" ]]; then
                log_info "Logging in to tenant ${new_tenant_id} (this may open a browser for MFA)..."
                az login --tenant "$new_tenant_id" --output none
                if ! account_json=$(az account show --output json 2>/dev/null); then
                    log_error "Login to new tenant failed."
                    exit 2
                fi
                log_info "Switched successfully."
                current_sub=$(printf '%s' "$account_json" | jq -r '.name')
                current_sub_id=$(printf '%s' "$account_json" | jq -r '.id')
            else
                log_warn "No tenant ID provided — continuing with current tenant."
            fi
        fi
    fi

    # Store accepted subscription for later use
    ACCEPTED_SUB_ID="$current_sub_id"
    ACCEPTED_SUB_NAME="$current_sub"

    # ── Check for resource-graph extension (needed for Resource Graph queries) ──
    if ! az extension show --name resource-graph &>/dev/null 2>&1; then
        log_warn "The 'resource-graph' Azure CLI extension is required but not installed."
        read -rp "Install it now? [Y/n/q=exit]: " ext_choice
        ext_choice="${ext_choice:-Y}"
        if [[ "$ext_choice" =~ ^[Qq]$ ]]; then log_info "Exiting."; exit 0; fi
        if [[ "$ext_choice" =~ ^[Yy]$ ]]; then
            log_info "Installing 'resource-graph' extension…"
            if az extension add --name resource-graph --yes --output none 2>/dev/null; then
                log_info "Extension 'resource-graph' installed  ✓"
            else
                log_error "Failed to install 'resource-graph' extension."
                log_detail "Install manually: az extension add --name resource-graph"
                exit 1
            fi
        else
            log_error "The 'resource-graph' extension is required for this script."
            log_detail "Install manually: az extension add --name resource-graph"
            exit 1
        fi
    fi

    log_info "Prerequisites satisfied  ✓"
}
invoke_with_retry() {
    local label="$1"; shift
    local error_scope=""
    local max_retries="$MAX_RETRIES"
    # Check for optional parameters
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --error-scope) error_scope="$2"; shift 2 ;;
            --max-retries) max_retries="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local attempt
    for attempt in $(seq 1 "$max_retries"); do
        local result stderr_output
        stderr_output=$(mktemp)
        _register_temp "$stderr_output"
        if result=$("$@" 2>"$stderr_output"); then
            rm -f "$stderr_output"
            printf '%s' "$result"
            return 0
        fi

        # ── Access Denied fast-fail (GH #33) ──
        if [[ -f "$stderr_output" ]] && grep -qiE "403|AuthorizationFailed|does not have authorization|Forbidden|AccessDenied|InsufficientPrivileges" "$stderr_output" 2>/dev/null; then
            local err_msg="Access Denied: $label"
            local scope="${error_scope:-$label}"
            DISCOVERY_ERRORS+=("$(jq -n --arg scope "$scope" --arg error "$err_msg" --arg category "Access Denied" '{scope: $scope, error: $error, category: $category}')")
            log_warn "$label — Access Denied (403), skipping retries"
            rm -f "$stderr_output"
            return 1
        fi

        # Check for 429 Retry-After
        if [[ -f "$stderr_output" ]] && grep -qi "429\|Too Many Requests" "$stderr_output" 2>/dev/null; then
            local retry_after
            retry_after=$(grep -oi 'Retry-After[: ]*[0-9]*' "$stderr_output" 2>/dev/null | grep -o '[0-9]*' | head -1)
            if [[ -n "$retry_after" ]] && (( attempt < max_retries )); then
                log_warn "$label — HTTP 429, waiting ${retry_after}s (Retry-After)…"
                rm -f "$stderr_output"
                sleep "$retry_after"
                continue
            fi
        fi
        rm -f "$stderr_output"
        if (( attempt == max_retries )); then
            if [[ -n "$error_scope" ]]; then
                local err_msg="Failed after $max_retries retries: $label"
                local category="API Failure"
                DISCOVERY_ERRORS+=("$(jq -n --arg scope "$error_scope" --arg error "$err_msg" --arg category "$category" '{scope: $scope, error: $error, category: $category}')")
                log_warn "Non-fatal: $err_msg"
                return 1
            fi
            return 1
        fi
        local delay=$(( RETRY_BASE_DELAY * (1 << (attempt - 1)) ))
        log_warn "$label — attempt $attempt failed, retrying in ${delay}s…"
        sleep "$delay"
    done
}

invoke_graph_query_paginated() {
    local label="$1"
    local query="$2"
    local subscription="$3"
    local error_scope="${4:-}"
    local id_field="${5:-id}"

    local all_data="[]"
    local seen_ids=""
    local skip_token=""
    local page=0

    while true; do
        page=$((page + 1))
        local args=(az graph query -q "$query" --subscriptions "$subscription" --output json --first 500)
        if [[ -n "$skip_token" ]]; then
            args+=(--skip-token "$skip_token")
        fi

        local page_result
        if [[ -n "$error_scope" ]]; then
            page_result=$(invoke_with_retry "$label (page $page)" --error-scope "$error_scope" "${args[@]}" 2>/dev/null) || break
        else
            page_result=$(invoke_with_retry "$label (page $page)" "${args[@]}" 2>/dev/null) || break
        fi

        local page_data
        page_data=$(printf '%s' "$page_result" | jq '.data // []')

        # Deduplicate by ARM resource ID
        local item_count
        item_count=$(printf '%s' "$page_data" | jq 'length')
        for (( pi = 0; pi < item_count; pi++ )); do
            local item_id
            item_id=$(printf '%s' "$page_data" | jq -r ".[$pi].$id_field // empty" | tr '[:upper:]' '[:lower:]')
            if [[ -n "$item_id" ]] && ! echo "$seen_ids" | grep -qF "$item_id"; then
                seen_ids+="${item_id}"$'\n'
                local item_json
                item_json=$(printf '%s' "$page_data" | jq -c ".[$pi]")
                all_data=$(printf '%s' "$all_data" | jq --argjson item "$item_json" '. + [$item]')
            fi
        done

        skip_token=$(printf '%s' "$page_result" | jq -r '."$skipToken" // .skipToken // empty')
        if [[ -z "$skip_token" ]]; then
            break
        fi
    done

    if (( page > 1 )); then
        local total
        total=$(printf '%s' "$all_data" | jq 'length')
        log_info "Pagination: retrieved $total resources across $page pages for $label"
    fi

    printf '%s' "$all_data"
}

# ── Interactive selection helpers ────────────────────────────────────────────
prompt_selection() {
    local prompt="$1" max="$2"
    while true; do
        read -rp "$prompt" choice
        if [[ "$choice" =~ ^[Qq]$ ]]; then
            log_info "Exiting."
            exit 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max )); then
            echo "$choice"
            return 0
        fi
        echo "  Enter a number between 1 and $max (or 'q' to exit)." >&2
    done
}

select_subscription() {
    log_step "Select Azure Subscription"
    local subs_json
    subs_json=$(invoke_with_retry "List subscriptions" \
        az account list --query "[?state=='Enabled']" --output json) || exit 1

    local count
    count=$(printf '%s' "$subs_json" | jq 'length')
    if (( count == 0 )); then
        log_error "No enabled subscriptions found."
        exit 1
    fi

    printf '%s' "$subs_json" | jq -r 'to_entries[] | "  \(.key + 1)) \(.value.name)  [\(.value.id)]"' >&2
    local idx
    idx=$(prompt_selection "Subscription [1-$count]: " "$count")
    SUB_ID=$(printf '%s' "$subs_json" | jq -r ".[$((idx - 1))].id")
    SUB_NAME=$(printf '%s' "$subs_json" | jq -r ".[$((idx - 1))].name")
    log_info "Selected: $SUB_NAME ($SUB_ID)"
}

select_resource_group() {
    log_step "Select Resource Group"
    local rgs_json
    rgs_json=$(invoke_with_retry "List resource groups" \
        az group list --subscription "$SUB_ID" --output json) || exit 1

    local count
    count=$(printf '%s' "$rgs_json" | jq 'length')
    if (( count == 0 )); then
        log_error "No resource groups found in subscription '$SUB_NAME'."
        exit 1
    fi

    printf '%s' "$rgs_json" | jq -r 'to_entries[] | "  \(.key + 1)) \(.value.name)  (\(.value.location))"' >&2
    local idx
    idx=$(prompt_selection "Resource Group [1-$count]: " "$count")
    RG_NAME=$(printf '%s' "$rgs_json" | jq -r ".[$((idx - 1))].name")
    log_info "Selected: $RG_NAME"
}

select_vnet() {
    log_step "Select Starting Network"
    log_info "Discovery crawls outward from the selected network, following peerings, hub connections, and vWAN links."

    start_spinner "Loading networks in ${RG_NAME}..."

    # ── VNets in the selected RG ──
    local vnets_json
    vnets_json=$(invoke_with_retry "List VNets" \
        az network vnet list --subscription "$SUB_ID" --resource-group "$RG_NAME" --output json) || exit 1
    local vnet_count
    vnet_count=$(printf '%s' "$vnets_json" | jq 'length')

    # ── Virtual Hubs in the selected RG ──
    local vhubs_json
    vhubs_json=$(invoke_with_retry "List vHubs" --max-retries 1 \
        az network vhub list --subscription "$SUB_ID" --resource-group "$RG_NAME" --output json || echo '[]')
    local vhub_count
    vhub_count=$(printf '%s' "$vhubs_json" | jq 'length')

    stop_spinner

    local total_count=$(( vnet_count + vhub_count ))
    if (( total_count == 0 )); then
        log_warn "No VNets or Virtual Hubs found in '$RG_NAME'. No topology to discover."
        exit 1
    fi

    # Display VNets
    if (( vnet_count > 0 )); then
        echo "  VNets:" >&2
        printf '%s' "$vnets_json" | jq -r 'to_entries[] | "    \(.key + 1)) \(.value.name)  [\(.value.addressSpace.addressPrefixes | join(", "))]"' >&2
    fi

    # Display vHubs (numbered after VNets)
    if (( vhub_count > 0 )); then
        echo "  Virtual Hubs:" >&2
        for (( h = 0; h < vhub_count; h++ )); do
            local hname hprefix hloc
            hname=$(printf '%s' "$vhubs_json" | jq -r ".[$h].name")
            hprefix=$(printf '%s' "$vhubs_json" | jq -r ".[$h].addressPrefix // \"\"")
            hloc=$(printf '%s' "$vhubs_json" | jq -r ".[$h].location // \"\"")
            printf '    %d) %s  [%s] (%s)\n' "$((vnet_count + h + 1))" "$hname" "$hprefix" "$hloc" >&2
        done
    fi

    if (( BASH_VERSINFO[0] >= 4 )); then
        echo "  0) All VNets and Virtual Hubs in $RG_NAME" >&2
    else
        echo "  0) All VNets and Virtual Hubs  [disabled — requires bash 4+]" >&2
    fi
    echo "  q) Exit" >&2

    local choice
    read -rp "Select [0-$total_count, q=exit] (0=all): " choice
    if [[ "$choice" =~ ^[Qq]$ ]]; then
        log_info "Exiting."
        exit 0
    elif [[ -z "$choice" || "$choice" == "0" ]]; then
        # Block "All" mode on bash < 4 (no associative arrays for BFS)
        if (( BASH_VERSINFO[0] < 4 )); then
            log_warn "'All' mode is disabled on bash ${BASH_VERSION} (requires 4.0+)."
            log_detail "macOS ships with bash 3.x — install a newer version via:"
            log_detail "  brew install bash"
            log_detail "Then run:  /opt/homebrew/bin/bash $0"
            log_detail "Or select a specific VNet/vHub as your starting point."
            select_vnet
            return
        fi
        # Large environment warning
        log_warn "'All' mode will discover every VNet and Virtual Hub in this"
        log_warn "resource group, including all peered networks across subscriptions."
        log_warn "In large environments this can take a very long time."
        log_warn "Consider selecting a specific VNet or vHub as an entry point instead."
        local confirm
        read -rp "  Continue with 'All' mode? [y/N/q=exit]: " confirm
        if [[ "$confirm" =~ ^[Qq]$ ]]; then
            log_info "Exiting."
            exit 0
        fi
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Cancelled. Please select a specific resource."
            select_vnet
            return
        fi
        STARTING_VNET_ID=""
        STARTING_VNET_TYPE="All"
        log_info "Will discover all VNets and Virtual Hubs in $RG_NAME"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= vnet_count )); then
        STARTING_VNET_ID=$(printf '%s' "$vnets_json" | jq -r ".[$((choice - 1))].id")
        STARTING_VNET_TYPE="Microsoft.Network/virtualNetworks"
        log_info "Starting from VNet: $(printf '%s' "$vnets_json" | jq -r ".[$((choice - 1))].name")"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > vnet_count && choice <= total_count )); then
        local vhub_idx=$(( choice - vnet_count - 1 ))
        STARTING_VNET_ID=$(printf '%s' "$vhubs_json" | jq -r ".[$vhub_idx].id")
        STARTING_VNET_TYPE="Microsoft.Network/virtualHubs"
        log_info "Starting from vHub: $(printf '%s' "$vhubs_json" | jq -r ".[$vhub_idx].name")"
    else
        echo "  Invalid selection." >&2
        select_vnet
    fi
}

prompt_title() {
    if [[ -z "$DIAGRAM_TITLE" ]]; then
        read -rp "Diagram title (q=exit): " DIAGRAM_TITLE
        if [[ "$DIAGRAM_TITLE" =~ ^[Qq]$ ]]; then
            log_info "Exiting."
            exit 0
        fi
        if [[ -z "$DIAGRAM_TITLE" ]]; then
            DIAGRAM_TITLE="Azure Network Topology — $(date -u +%Y-%m-%d)"
        fi
    fi
}

# ── Discovery functions ─────────────────────────────────────────────────────

# Discover a single VNet and return a JSON object matching the schema vnet def
discover_vnet() {
    local vnet_id="$1"

    local vnet_json
    vnet_json=$(invoke_with_retry "Get VNet $vnet_id" --max-retries 1 \
        az network vnet show --ids "$vnet_id" --output json || echo '{}')

    local vnet_name address_prefixes location rg
    vnet_name=$(printf '%s' "$vnet_json" | jq -r '.name // empty')
    [[ -z "$vnet_name" ]] && vnet_name=$(basename "$vnet_id")
    address_prefixes=$(printf '%s' "$vnet_json" | jq -c '[.addressSpace.addressPrefixes // [] | .[]]')
    location=$(printf '%s' "$vnet_json" | jq -r '.location // "unknown"')
    rg=$(printf '%s' "$vnet_json" | jq -r '.resourceGroup // "unknown"')
    dns_servers=$(printf '%s' "$vnet_json" | jq -c '[.dhcpOptions.dnsServers // [] | .[]]')

    # ── Subnets ──
    local subnets_json="[]"
    local subnet_count
    subnet_count=$(printf '%s' "$vnet_json" | jq '[.subnets // [] | .[]] | length')

    for (( s = 0; s < subnet_count; s++ )); do
        local subnet_raw
        subnet_raw=$(printf '%s' "$vnet_json" | jq -c ".subnets[$s]")

        local sid sname sprefix snsg snsg_name srt srt_name
        sid=$(printf '%s' "$subnet_raw" | jq -r '.id // empty')
        sname=$(printf '%s' "$subnet_raw" | jq -r '.name // empty')
        sprefix=$(printf '%s' "$subnet_raw" | jq -r '
            (.addressPrefix // (.addressPrefixes // [] | join(", ")) // "unknown")
            | if . == "" then "unknown" else . end')
        snsg=$(printf '%s' "$subnet_raw" | jq -r '.networkSecurityGroup.id // empty')
        srt=$(printf '%s' "$subnet_raw" | jq -r '.routeTable.id // empty')

        # Build subnet object
        local subnet_obj
        subnet_obj=$(jq -n \
            --arg id "$sid" \
            --arg name "$sname" \
            --arg prefix "$sprefix" \
            '{id: $id, name: $name, addressPrefix: $prefix, resources: []}')

        # Add NSG reference (object with id + name)
        if [[ -n "$snsg" ]]; then
            snsg_name=$(basename "$snsg")
            subnet_obj=$(printf '%s' "$subnet_obj" | jq --arg nsgId "$snsg" --arg nsgName "$snsg_name" '.nsg = {id: $nsgId, name: $nsgName}')
        fi

        # Add route table reference (object with id + name)
        if [[ -n "$srt" ]]; then
            srt_name=$(basename "$srt")
            subnet_obj=$(printf '%s' "$subnet_obj" | jq --arg rtId "$srt" --arg rtName "$srt_name" '.routeTable = {id: $rtId, name: $rtName}')
        fi

        # Subnet enrichment (FR-005 to FR-011)
        # Service endpoints — omit when empty
        local svc_eps
        svc_eps=$(printf '%s' "$subnet_raw" | jq -c '[(.serviceEndpoints // [])[] | {service: .service} + (if .provisioningState then {provisioningState: .provisioningState} else {} end)]')
        if [[ "$svc_eps" != "[]" ]]; then
            subnet_obj=$(printf '%s' "$subnet_obj" | jq --argjson eps "$svc_eps" '.serviceEndpoints = $eps')
        fi

        # Private endpoint network policies — omit when "Enabled" (default)
        local pe_policy
        pe_policy=$(printf '%s' "$subnet_raw" | jq -r '.privateEndpointNetworkPolicies // empty')
        if [[ -n "$pe_policy" ]] && [[ "$pe_policy" != "Enabled" ]]; then
            subnet_obj=$(printf '%s' "$subnet_obj" | jq --arg v "$pe_policy" '.privateEndpointNetworkPolicies = $v')
        fi

        # Private link service network policies — omit when "Enabled" (default)
        local pls_policy
        pls_policy=$(printf '%s' "$subnet_raw" | jq -r '.privateLinkServiceNetworkPolicies // empty')
        if [[ -n "$pls_policy" ]] && [[ "$pls_policy" != "Enabled" ]]; then
            subnet_obj=$(printf '%s' "$subnet_obj" | jq --arg v "$pls_policy" '.privateLinkServiceNetworkPolicies = $v')
        fi

        # Delegations — omit when empty
        local delegations
        delegations=$(printf '%s' "$subnet_raw" | jq -c '[(.delegations // [])[] | {serviceName: (.serviceName // .properties.serviceName // empty)}]')
        if [[ "$delegations" != "[]" ]]; then
            subnet_obj=$(printf '%s' "$subnet_obj" | jq --argjson d "$delegations" '.delegations = $d')
        fi

        subnets_json=$(printf '%s' "$subnets_json" | jq --argjson sub "$subnet_obj" '. + [$sub]')
    done

    # ── Resources per subnet (via Resource Graph) ──
    local sub_id
    sub_id=$(echo "$vnet_id" | sed -n 's|^/subscriptions/\([^/]*\)/.*|\1|p')

    log_substep "Querying subnet resources..."
    local res_query
    res_query="Resources
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
        | where properties.ipConfigurations[0].properties.subnet.id startswith '${vnet_id}'
            or properties.gatewayIPConfigurations[0].properties.subnet.id startswith '${vnet_id}'
            or properties.subnet.id startswith '${vnet_id}'
            or properties.ipConfigurations[0].subnet.id startswith '${vnet_id}'
            or properties.ipConfiguration.properties.subnet.id startswith '${vnet_id}'
        | project id, name, type, location, resourceGroup, subscriptionId, properties, tags
        | order by type asc, name asc"

    local res_data
    res_data=$(invoke_graph_query_paginated "Query resources for $vnet_name" "$res_query" "$sub_id" "vnet/$vnet_name/subnet-resources")
    local res_count
    res_count=$(printf '%s' "$res_data" | jq 'length')

    log_found "$res_count resource(s) found"

    # Also query VMs that have NICs in this VNet
    local vm_query
    vm_query="Resources
        | where type =~ 'microsoft.compute/virtualMachines'
        | where isnotnull(properties.networkProfile)
        | mv-expand nic = properties.networkProfile.networkInterfaces
        | project vmId=id, vmName=name, vmType=type, nicId=tolower(nic.id), location, resourceGroup, subscriptionId, tags"

    local vms_result
    vms_result=$(invoke_graph_query_paginated "Query VMs" "$vm_query" "$sub_id" "vnet/$vnet_name/vm-query" "vmId")
    # vms_result is already a JSON array from the paginated helper

    # Also query VMSS to resolve VMSS instance NICs → parent VMSS
    local vmss_query
    vmss_query="Resources
        | where type =~ 'microsoft.compute/virtualMachineScaleSets'
        | where isnotnull(properties.virtualMachineProfile.networkProfile)
        | mv-expand nicCfg = properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations
        | mv-expand ipCfg = nicCfg.properties.ipConfigurations
        | where ipCfg.properties.subnet.id startswith '${vnet_id}'
        | project vmssId=id, vmssName=name, location, resourceGroup, subscriptionId, tags, sku"

    local vmss_result
    vmss_result=$(invoke_graph_query_paginated "Query VMSS" "$vmss_query" "$sub_id" "vnet/$vnet_name/vmss-query" "vmssId")
    # vmss_result is already a JSON array from the paginated helper

    # Map resources to subnets
    for (( r = 0; r < res_count; r++ )); do
        local rjson
        rjson=$(printf '%s' "$res_data" | jq -c ".[$r]")

        local rid rname rtype rloc rtags rsubnet_id
        rid=$(printf '%s' "$rjson" | jq -r '.id')
        rname=$(printf '%s' "$rjson" | jq -r '.name')
        rtype=$(printf '%s' "$rjson" | jq -r '.type')
        rloc=$(printf '%s' "$rjson" | jq -r '.location // empty')
        rtags=$(printf '%s' "$rjson" | jq -c '.tags // {}')
        local rtype_lower
        rtype_lower=$(echo "$rtype" | tr '[:upper:]' '[:lower:]')

        # Resolve subnet ID from the resource properties
        rsubnet_id=""
        if [[ "$rtype_lower" == *"networkinterfaces"* ]]; then
            rsubnet_id=$(printf '%s' "$rjson" | jq -r '.properties.ipConfigurations[0].properties.subnet.id // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"applicationgateways"* ]]; then
            rsubnet_id=$(printf '%s' "$rjson" | jq -r '.properties.gatewayIPConfigurations[0].properties.subnet.id // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"privateendpoints"* ]]; then
            rsubnet_id=$(printf '%s' "$rjson" | jq -r '.properties.subnet.id // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"loadbalancers"* ]]; then
            rsubnet_id=$(printf '%s' "$rjson" | jq -r '[.properties.frontendIPConfigurations[] | .properties.subnet.id // empty] | first // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"azurefirewalls"* || "$rtype_lower" == *"virtualnetworkgateways"* || "$rtype_lower" == *"bastionhosts"* || "$rtype_lower" == *"natgateways"* || "$rtype_lower" == *"dnsresolvers"* ]]; then
            rsubnet_id=$(printf '%s' "$rjson" | jq -r '.properties.ipConfigurations[0].properties.subnet.id // empty' 2>/dev/null)
        fi

        [[ -z "$rsubnet_id" ]] && continue
        local subnet_name_for_res
        subnet_name_for_res=$(basename "$rsubnet_id")

        # Handle NICs → resolve to VM or VMSS
        if [[ "$rtype_lower" == *"networkinterfaces"* ]]; then
            local vm_id
            vm_id=$(printf '%s' "$rjson" | jq -r '.properties.virtualMachine.id // empty' 2>/dev/null)
            if [[ -n "$vm_id" && "$vm_id" != "null" ]]; then
                # Check if NIC belongs to a VMSS instance
                if [[ "$vm_id" =~ [Vv]irtual[Mm]achine[Ss]cale[Ss]ets/[^/]+/virtualMachines/ ]]; then
                    # Extract parent VMSS ARM ID (everything up to /virtualMachines/)
                    local vmss_id
                    vmss_id=$(echo "$vm_id" | sed -E 's|(/[Vv]irtual[Mm]achine[Ss]cale[Ss]ets/[^/]+)/virtualMachines/.*|\1|')
                    local vmss_id_lower
                    vmss_id_lower=$(echo "$vmss_id" | tr '[:upper:]' '[:lower:]')

                    local vmss_name vmss_sku vmss_tags_val
                    vmss_name=$(printf '%s' "$vmss_result" | jq -r --arg vid "$vmss_id_lower" \
                        '[.[] | select((.vmssId | ascii_downcase) == $vid)] | first | .vmssName // empty' 2>/dev/null)
                    [[ -z "$vmss_name" ]] && vmss_name=$(basename "$vmss_id")
                    vmss_sku=$(printf '%s' "$vmss_result" | jq -r --arg vid "$vmss_id_lower" \
                        '[.[] | select((.vmssId | ascii_downcase) == $vid)] | first | .sku.name // empty' 2>/dev/null)
                    vmss_tags_val=$(printf '%s' "$vmss_result" | jq -c --arg vid "$vmss_id_lower" \
                        '[.[] | select((.vmssId | ascii_downcase) == $vid)] | first | .tags // {}' 2>/dev/null || echo '{}')

                    local vmss_resource
                    vmss_resource=$(jq -n \
                        --arg id "$vmss_id" \
                        --arg name "$vmss_name" \
                        --arg subType "$vmss_sku" \
                        --arg loc "$rloc" \
                        --argjson tags "$vmss_tags_val" \
                        '{id: $id, name: $name, type: "Microsoft.Compute/virtualMachineScaleSets",
                          location: $loc, tags: $tags}
                         | if $subType != "" then .subType = $subType else . end')

                    subnets_json=$(printf '%s' "$subnets_json" | jq \
                        --arg sn "$subnet_name_for_res" --argjson res "$vmss_resource" \
                        '[.[] | if .name == $sn then .resources += [$res] | .resources |= unique_by(.id | ascii_downcase) else . end]')
                else
                    # Standalone VM NIC
                    local vm_name
                    vm_name=$(printf '%s' "$vms_result" | jq -r --arg nicId "$(echo "$rid" | tr '[:upper:]' '[:lower:]')" \
                        '.[] | select(.nicId == $nicId) | .vmName // empty' 2>/dev/null)
                    [[ -z "$vm_name" ]] && vm_name=$(basename "$vm_id")

                    local vm_tags
                    vm_tags=$(printf '%s' "$vms_result" | jq -c --arg nicId "$(echo "$rid" | tr '[:upper:]' '[:lower:]')" \
                        '.[] | select(.nicId == $nicId) | .tags // {}' 2>/dev/null || echo '{}')

                    local vm_resource
                    vm_resource=$(jq -n \
                        --arg id "$vm_id" \
                        --arg name "$vm_name" \
                        --arg loc "$rloc" \
                        --argjson tags "$vm_tags" \
                        '{id: $id, name: $name, type: "Microsoft.Compute/virtualMachines",
                          location: $loc, tags: $tags}')

                    subnets_json=$(printf '%s' "$subnets_json" | jq \
                        --arg sn "$subnet_name_for_res" --argjson res "$vm_resource" \
                        '[.[] | if .name == $sn then .resources += [$res] | .resources |= unique_by(.id) else . end]')
                fi
            fi
            continue
        fi

        # Determine subType for known resource types
        local sub_type=""
        if [[ "$rtype_lower" == *"virtualnetworkgateways"* ]]; then
            sub_type=$(printf '%s' "$rjson" | jq -r '.properties.gatewayType // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"applicationgateways"* ]]; then
            sub_type=$(printf '%s' "$rjson" | jq -r '.properties.sku.tier // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"privateendpoints"* ]]; then
            sub_type=$(printf '%s' "$rjson" | jq -r '[.properties.privateLinkServiceConnections // [] | .[] | .properties.groupIds // [] | .[]] | first // empty' 2>/dev/null)
        elif [[ "$rtype_lower" == *"loadbalancers"* ]]; then
            local has_pub_fe
            has_pub_fe=$(printf '%s' "$rjson" | jq '[.properties.frontendIPConfigurations[] | select(.properties.publicIPAddress != null)] | length' 2>/dev/null || echo "0")
            if (( has_pub_fe > 0 )); then
                sub_type="Public"
            else
                sub_type="Internal"
            fi
        elif [[ "$rtype_lower" == *"dnsresolvers"* ]]; then
            # Determine inbound vs outbound from subnet name heuristic
            if [[ "$subnet_name_for_res" == *"inbound"* ]]; then
                sub_type="Inbound"
            elif [[ "$subnet_name_for_res" == *"outbound"* ]]; then
                sub_type="Outbound"
            fi
        fi

        # Collect public IPs for gateways, firewalls, app gateways, bastions
        local public_ips="[]"
        if [[ "$rtype_lower" == *"virtualnetworkgateways"* || "$rtype_lower" == *"azurefirewalls"* || "$rtype_lower" == *"bastionhosts"* ]]; then
            local pip_ids
            pip_ids=$(printf '%s' "$rjson" | jq -r '[.properties.ipConfigurations // [] | .[] | .properties.publicIPAddress.id // empty] | .[]' 2>/dev/null)
            for pip_id in $pip_ids; do
                [[ -z "$pip_id" ]] && continue
                local pip_ip
                pip_ip=$(invoke_with_retry "Get PIP" --max-retries 1 az network public-ip show --ids "$pip_id" --query ipAddress -o tsv || echo "")
                if [[ -n "$pip_ip" ]]; then
                    public_ips=$(printf '%s' "$public_ips" | jq --arg ip "$pip_ip" '. + [$ip]')
                fi
            done
        elif [[ "$rtype_lower" == *"applicationgateways"* ]]; then
            local pip_ids
            pip_ids=$(printf '%s' "$rjson" | jq -r '[.properties.frontendIPConfigurations // [] | .[] | .properties.publicIPAddress.id // empty] | .[]' 2>/dev/null)
            for pip_id in $pip_ids; do
                [[ -z "$pip_id" ]] && continue
                local pip_ip
                pip_ip=$(invoke_with_retry "Get PIP" --max-retries 1 az network public-ip show --ids "$pip_id" --query ipAddress -o tsv || echo "")
                if [[ -n "$pip_ip" ]]; then
                    public_ips=$(printf '%s' "$public_ips" | jq --arg ip "$pip_ip" '. + [$ip]')
                fi
            done
        fi

        # Build resource object conforming to schema $defs/resource
        local res_obj
        res_obj=$(jq -n \
            --arg id "$rid" \
            --arg name "$rname" \
            --arg type "$rtype" \
            --arg subType "$sub_type" \
            --arg loc "$rloc" \
            --argjson publicIps "$public_ips" \
            --argjson tags "$rtags" \
            '{id: $id, name: $name, type: $type, location: $loc, tags: $tags}
             | if $subType != "" then .subType = $subType else . end
             | if ($publicIps | length) > 0 then .publicIps = $publicIps else . end')

        subnets_json=$(printf '%s' "$subnets_json" | jq \
            --arg sn "$subnet_name_for_res" --argjson res "$res_obj" \
            '[.[] | if .name == $sn then .resources += [$res] | .resources |= unique_by(.id) else . end]')
    done

    # ── VNet-injected / delegation-based resources ──
    # Discover resources that integrate via subnet delegation (App Service, APIM,
    # SQL MI, Container Apps Environments, Databricks, NetApp, etc.)
    log_substep "Querying VNet-injected resources (App Service, APIM, SQL MI, etc.)..."
    local deleg_query
    deleg_query="Resources
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
        | where properties.virtualNetworkSubnetId startswith '${vnet_id}'
            or properties.subnetId startswith '${vnet_id}'
            or properties.virtualNetworkConfiguration.subnetResourceId startswith '${vnet_id}'
            or properties.subnetIds[0].id startswith '${vnet_id}'
            or properties.vnetConfiguration.infrastructureSubnetId startswith '${vnet_id}'
            or properties.parameters.customVirtualNetworkId.value =~ '${vnet_id}'
            or properties.virtualNetworkConfiguration.subnetId startswith '${vnet_id}'
        | project id, name, type, location, resourceGroup, subscriptionId, properties, tags, kind
        | order by type asc, name asc"

    local deleg_data
    deleg_data=$(invoke_graph_query_paginated "Query VNet-injected resources for $vnet_name" "$deleg_query" "$sub_id" "vnet/$vnet_name/delegated-resources")
    local deleg_count
    deleg_count=$(printf '%s' "$deleg_data" | jq 'length')
    log_found "$deleg_count VNet-injected resource(s) found"

    for (( d = 0; d < deleg_count; d++ )); do
        local djson
        djson=$(printf '%s' "$deleg_data" | jq -c ".[$d]")

        local drid drname drtype drloc drtags drtype_lower
        drid=$(printf '%s' "$djson" | jq -r '.id')
        drname=$(printf '%s' "$djson" | jq -r '.name')
        drtype=$(printf '%s' "$djson" | jq -r '.type')
        drloc=$(printf '%s' "$djson" | jq -r '.location // empty')
        drtags=$(printf '%s' "$djson" | jq -c '.tags // {}')
        drtype_lower=$(echo "$drtype" | tr '[:upper:]' '[:lower:]')

        # Resolve subnet ID based on resource type
        local dsubnet_id=""
        if [[ "$drtype_lower" == *"microsoft.web/sites"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.virtualNetworkSubnetId // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"apimanagement"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.virtualNetworkConfiguration.subnetResourceId // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"managedinstances"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.subnetId // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"managedenvironments"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.vnetConfiguration.infrastructureSubnetId // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"containergroups"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.subnetIds[0].id // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"databricks"* ]]; then
            local dbricks_vnet
            dbricks_vnet=$(printf '%s' "$djson" | jq -r '.properties.parameters.customVirtualNetworkId.value // empty' 2>/dev/null)
            if [[ -n "$dbricks_vnet" ]]; then
                local dbricks_sub
                dbricks_sub=$(printf '%s' "$djson" | jq -r '(.properties.parameters.customPublicSubnetName.value // .properties.parameters.customPrivateSubnetName.value) // empty' 2>/dev/null)
                if [[ -n "$dbricks_sub" ]]; then
                    dsubnet_id="${dbricks_vnet}/subnets/${dbricks_sub}"
                fi
            fi
        elif [[ "$drtype_lower" == *"netapp"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.subnetId // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"kusto"* ]]; then
            dsubnet_id=$(printf '%s' "$djson" | jq -r '.properties.virtualNetworkConfiguration.subnetId // empty' 2>/dev/null)
        fi

        [[ -z "$dsubnet_id" ]] && continue
        local dsubnet_name
        dsubnet_name=$(basename "$dsubnet_id")

        # Determine subType
        local dsub_type=""
        if [[ "$drtype_lower" == *"microsoft.web/sites"* ]]; then
            local dkind
            dkind=$(printf '%s' "$djson" | jq -r '.kind // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [[ "$dkind" == *"functionapp"* ]]; then dsub_type="Function App"
            elif [[ "$dkind" == *"linux"* ]]; then dsub_type="Linux"
            else dsub_type="Windows"; fi
        elif [[ "$drtype_lower" == *"apimanagement"* ]]; then
            dsub_type=$(printf '%s' "$djson" | jq -r '.properties.sku.name // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"managedinstances"* ]]; then
            dsub_type=$(printf '%s' "$djson" | jq -r '.properties.sku.tier // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"managedenvironments"* ]]; then
            dsub_type="Container Apps"
        elif [[ "$drtype_lower" == *"databricks"* ]]; then
            dsub_type=$(printf '%s' "$djson" | jq -r '.sku.name // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"netapp"* ]]; then
            dsub_type=$(printf '%s' "$djson" | jq -r '.properties.serviceLevel // empty' 2>/dev/null)
        elif [[ "$drtype_lower" == *"kusto"* ]]; then
            dsub_type=$(printf '%s' "$djson" | jq -r '.properties.sku.name // empty' 2>/dev/null)
        fi

        # Build resource object
        local dres_obj
        dres_obj=$(jq -n \
            --arg id "$drid" \
            --arg name "$drname" \
            --arg type "$drtype" \
            --arg subType "$dsub_type" \
            --arg loc "$drloc" \
            --argjson tags "$drtags" \
            '{id: $id, name: $name, type: $type, location: $loc, tags: $tags}
             | if $subType != "" then .subType = $subType else . end')

        subnets_json=$(printf '%s' "$subnets_json" | jq \
            --arg sn "$dsubnet_name" --argjson res "$dres_obj" \
            '[.[] | if .name == $sn then .resources += [$res] | .resources |= unique_by(.id) else . end]')
    done

    # ── Peerings ──
    local peerings_json="[]"
    local peering_count
    peering_count=$(printf '%s' "$vnet_json" | jq '[.virtualNetworkPeerings // [] | .[]] | length')

    for (( p = 0; p < peering_count; p++ )); do
        local praw
        praw=$(printf '%s' "$vnet_json" | jq -c ".virtualNetworkPeerings[$p]")

        local pname premote pstate pforward ptransit premotegw
        pname=$(printf '%s' "$praw" | jq -r '.name // empty')
        premote=$(printf '%s' "$praw" | jq -r '.remoteVirtualNetwork.id // empty')
        pstate=$(printf '%s' "$praw" | jq -r '.peeringState // "Unknown"')
        pforward=$(printf '%s' "$praw" | jq -r '.allowForwardedTraffic // false')
        ptransit=$(printf '%s' "$praw" | jq -r '.allowGatewayTransit // false')
        premotegw=$(printf '%s' "$praw" | jq -r '.useRemoteGateways // false')

        peerings_json=$(printf '%s' "$peerings_json" | jq \
            --arg name "$pname" \
            --arg remoteVnetId "$premote" \
            --arg state "$pstate" \
            --argjson allowForwardedTraffic "$pforward" \
            --argjson allowGatewayTransit "$ptransit" \
            --argjson useRemoteGateways "$premotegw" \
            '. + [{name: $name, remoteVnetId: $remoteVnetId, state: $state,
                   allowForwardedTraffic: $allowForwardedTraffic,
                   allowGatewayTransit: $allowGatewayTransit,
                   useRemoteGateways: $useRemoteGateways}]')
    done

    # ── Build VNet object matching schema $defs/vnet ──
    local vnet_obj
    vnet_obj=$(jq -n \
        --arg id "$vnet_id" \
        --arg name "$vnet_name" \
        --argjson addressSpace "$address_prefixes" \
        --arg location "$location" \
        --arg resourceGroup "$rg" \
        --argjson subnets "$subnets_json" \
        --argjson peerings "$peerings_json" \
        '{id: $id, name: $name, addressSpace: $addressSpace,
          location: $location, resourceGroup: $resourceGroup,
          subnets: $subnets, peerings: $peerings}')

    # Add dnsServers only when custom DNS is configured (omit for Azure-provided)
    if [[ "$dns_servers" != "[]" ]]; then
        vnet_obj=$(printf '%s' "$vnet_obj" | jq --argjson dnsServers "$dns_servers" '. + {dnsServers: $dnsServers}')
    fi

    # Add tags when present (omit when empty)
    local vnet_tags
    vnet_tags=$(printf '%s' "$vnet_json" | jq -c '.tags // {}')
    if [[ "$vnet_tags" != "{}" && "$vnet_tags" != "null" ]]; then
        vnet_obj=$(printf '%s' "$vnet_obj" | jq --argjson tags "$vnet_tags" '. + {tags: $tags}')
    fi

    printf '%s' "$vnet_obj"
}

# ── vWAN Hub detection ───────────────────────────────────────────────────────
# Azure creates a managed VNet named HV_virtualHubVnet_<guid> inside
# RG_virtualHubVnet_<guid> for each Virtual Hub.  When a peering target
# matches that pattern we need to resolve to the actual
# Microsoft.Network/virtualHubs resource and use vHub-specific CLI commands.

is_vhub_vnet_id() {
    # Returns 0 (true) if the ARM id looks like a vWAN-managed VNet.
    # Azure creates these with pattern: HV_<name>_<guid> in RG_<name>_<guid>
    local id_lower
    id_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    local vnet_name
    vnet_name=$(basename "$id_lower")
    local rg_name
    rg_name=$(echo "$id_lower" | sed -n 's|^/subscriptions/[^/]*/resourcegroups/\([^/]*\)/.*|\1|p')
    # Both the VNet name and RG follow HV_/RG_ prefix for vHub managed networks
    [[ "$vnet_name" == hv_* ]] && [[ "$rg_name" == rg_* ]]
}

# Resolve a vHub-managed VNet ID to the actual Microsoft.Network/virtualHubs ID.
#
# Azure names these as:
#   VNet: HV_<hubName>_<guid>    in    RG: RG_<something>_<guid>
#
# Strategy:
#   1. Extract the hub name from the VNet name (middle segment of HV_<name>_<guid>)
#   2. Resource Graph query filtered by that hub name
#   3. Fallback: list all vHubs and match by name
resolve_vhub_id_from_vnet() {
    local vnet_id="$1"
    local sub_id
    sub_id=$(echo "$vnet_id" | sed -n 's|^/subscriptions/\([^/]*\)/.*|\1|p')

    # Extract probable hub name from VNet name: HV_<hubName>_<guid>
    # The GUID is the last 36 chars after the final underscore
    local vnet_basename
    vnet_basename=$(basename "$vnet_id")
    # Strip "HV_" prefix
    local without_prefix="${vnet_basename#HV_}"
    without_prefix="${without_prefix#hv_}"
    # Strip the trailing _<guid> (last 37 chars: underscore + 36-char UUID)
    local hub_name_guess=""
    if [[ "$without_prefix" =~ ^(.+)_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        hub_name_guess="${BASH_REMATCH[1]}"
    else
        # Fallback: use the whole middle part
        hub_name_guess="$without_prefix"
    fi
    log_substep "Resolving vHub '$hub_name_guess'..."

    # Approach 1: Resource Graph query filtered by name (scoped to same subscription)
    if [[ -n "$hub_name_guess" ]]; then
        local vhub_query="Resources | where type =~ 'microsoft.network/virtualhubs' and name =~ '$hub_name_guess' | project id, name"
        local vhub_graph
        vhub_graph=$(invoke_with_retry "Find vHub by name (same sub)" --max-retries 1 \
            az graph query -q "$vhub_query" --subscriptions "$sub_id" --output json --first 10 || echo '{"data":[]}')

        local match_id
        match_id=$(printf '%s' "$vhub_graph" | jq -r '.data[0].id // empty')
        if [[ -n "$match_id" ]]; then
            log_found "Resolved → $match_id"
            echo "$match_id"
            return 0
        fi

        # Approach 1b: vHub may live in a DIFFERENT subscription than its managed VNet
        log_substep "Not in local subscription — searching cross-subscription..."
        vhub_graph=$(invoke_with_retry "Find vHub by name (all subs)" --max-retries 1 \
            az graph query -q "$vhub_query" --output json --first 10 || echo '{"data":[]}')

        match_id=$(printf '%s' "$vhub_graph" | jq -r '.data[0].id // empty')
        if [[ -n "$match_id" ]]; then
            log_found "Resolved (cross-subscription) → $(basename "$match_id")"
            echo "$match_id"
            return 0
        fi
    fi

    # Approach 2: List all vHubs in the subscription, match by name
    local vhub_list
    vhub_list=$(invoke_with_retry "List vHubs" --max-retries 1 \
        az network vhub list --subscription "$sub_id" --output json || echo '[]')

    local list_count
    list_count=$(printf '%s' "$vhub_list" | jq 'length')

    for (( h = 0; h < list_count; h++ )); do
        local candidate_name candidate_id
        candidate_name=$(printf '%s' "$vhub_list" | jq -r ".[$h].name")
        candidate_id=$(printf '%s' "$vhub_list" | jq -r ".[$h].id")

        # Match by hub name (case-insensitive)
        local candidate_lower hub_guess_lower
        candidate_lower=$(echo "$candidate_name" | tr '[:upper:]' '[:lower:]')
        hub_guess_lower=$(echo "$hub_name_guess" | tr '[:upper:]' '[:lower:]')
        if [[ "$candidate_lower" == "$hub_guess_lower" ]]; then
            log_found "Resolved → $(basename "$candidate_id")"
            echo "$candidate_id"
            return 0
        fi
    done

    # Approach 3: If only one vHub exists in this sub, use it
    if (( list_count == 1 )); then
        local solo_id
        solo_id=$(printf '%s' "$vhub_list" | jq -r '.[0].id')
        log_found "Single vHub in subscription → $(basename "$solo_id")"
        echo "$solo_id"
        return 0
    fi

    log_substep "Could not resolve vHub from managed VNet"
    echo ""
    return 1
}

# Returns 0 (true) if the ARM id is a virtualHubs resource (not a managed VNet).
is_vhub_resource_id() {
    local id_lower
    id_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$id_lower" == */microsoft.network/virtualhubs/* ]]
}

# ── Discover a Virtual Hub ──────────────────────────────────────────────────
# Returns a VNet-compatible JSON object for the topology, with
# _isVirtualHub=true so the renderer can style it differently later.
# vHubs have no traditional subnets but contain:
#   - ER Gateways (Microsoft.Network/expressRouteGateways)
#   - VPN Gateways (Microsoft.Network/vpnGateways)
#   - Azure Firewall
#   - Hub Virtual Network Connections (peerings to spoke VNets)
discover_vhub() {
    local vhub_id="$1"        # The ARM ID of the microsoft.network/virtualHubs resource
    local original_vnet_id="$2"  # The HV_ VNet ID that led us here

    local sub_id
    sub_id=$(echo "$vhub_id" | sed -n 's|^/subscriptions/\([^/]*\)/.*|\1|p')

    log_detail "Hub resource: $(basename "$vhub_id")"

    # ── Get vHub details ──
    local vhub_json
    vhub_json=$(invoke_with_retry "Get vHub" --max-retries 1 --error-scope "vhub/$(basename "$vhub_id")" \
        az network vhub show --ids "$vhub_id" --output json || echo '{}')

    local vhub_name location rg address_prefix vwan_id
    vhub_name=$(printf '%s' "$vhub_json" | jq -r '.name // empty')
    [[ -z "$vhub_name" ]] && vhub_name=$(basename "$vhub_id")
    location=$(printf '%s' "$vhub_json" | jq -r '.location // "unknown"')
    rg=$(printf '%s' "$vhub_json" | jq -r '.resourceGroup // "unknown"')
    address_prefix=$(printf '%s' "$vhub_json" | jq -r '.addressPrefix // ""')
    vwan_id=$(printf '%s' "$vhub_json" | jq -r '.virtualWan.id // ""')

    # ── Extract hub-level properties ──
    local hub_routing_pref allow_b2b routing_state hub_sku hub_asn
    hub_routing_pref=$(printf '%s' "$vhub_json" | jq -r '.hubRoutingPreference // "ExpressRoute"')
    allow_b2b=$(printf '%s' "$vhub_json" | jq -r '.allowBranchToBranchTraffic // false')
    routing_state=$(printf '%s' "$vhub_json" | jq -r '.routingState // "Unknown"')
    hub_sku=$(printf '%s' "$vhub_json" | jq -r '.sku // "Basic"')
    hub_asn=$(printf '%s' "$vhub_json" | jq -r '.virtualRouterAsn // 0')
    local hub_router_ips
    hub_router_ips=$(printf '%s' "$vhub_json" | jq -c '[.virtualRouterIps // [] | .[]]')

    # Build address space array
    local address_space="[]"
    if [[ -n "$address_prefix" ]]; then
        address_space=$(jq -n --arg p "$address_prefix" '[$p]')
    fi

    # ── Discover resources inside the vHub ──
    # Represented as a single "hub-resources" pseudo-subnet
    local hub_resources="[]"

    # ── 1. ExpressRoute Gateways ──
    log_substep "Checking ER gateways..."
    local er_gw_json
    er_gw_json=$(invoke_with_retry "List vHub ER GWs" --max-retries 1 \
        az network express-route gateway list --subscription "$sub_id" --resource-group "$rg" --output json || echo '[]')
    # az network express-route gateway list may return {"value":[...]} instead of a bare array
    er_gw_json=$(printf '%s' "$er_gw_json" | jq 'if type == "object" and has("value") then .value else . end')
    local er_gw_count
    er_gw_count=$(printf '%s' "$er_gw_json" | jq 'length')
    for (( i = 0; i < er_gw_count; i++ )); do
        local gw
        gw=$(printf '%s' "$er_gw_json" | jq -c ".[$i]")
        # Skip gateways that belong to a different vHub in the same RG
        local gw_vhub_id
        gw_vhub_id=$(printf '%s' "$gw" | jq -r '.virtualHub.id // empty')
        if [[ -n "$gw_vhub_id" ]] && [[ "${gw_vhub_id,,}" != "${vhub_id,,}" ]]; then
            continue
        fi
        local gw_id gw_name gw_loc gw_scale
        gw_id=$(printf '%s' "$gw" | jq -r '.id')
        gw_name=$(printf '%s' "$gw" | jq -r '.name')
        gw_loc=$(printf '%s' "$gw" | jq -r '.location // ""')
        gw_scale=$(printf '%s' "$gw" | jq -r '.autoScaleConfiguration.bounds.min // 1')
        hub_resources=$(printf '%s' "$hub_resources" | jq \
            --arg id "$gw_id" --arg name "$gw_name" --arg loc "$gw_loc" --arg scale "$gw_scale" \
            '. + [{id: $id, name: $name, type: "Microsoft.Network/expressRouteGateways",
                   subType: "ExpressRoute", location: $loc,
                   tags: {"x-aed-solution": "core-networking"},
                   metadata: {scaleUnits: ($scale | tonumber)}}]')

        # ── ER Gateway Connections → ER Circuits ──
        local er_conns
        er_conns=$(invoke_with_retry "List ER GW connections" --max-retries 1 \
            az network express-route gateway connection list \
                --gateway-name "$gw_name" --subscription "$sub_id" --resource-group "$rg" \
                --output json || echo '[]')
        er_conns=$(printf '%s' "$er_conns" | jq 'if type == "object" and has("value") then .value else . end')
        local er_conn_count
        er_conn_count=$(printf '%s' "$er_conns" | jq 'length')
        for (( c = 0; c < er_conn_count; c++ )); do
            local circuit_peering_id
            circuit_peering_id=$(printf '%s' "$er_conns" | jq -r ".[$c].expressRouteCircuitPeering | if type == \"string\" then . elif type == \"object\" then .id // empty else empty end" 2>/dev/null)
            if [[ -n "$circuit_peering_id" ]]; then
                local circuit_arm_id
                circuit_arm_id=$(echo "$circuit_peering_id" | sed 's|/peerings/.*$||')
                local circuit_json
                circuit_json=$(invoke_with_retry "Get ER circuit" --max-retries 1 \
                    az network express-route show --ids "$circuit_arm_id" --output json || echo '{}')
                local circuit_name
                circuit_name=$(printf '%s' "$circuit_json" | jq -r '.name // empty')
                if [[ -n "$circuit_name" ]]; then
                    ER_CIRCUITS+=("$(printf '%s' "$circuit_json" | jq '{
                        id: .id, name: .name, location: .location,
                        serviceProviderName: (.serviceProviderProperties.serviceProviderName // "Unknown"),
                        peeringLocation: (.serviceProviderProperties.peeringLocation // "Unknown"),
                        bandwidthInMbps: (.serviceProviderProperties.bandwidthInMbps // 0),
                        skuTier: (.sku.tier // "Standard"),
                        skuFamily: (.sku.family // "MeteredData"),
                        circuitProvisioningState: (.circuitProvisioningState // "Unknown"),
                        serviceProviderProvisioningState: (.serviceProviderProvisioningState // "Unknown")
                    } + (if (.peerings // [] | length) > 0 then
                        {peerings: [.peerings[] | {peeringType, state, vlanId, primaryPeerAddressPrefix, secondaryPeerAddressPrefix, peerASN}
                            + (if .microsoftPeeringConfig.advertisedPublicPrefixes then {advertisedPublicPrefixes: .microsoftPeeringConfig.advertisedPublicPrefixes, advertisedPublicPrefixesState: .microsoftPeeringConfig.advertisedPublicPrefixesState} else {} end)
                            | del(.[] | nulls)]}
                      else {} end)')") 
                fi
            fi
        done
    done

    # ── 2. S2S VPN Gateways + their connections → VPN Sites ──
    log_substep "Checking S2S VPN gateways..."
    local vpn_gw_json
    vpn_gw_json=$(invoke_with_retry "List vHub VPN GWs" --max-retries 1 \
        az network vpn-gateway list --subscription "$sub_id" --resource-group "$rg" --output json || echo '[]')
    vpn_gw_json=$(printf '%s' "$vpn_gw_json" | jq 'if type == "object" and has("value") then .value else . end')
    local vpn_gw_count
    vpn_gw_count=$(printf '%s' "$vpn_gw_json" | jq 'length')
    for (( i = 0; i < vpn_gw_count; i++ )); do
        local gw
        gw=$(printf '%s' "$vpn_gw_json" | jq -c ".[$i]")
        # Skip gateways that belong to a different vHub in the same RG
        local gw_vhub_id
        gw_vhub_id=$(printf '%s' "$gw" | jq -r '.virtualHub.id // empty')
        if [[ -n "$gw_vhub_id" ]] && [[ "${gw_vhub_id,,}" != "${vhub_id,,}" ]]; then
            continue
        fi
        local gw_id gw_name gw_loc gw_scale
        gw_id=$(printf '%s' "$gw" | jq -r '.id')
        gw_name=$(printf '%s' "$gw" | jq -r '.name')
        gw_loc=$(printf '%s' "$gw" | jq -r '.location // ""')
        gw_scale=$(printf '%s' "$gw" | jq -r '.vpnGatewayScaleUnit // 1')

        # Get S2S connections for this VPN gateway
        local s2s_conn_count=0
        local s2s_site_names="[]"
        local vpn_conns
        vpn_conns=$(invoke_with_retry "List VPN GW connections" --max-retries 1 \
            az network vpn-gateway connection list \
                --gateway-name "$gw_name" --subscription "$sub_id" --resource-group "$rg" \
                --output json || echo '[]')
        vpn_conns=$(printf '%s' "$vpn_conns" | jq 'if type == "object" and has("value") then .value else . end')
        s2s_conn_count=$(printf '%s' "$vpn_conns" | jq 'length')

        if (( s2s_conn_count > 0 )); then
            s2s_site_names=$(printf '%s' "$vpn_conns" | jq '[.[].name]')
            log_found "$s2s_conn_count S2S VPN connection(s)"

            # Collect linked VPN sites
            for (( sc = 0; sc < s2s_conn_count; sc++ )); do
                local vpn_site_links
                vpn_site_links=$(printf '%s' "$vpn_conns" | jq -r ".[$sc].vpnLinkConnections[]?.vpnSiteLink.id // empty" 2>/dev/null)
                while IFS= read -r site_link_id; do
                    [[ -z "$site_link_id" ]] && continue
                    # Strip /vpnSiteLinks/... to get the site ID
                    local vpn_site_id
                    vpn_site_id=$(echo "$site_link_id" | sed 's|/vpnSiteLinks/.*$||')
                    local site_json
                    site_json=$(invoke_with_retry "Get VPN site" --max-retries 1 \
                        az network vpn-site show --ids "$vpn_site_id" --output json || echo '{}')
                    local site_name
                    site_name=$(printf '%s' "$site_json" | jq -r '.name // empty')
                    if [[ -n "$site_name" ]]; then
                        local lng_obj
                        lng_obj=$(printf '%s' "$site_json" | jq '{
                            id: .id, name: .name, location: .location,
                            gatewayIpAddress: (.ipAddress // .vpnSiteLinks[0].ipAddress // ""),
                            localAddressSpace: [(.addressSpace.addressPrefixes // [])[]],
                            deviceVendor: (.deviceProperties.deviceVendor // ""),
                            deviceModel: (.deviceProperties.deviceModel // ""),
                            linkSpeedInMbps: (.deviceProperties.linkSpeedInMbps // 0)
                        }')
                        LNGS+=("$lng_obj")
                    fi
                done <<< "$vpn_site_links"
            done
        fi

        hub_resources=$(printf '%s' "$hub_resources" | jq \
            --arg id "$gw_id" --arg name "$gw_name" --arg loc "$gw_loc" \
            --argjson scale "$gw_scale" --argjson connCount "$s2s_conn_count" \
            --argjson siteNames "$s2s_site_names" \
            '. + [{id: $id, name: $name, type: "Microsoft.Network/vpnGateways",
                   subType: "Vpn", location: $loc,
                   tags: {"x-aed-solution": "core-networking"},
                   metadata: {scaleUnits: $scale, s2sConnectionCount: $connCount,
                              connectedSites: $siteNames}}]')
    done

    # ── 3. P2S VPN Gateways ──
    log_substep "Checking P2S VPN gateways..."
    local p2s_gw_json
    p2s_gw_json=$(invoke_with_retry "List P2S VPN GWs" --max-retries 1 \
        az network p2s-vpn-gateway list --subscription "$sub_id" --resource-group "$rg" --output json || echo '[]')
    p2s_gw_json=$(printf '%s' "$p2s_gw_json" | jq 'if type == "object" and has("value") then .value else . end')
    local p2s_gw_count
    p2s_gw_count=$(printf '%s' "$p2s_gw_json" | jq 'length')
    for (( i = 0; i < p2s_gw_count; i++ )); do
        local gw
        gw=$(printf '%s' "$p2s_gw_json" | jq -c ".[$i]")
        # Skip gateways that belong to a different vHub in the same RG
        local gw_vhub_id
        gw_vhub_id=$(printf '%s' "$gw" | jq -r '.virtualHub.id // empty')
        if [[ -n "$gw_vhub_id" ]] && [[ "${gw_vhub_id,,}" != "${vhub_id,,}" ]]; then
            continue
        fi
        local gw_id gw_name gw_loc gw_scale p2s_config_name
        gw_id=$(printf '%s' "$gw" | jq -r '.id')
        gw_name=$(printf '%s' "$gw" | jq -r '.name')
        gw_loc=$(printf '%s' "$gw" | jq -r '.location // ""')
        gw_scale=$(printf '%s' "$gw" | jq -r '.vpnGatewayScaleUnit // 1')
        p2s_config_name=$(printf '%s' "$gw" | jq -r '.vpnServerConfiguration.id // "" | split("/") | last')
        local p2s_client_pool
        p2s_client_pool=$(printf '%s' "$gw" | jq -c '[.vpnClientAddressPool.addressPrefixes // [] | .[]]')

        hub_resources=$(printf '%s' "$hub_resources" | jq \
            --arg id "$gw_id" --arg name "$gw_name" --arg loc "$gw_loc" \
            --argjson scale "$gw_scale" --arg configName "$p2s_config_name" \
            --argjson clientPool "$p2s_client_pool" \
            '. + [{id: $id, name: $name, type: "Microsoft.Network/p2sVpnGateways",
                   subType: "P2S", location: $loc,
                   tags: {"x-aed-solution": "core-networking"},
                   metadata: {scaleUnits: $scale, vpnServerConfig: $configName,
                              clientAddressPool: $clientPool}}]')
    done

    # ── 4. Azure Firewall ──
    log_substep "Checking Azure Firewall..."
    local fw_id
    fw_id=$(printf '%s' "$vhub_json" | jq -r '.azureFirewall.id // empty')
    if [[ -n "$fw_id" ]]; then
        local fw_json
        fw_json=$(invoke_with_retry "Get vHub Firewall" --max-retries 1 \
            az network firewall show --ids "$fw_id" --output json || echo '{}')
        local fw_name fw_loc fw_sku fw_tier fw_policy
        fw_name=$(printf '%s' "$fw_json" | jq -r '.name // empty')
        [[ -z "$fw_name" ]] && fw_name=$(basename "$fw_id")
        fw_loc=$(printf '%s' "$fw_json" | jq -r '.location // ""')
        fw_sku=$(printf '%s' "$fw_json" | jq -r '.sku.name // "AZFW_Hub"')
        fw_tier=$(printf '%s' "$fw_json" | jq -r '.sku.tier // "Standard"')
        fw_policy=$(printf '%s' "$fw_json" | jq -r '.firewallPolicy.id // ""')
        hub_resources=$(printf '%s' "$hub_resources" | jq \
            --arg id "$fw_id" --arg name "$fw_name" --arg loc "$fw_loc" \
            --arg sku "$fw_sku" --arg tier "$fw_tier" --arg policy "$fw_policy" \
            '. + [{id: $id, name: $name, type: "Microsoft.Network/azureFirewalls",
                   subType: "vHub", location: $loc,
                   tags: {"x-aed-solution": "core-networking"},
                   metadata: {sku: $sku, tier: $tier, firewallPolicyId: $policy}}]')
    fi

    # ── 5. BGP Connections (NVAs) ──
    log_substep "Checking BGP connections (NVAs)..."
    local bgp_conns
    bgp_conns=$(invoke_with_retry "List BGP connections" --max-retries 1 \
        az network vhub bgpconnection list \
            --vhub-name "$vhub_name" --subscription "$sub_id" --resource-group "$rg" \
            --output json || echo '[]')
    local bgp_count
    bgp_count=$(printf '%s' "$bgp_conns" | jq 'length')
    for (( i = 0; i < bgp_count; i++ )); do
        local bgp
        bgp=$(printf '%s' "$bgp_conns" | jq -c ".[$i]")
        local bgp_id bgp_name bgp_peer_ip bgp_peer_asn bgp_state
        bgp_id=$(printf '%s' "$bgp" | jq -r '.id')
        bgp_name=$(printf '%s' "$bgp" | jq -r '.name')
        bgp_peer_ip=$(printf '%s' "$bgp" | jq -r '.peerIp // ""')
        bgp_peer_asn=$(printf '%s' "$bgp" | jq -r '.peerAsn // 0')
        bgp_state=$(printf '%s' "$bgp" | jq -r '.connectionState // "Unknown"')
        hub_resources=$(printf '%s' "$hub_resources" | jq \
            --arg id "$bgp_id" --arg name "$bgp_name" --arg peerIp "$bgp_peer_ip" \
            --argjson peerAsn "$bgp_peer_asn" --arg state "$bgp_state" \
            '. + [{id: $id, name: $name, type: "Microsoft.Network/virtualHubs/bgpConnections",
                   subType: "NVA-BGP", location: "",
                   tags: {"x-aed-solution": "core-networking"},
                   metadata: {peerIp: $peerIp, peerAsn: $peerAsn, connectionState: $state}}]')
    done

    # ── 6. Routing Intent ──
    log_substep "Checking routing intent..."
    local routing_intent_json="null"
    local ri_list
    ri_list=$(invoke_with_retry "List routing intents" --max-retries 1 \
        az network vhub routing-intent list \
            --vhub-name "$vhub_name" --subscription "$sub_id" --resource-group "$rg" \
            --output json || echo '[]')
    local ri_count
    ri_count=$(printf '%s' "$ri_list" | jq 'length')
    if (( ri_count > 0 )); then
        routing_intent_json=$(printf '%s' "$ri_list" | jq '[.[] | {
            name: .name,
            provisioningState: .provisioningState,
            routingPolicies: [.routingPolicies[]? | {
                name: .name,
                destinations: .destinations,
                nextHop: .nextHop
            }]
        }]')
    fi

    # ── 7. Route Tables ──
    log_substep "Checking route tables..."
    local route_tables_json="[]"
    local rt_list
    rt_list=$(invoke_with_retry "List hub route tables" --max-retries 1 \
        az network vhub route-table list \
            --vhub-name "$vhub_name" --subscription "$sub_id" --resource-group "$rg" \
            --output json || echo '[]')
    local rt_count
    rt_count=$(printf '%s' "$rt_list" | jq 'length')
    if (( rt_count > 0 )); then
        route_tables_json=$(printf '%s' "$rt_list" | jq '[.[] | {
            id: .id, name: .name,
            provisioningState: .provisioningState,
            labels: [.labels[]?],
            routes: [.routes[]? | {name: .name, destinationType: .destinationType,
                     destinations: .destinations, nextHopType: .nextHopType, nextHop: .nextHop}]
        }]')
    fi

    # ── Build the pseudo-subnet for hub resources ──
    local subnets_json="[]"
    local res_count
    res_count=$(printf '%s' "$hub_resources" | jq 'length')
    if (( res_count > 0 )); then
        subnets_json=$(jq -n \
            --arg prefix "$address_prefix" \
            --argjson resources "$hub_resources" \
            '[{id: "hub-resources", name: "Hub Resources", addressPrefix: $prefix, resources: $resources}]')
    fi

    # ── 8. Hub VNet Connections (spoke peerings) ──
    log_substep "Checking spoke connections..."
    local peerings_json="[]"
    local hub_conns
    hub_conns=$(invoke_with_retry "List vHub connections" --max-retries 1 \
        az network vhub connection list \
            --vhub-name "$vhub_name" --subscription "$sub_id" --resource-group "$rg" \
            --output json || echo '[]')

    local conn_count
    conn_count=$(printf '%s' "$hub_conns" | jq 'length')
    log_found "$conn_count spoke connection(s) found"

    for (( i = 0; i < conn_count; i++ )); do
        local conn
        conn=$(printf '%s' "$hub_conns" | jq -c ".[$i]")

        local conn_name remote_vnet_id conn_status
        conn_name=$(printf '%s' "$conn" | jq -r '.name // empty')
        remote_vnet_id=$(printf '%s' "$conn" | jq -r '.remoteVirtualNetwork.id // empty')
        conn_status=$(printf '%s' "$conn" | jq -r '.provisioningState // "Unknown"')

        [[ -z "$remote_vnet_id" ]] && continue

        # Extract rich connection properties
        local allow_hub_transit allow_remote_gw internet_security
        allow_hub_transit=$(printf '%s' "$conn" | jq -r '.allowHubToRemoteVnetTransit // false')
        allow_remote_gw=$(printf '%s' "$conn" | jq -r '.allowRemoteVnetToUseHubVnetGateways // false')
        internet_security=$(printf '%s' "$conn" | jq -r '.enableInternetSecurity // false')

        # Routing configuration
        local assoc_rt prop_labels
        assoc_rt=$(printf '%s' "$conn" | jq -r '.routingConfiguration.associatedRouteTable.id // "" | split("/") | last')
        prop_labels=$(printf '%s' "$conn" | jq -c '[.routingConfiguration.propagatedRouteTables.labels // [] | .[]]')
        local static_routes
        static_routes=$(printf '%s' "$conn" | jq -c '[.routingConfiguration.vnetRoutes.staticRoutes // [] | .[] | {name, addressPrefixes, nextHopIpAddress}]')

        peerings_json=$(printf '%s' "$peerings_json" | jq \
            --arg name "$conn_name" \
            --arg remoteVnetId "$remote_vnet_id" \
            --arg state "$conn_status" \
            --argjson allowHubTransit "$allow_hub_transit" \
            --argjson allowRemoteGw "$allow_remote_gw" \
            --argjson internetSecurity "$internet_security" \
            --arg assocRouteTable "$assoc_rt" \
            --argjson propLabels "$prop_labels" \
            --argjson staticRoutes "$static_routes" \
            '. + [{name: $name, remoteVnetId: $remoteVnetId, state: $state,
                   allowForwardedTraffic: $allowHubTransit,
                   allowGatewayTransit: $allowRemoteGw,
                   useRemoteGateways: false,
                   _hubConnectionMetadata: {
                       enableInternetSecurity: $internetSecurity,
                       associatedRouteTable: $assocRouteTable,
                       propagatedLabels: $propLabels,
                       staticRoutes: $staticRoutes
                   }}]')
    done

    # ── 9. Inter-hub peerings (via vWAN sibling hubs) ──
    local interhub_peers="[]"
    if [[ -n "$vwan_id" ]]; then
        log_substep "Checking vWAN inter-hub links..."
        local vwan_json
        vwan_json=$(invoke_with_retry "Get vWAN" --max-retries 1 \
            az network vwan show --ids "$vwan_id" --output json || echo '{}')

        local sibling_hub_ids
        sibling_hub_ids=$(printf '%s' "$vwan_json" | jq -r '.virtualHubs[]?.id // empty' 2>/dev/null)

        while IFS= read -r sibling_id; do
            [[ -z "$sibling_id" ]] && continue
            # Skip self
            local sibling_lower vhub_lower
            sibling_lower=$(echo "$sibling_id" | tr '[:upper:]' '[:lower:]')
            vhub_lower=$(echo "$vhub_id" | tr '[:upper:]' '[:lower:]')
            [[ "$sibling_lower" == "$vhub_lower" ]] && continue

            local sibling_name
            sibling_name=$(basename "$sibling_id")
            log_found "Sibling hub: $sibling_name"

            interhub_peers=$(printf '%s' "$interhub_peers" | jq \
                --arg id "$sibling_id" --arg name "$sibling_name" \
                '. + [{hubId: $id, hubName: $name}]')

            # Add sibling hub's vHub ARM ID as a peering so BFS discovers it directly
            peerings_json=$(printf '%s' "$peerings_json" | jq \
                --arg name "interhub-$sibling_name" \
                --arg remoteVnetId "$sibling_id" \
                '. + [{name: $name, remoteVnetId: $remoteVnetId, state: "Connected",
                       allowForwardedTraffic: true, allowGatewayTransit: true,
                       useRemoteGateways: false, _isInterHubPeering: true}]')
            log_found "Linked → $sibling_name"
        done <<< "$sibling_hub_ids"

        # Extract vWAN-level settings
        local vwan_b2b vwan_vnet2vnet vwan_vpn_encryption
        vwan_b2b=$(printf '%s' "$vwan_json" | jq -r '.allowBranchToBranchTraffic // false')
        vwan_vnet2vnet=$(printf '%s' "$vwan_json" | jq -r '.allowVnetToVnetTraffic // null')
        vwan_vpn_encryption=$(printf '%s' "$vwan_json" | jq -r '.disableVpnEncryption // false')
    fi

    # Use the original HV_ VNet ID so peering connections still match
    local output_id="$original_vnet_id"

    # ── Build the VNet-compatible object ──
    local result
    result=$(jq -n \
        --arg id "$output_id" \
        --arg name "$vhub_name" \
        --argjson addressSpace "$address_space" \
        --arg location "$location" \
        --arg resourceGroup "$rg" \
        --argjson subnets "$subnets_json" \
        --argjson peerings "$peerings_json" \
        --arg vhubId "$vhub_id" \
        --arg vwanId "$vwan_id" \
        --arg hubRoutingPreference "$hub_routing_pref" \
        --argjson allowBranchToBranch "$allow_b2b" \
        --arg routingState "$routing_state" \
        --arg hubSku "$hub_sku" \
        --argjson hubAsn "$hub_asn" \
        --argjson hubRouterIps "$hub_router_ips" \
        --argjson routingIntent "$routing_intent_json" \
        --argjson routeTables "$route_tables_json" \
        --argjson interhubPeers "$interhub_peers" \
        '{id: $id, name: $name, addressSpace: $addressSpace,
          location: $location, resourceGroup: $resourceGroup,
          subnets: $subnets, peerings: $peerings,
          _isVirtualHub: true, _vhubResourceId: $vhubId,
          _hubConfig: {
              sku: $hubSku,
              routingPreference: $hubRoutingPreference,
              routingState: $routingState,
              allowBranchToBranchTraffic: $allowBranchToBranch,
              virtualRouterAsn: $hubAsn,
              virtualRouterIps: $hubRouterIps
          }}
         | if $vwanId != "" then ._vwanId = $vwanId else . end
         | if ($routingIntent != null) then ._hubConfig.routingIntent = $routingIntent else . end
         | if ($routeTables | length) > 0 then ._hubConfig.routeTables = $routeTables else . end
         | if ($interhubPeers | length) > 0 then ._hubConfig.interhubPeers = $interhubPeers else . end')

    # Add tags when present (omit when empty)
    local vhub_tags
    vhub_tags=$(printf '%s' "$vhub_json" | jq -c '.tags // {}')
    if [[ "$vhub_tags" != "{}" && "$vhub_tags" != "null" ]]; then
        result=$(printf '%s' "$result" | jq --argjson tags "$vhub_tags" '. + {tags: $tags}')
    fi

    printf '%s' "$result"
}

# Synthesise on-premises site entries from ER circuit private peerings.
# Each AzurePrivatePeering with a peerASN produces one on-prem site keyed
# by (circuitId, peerASN). Falls back to one site per circuit when no ASN exists.
# Input:  $1 = er_circuits JSON array
# Output: JSON array of on-prem site objects (stdout)
synthesize_on_premises() {
    local er_circuits_json="$1"
    jq -c '
      reduce .[] as $circuit ([];
        ($circuit.id // "") as $cid |
        ($circuit.serviceProviderName // "") as $provider |
        ($circuit.peeringLocation // $circuit.location // "") as $peeringLoc |
        ($circuit.peerings // []) as $peerings |
        ([ $peerings[] | select((.peeringType // "" | ascii_downcase) == "azureprivatepeering" and .peerASN != null) ]) as $privPeerings |
        if ($privPeerings | length) > 0 then
          reduce $privPeerings[] as $p (.;
            ($p.peerASN | tostring) as $asnStr |
            (($peeringLoc | ascii_downcase | gsub(" "; "-")) // "unknown") as $locSlug |
            ("onprem-asn-" + $asnStr + "-" + $locSlug) as $siteId |
            ("ASN " + $asnStr
              + (if $peeringLoc != "" then " – " + $peeringLoc else "" end)
              + (if $provider != "" and $provider != "Unknown" then " (" + $provider + ")" else "" end)
            ) as $name |
            if (map(.id) | index($siteId)) then .
            else . + [{
              id: $siteId,
              name: $name,
              location: $peeringLoc,
              circuitId: $cid,
              peerASN: $p.peerASN
            } + (if $provider != "" and $provider != "Unknown" then {serviceProviderName: $provider} else {} end)]
            end
          )
        else
          (($peeringLoc | ascii_downcase | gsub(" "; "-")) // "unknown") as $locSlug |
          ("onprem-circuit-" + $locSlug + "-" + ($circuit.name // "unknown")) as $siteId |
          (($peeringLoc // $circuit.name // "On-Premises")
            + (if $provider != "" and $provider != "Unknown" then " (" + $provider + ")" else "" end)
          ) as $name |
          if (map(.id) | index($siteId)) then .
          else . + [{
            id: $siteId,
            name: $name,
            location: $peeringLoc,
            circuitId: $cid
          } + (if $provider != "" and $provider != "Unknown" then {serviceProviderName: $provider} else {} end)]
          end
        end
      )
    ' <<< "$er_circuits_json"
}

# Discover ExpressRoute circuits, local network gateways, and gateway connections for a VNet
discover_external_connectivity() {
    local vnet_id="$1"
    local sub_id
    sub_id=$(echo "$vnet_id" | sed -n 's|^/subscriptions/\([^/]*\)/.*|\1|p')
    local rg
    rg=$(echo "$vnet_id" | sed -n 's|^/subscriptions/[^/]*/resourceGroups/\([^/]*\)/.*|\1|p')
    local vnet_name
    vnet_name=$(basename "$vnet_id")

    # ── ExpressRoute circuits in this RG ──
    local er_json
    er_json=$(invoke_with_retry "List ER circuits" --max-retries 1 --error-scope "vnet/$vnet_name/er-circuits" \
        az network express-route list --subscription "$sub_id" --resource-group "$rg" --output json || echo '[]')

    local er_count
    er_count=$(printf '%s' "$er_json" | jq 'length')
    for (( i = 0; i < er_count; i++ )); do
        local circuit
        circuit=$(printf '%s' "$er_json" | jq -c ".[$i]")
        local cid cname cloc
        cid=$(printf '%s' "$circuit" | jq -r '.id')
        cname=$(printf '%s' "$circuit" | jq -r '.name')
        cloc=$(printf '%s' "$circuit" | jq -r '.location')

        ER_CIRCUITS+=("$(printf '%s' "$circuit" | jq '{
            id: .id,
            name: .name,
            location: .location,
            serviceProviderName: (.serviceProviderProperties.serviceProviderName // "Unknown"),
            peeringLocation: (.serviceProviderProperties.peeringLocation // "Unknown"),
            bandwidthInMbps: (.serviceProviderProperties.bandwidthInMbps // 0),
            skuTier: (.sku.tier // "Standard"),
            skuFamily: (.sku.family // "MeteredData"),
            circuitProvisioningState: (.circuitProvisioningState // "Unknown"),
            serviceProviderProvisioningState: (.serviceProviderProvisioningState // "Unknown")
        } + (if (.peerings // [] | length) > 0 then
            {peerings: [.peerings[] | {peeringType, state, vlanId, primaryPeerAddressPrefix, secondaryPeerAddressPrefix, peerASN}
                + (if .microsoftPeeringConfig.advertisedPublicPrefixes then {advertisedPublicPrefixes: .microsoftPeeringConfig.advertisedPublicPrefixes, advertisedPublicPrefixesState: .microsoftPeeringConfig.advertisedPublicPrefixesState} else {} end)
                | del(.[] | nulls)]}
          else {} end)')") 
    done

    # ── Local Network Gateways in this RG ──
    local lng_json
    lng_json=$(invoke_with_retry "List LNGs" --max-retries 1 --error-scope "vnet/$vnet_name/lngs" \
        az network local-gateway list --subscription "$sub_id" --resource-group "$rg" --output json || echo '[]')

    local lng_count
    lng_count=$(printf '%s' "$lng_json" | jq 'length')
    for (( i = 0; i < lng_count; i++ )); do
        local lng
        lng=$(printf '%s' "$lng_json" | jq -c ".[$i]")

        LNGS+=("$(printf '%s' "$lng" | jq '{
            id: .id,
            name: .name,
            location: .location,
            gatewayIpAddress: (.gatewayIpAddress // "Unknown"),
            localAddressSpace: [.localNetworkAddressSpace.addressPrefixes // [] | .[]]
        }')")
    done

    # ── VPN/ER Gateway Connections in this RG (GH #35 fix) ──
    local conn_json
    conn_json=$(invoke_with_retry "List GW connections" --error-scope "vnet/$vnet_name/gw-connections" \
        az network vpn-connection list --subscription "$sub_id" --resource-group "$rg" --output json || echo '[]')

    local conn_count
    conn_count=$(printf '%s' "$conn_json" | jq 'length')

    # Fallback: Resource Graph query if CLI returned nothing
    if (( conn_count == 0 )); then
        log_detail "CLI returned no connections for $rg — trying Resource Graph fallback…"
        local graph_conns
        graph_conns=$(invoke_graph_query_paginated \
            "Query connections for $vnet_name" \
            "Resources | where type =~ 'microsoft.network/connections' | where resourceGroup =~ '$rg' or properties.virtualNetworkGateway1.id contains '$vnet_id' | project id, name, type, resourceGroup, connectionType = tostring(properties.connectionType), gatewayId = tostring(properties.virtualNetworkGateway1.id), circuitId = tostring(properties.peer.id), localNetworkGatewayId = tostring(properties.localNetworkGateway2.id), connectionStatus = tostring(properties.connectionStatus), routingWeight = toint(properties.routingWeight)" \
            "$sub_id" \
            "vnet/$vnet_name/gw-connections-graph")
        local graph_conn_count
        graph_conn_count=$(printf '%s' "$graph_conns" | jq 'length')
        if (( graph_conn_count > 0 )); then
            log_found "$graph_conn_count connection(s) found via Resource Graph fallback"
            for (( i = 0; i < graph_conn_count; i++ )); do
                GW_CONNECTIONS+=("$(printf '%s' "$graph_conns" | jq -c ".[$i] | {
                    id: .id, name: .name,
                    connectionType: (.connectionType // \"Unknown\"),
                    gatewayId: (.gatewayId // \"\"),
                    circuitId: (.circuitId // \"\"),
                    localNetworkGatewayId: (.localNetworkGatewayId // \"\"),
                    connectionStatus: (.connectionStatus // \"Unknown\"),
                    routingWeight: (.routingWeight // 0)
                }")")
            done
        fi
    else
        log_found "$conn_count connection(s) found"
        for (( i = 0; i < conn_count; i++ )); do
            local conn
            conn=$(printf '%s' "$conn_json" | jq -c ".[$i]")

            GW_CONNECTIONS+=("$(printf '%s' "$conn" | jq '{
                id: .id,
                name: .name,
                connectionType: (.connectionType // "Unknown"),
                gatewayId: (.virtualNetworkGateway1.id // ""),
                circuitId: (.peer.id // ""),
                localNetworkGatewayId: (.localNetworkGateway2.id // ""),
                connectionStatus: (.connectionStatus // "Unknown"),
                routingWeight: (.routingWeight // 0)
            }')")
        done
    fi
}

# ── Check for merge subcommand before regular arg parsing ────────────────────
_MERGE_MODE=""
_MERGE_ARGS=()
if [[ "${1:-}" == "merge" ]]; then
    _MERGE_MODE="true"
    shift
    _MERGE_ARGS=("$@")
    # Skip regular arg parsing — will dispatch after function definitions
    set --
fi

# ── Argument parsing ─────────────────────────────────────────────────────────
DIAGRAM_TITLE=""
STARTING_VNET_ID=""
STARTING_VNET_TYPE="Microsoft.Network/virtualNetworks"
SUB_ID=""
SUB_NAME=""
RG_NAME=""
OUTPUT_FILE=""
BASELINE_FILE=""
ACCEPTED_SUB_ID=""
ACCEPTED_SUB_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)
            DIAGRAM_TITLE="$2"; shift 2 ;;
        --vnet-id)
            STARTING_VNET_ID="$2"; STARTING_VNET_TYPE="Microsoft.Network/virtualNetworks"; shift 2 ;;
        --vhub-id)
            STARTING_VNET_ID="$2"; STARTING_VNET_TYPE="Microsoft.Network/virtualHubs"; shift 2 ;;
        --subscription)
            SUB_ID="$2"; shift 2 ;;
        --resource-group)
            RG_NAME="$2"; shift 2 ;;
        --output)
            OUTPUT_FILE="$2"; shift 2 ;;
        --baseline)
            BASELINE_FILE="$2"; shift 2 ;;
        --help)
            head -n 31 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0 ;;
        *)
            log_error "Unknown argument: $1"
            exit 1 ;;
    esac
done

# ── Banner ───────────────────────────────────────────────────────────────────
show_banner() {
    local w=60
    local bar
    bar=$(printf '═%.0s' $(seq 1 $((w + 4))))
    _banner_line() {
        local text="$1"
        local color="${2:-}"
        local len=${#text}
        local right=$(( w - len ))
        local pad
        pad=$(printf '%*s' "$right" '')
        printf "${_C_BOLD}${_C_CYAN}  ║${_C_RESET}  ${color}%s${_C_RESET}%s  ${_C_BOLD}${_C_CYAN}║${_C_RESET}\n" "$text" "$pad" >&2
    }
    printf "\n" >&2
    printf "${_C_BOLD}${_C_CYAN}  ╔%s╗${_C_RESET}\n" "$bar" >&2
    _banner_line ""
    _banner_line "  ▄▀█ █▀▀ █▀▄   █▀▀ █▀ █▀▄▀█ █▀▀" "${_C_BOLD}${_C_GREEN}"
    _banner_line "  █▀█ ██▄ █▄▀   ██▄ ▄█ █ ▀ █ ██▄" "${_C_BOLD}${_C_GREEN}"
    _banner_line ""
    _banner_line "  Azure Network Topology Generator" "${_C_BOLD}${_C_WHITE}"
    _banner_line "  v${SCRIPT_VERSION}  ·  Schema v${SCHEMA_VERSION}  ·  bash" "${_C_DIM}"
    _banner_line "  Author: johnfern@" "${_C_DIM}"
    _banner_line ""
    printf "${_C_BOLD}${_C_CYAN}  ╚%s╝${_C_RESET}\n" "$bar" >&2
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    show_banner

    # Capture script start time for duration reporting
    SECONDS=0

    check_prerequisites

    # Sleep prevention
    start_sleep_prevention
    trap 'stop_sleep_prevention; _cleanup_temp_files' EXIT INT TERM

    # ── Step 1: Subscription ──
    if [[ -n "$SUB_ID" ]]; then
        if validate_subscription_guid "$SUB_ID"; then
            SUB_NAME=$(az account show --subscription "$SUB_ID" --query name -o tsv 2>/dev/null || echo "$SUB_ID")
        else
            # Assume it's a subscription name
            SUB_NAME="$SUB_ID"
            SUB_ID=$(az account show --subscription "$SUB_NAME" --query id -o tsv 2>/dev/null || echo "")
            if [[ -z "$SUB_ID" ]]; then
                log_error "Could not resolve subscription: $SUB_NAME"
                exit 1
            fi
        fi
        log_info "Using subscription: $SUB_NAME ($SUB_ID)"
    fi

    # ── Step 2: If we have a direct VNet ID, extract sub + RG from it ──
    if [[ -n "$STARTING_VNET_ID" ]]; then
        if ! validate_arm_resource_id "$STARTING_VNET_ID"; then
            log_error "Invalid VNet resource ID: $STARTING_VNET_ID"
            exit 1
        fi
        SUB_ID=$(echo "$STARTING_VNET_ID" | sed -n 's|^/subscriptions/\([^/]*\)/.*|\1|p')
        RG_NAME=$(echo "$STARTING_VNET_ID" | sed -n 's|^/subscriptions/[^/]*/resourceGroups/\([^/]*\)/.*|\1|p')
        SUB_NAME=$(az account show --subscription "$SUB_ID" --query name -o tsv 2>/dev/null || echo "$SUB_ID")
        log_info "Direct mode: $STARTING_VNET_ID"
    fi

    # ── Step 3: Interactive selection for missing values ──
    if [[ -z "$SUB_ID" ]]; then
        if [[ -n "$ACCEPTED_SUB_ID" ]]; then
            SUB_ID="$ACCEPTED_SUB_ID"
            SUB_NAME="$ACCEPTED_SUB_NAME"
            log_info "Using subscription: $SUB_NAME ($SUB_ID)"
        else
            select_subscription
        fi
    fi
    [[ -z "$RG_NAME" ]] && select_resource_group
    [[ -z "$STARTING_VNET_ID" ]] && select_vnet

    # ── Step 4: Title ──
    prompt_title
    log_info "Title: $DIAGRAM_TITLE"

    # ── Step 5: Build the starting scope ──
    local starting_resource_id="$STARTING_VNET_ID"
    local starting_resource_type="$STARTING_VNET_TYPE"
    if [[ -z "$starting_resource_id" ]]; then
        starting_resource_id="/subscriptions/$SUB_ID/resourceGroups/$RG_NAME"
        starting_resource_type="ResourceGroup"
    fi

    # ── Step 6: Collect VNet IDs ──
    log_step "Discovering Network Topology"

    local vnet_ids=()
    if [[ -n "$STARTING_VNET_ID" ]]; then
        vnet_ids+=("$STARTING_VNET_ID")
    else
        # Collect all VNets in the RG
        local all_vnets
        all_vnets=$(invoke_with_retry "List VNets" --max-retries 1 \
            az network vnet list --subscription "$SUB_ID" --resource-group "$RG_NAME" --query '[].id' -o json || echo '[]')
        while IFS= read -r vid; do
            [[ -z "$vid" ]] && continue
            vnet_ids+=("$vid")
        done < <(printf '%s' "$all_vnets" | jq -r '.[]')

        # Also collect all Virtual Hubs in the RG
        local all_vhubs
        all_vhubs=$(invoke_with_retry "List vHubs" --max-retries 1 \
            az network vhub list --subscription "$SUB_ID" --resource-group "$RG_NAME" --query '[].id' -o json || echo '[]')
        while IFS= read -r vid; do
            [[ -z "$vid" ]] && continue
            vnet_ids+=("$vid")
        done < <(printf '%s' "$all_vhubs" | jq -r '.[]')
    fi

    if (( ${#vnet_ids[@]} == 0 )); then
        log_error "No VNets or Virtual Hubs to discover."
        exit 1
    fi

    # ── Step 7: Resolve topology version from baseline ──
    local topology_version=1
    if [[ -n "$BASELINE_FILE" ]]; then
        if [[ -f "$BASELINE_FILE" ]]; then
            local prev_version
            prev_version=$(jq -r '.topologyVersion // empty' "$BASELINE_FILE" 2>/dev/null)
            if [[ -n "$prev_version" ]] && [[ "$prev_version" =~ ^[0-9]+$ ]] && (( prev_version >= 1 )); then
                topology_version=$(( prev_version + 1 ))
            fi
            log_info "Baseline topology version ${prev_version:-null} → new version $topology_version"
            log_info "Baseline merge enabled — user edits will be preserved"
        else
            log_warn "Could not read baseline file '$BASELINE_FILE' — defaulting to version 1"
        fi
    fi

    # ── Step 8: Single-VNet mode or partition into connected components ──
    # Build a filename-safe slug from the title (spaces → dashes, lowercase)
    local title_slug
    title_slug=$(echo "$DIAGRAM_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g; s/[^a-z0-9._-]//g')

    # Open persistent log file (same directory as output, .log extension)
    local log_file_name="topology.${title_slug}.$(date -u +%Y%m%d-%H%M%S).log"
    if [[ -n "$OUTPUT_FILE" ]]; then
        log_file_name="$(cd "$(dirname "$OUTPUT_FILE")" 2>/dev/null && pwd)/$log_file_name"
    fi
    _log_file_open "$log_file_name"

    # Retroactively write prerequisite context to log file
    local _az_ver _acct_user _acct_tenant _acct_sub _acct_sub_id
    _az_ver=$(az version --output json 2>/dev/null | jq -r '."azure-cli" // "unknown"')
    _acct_user=$(az account show --query 'user.name' -o tsv 2>/dev/null || echo 'unknown')
    _acct_tenant=$(az account show --query 'tenantId' -o tsv 2>/dev/null || echo 'unknown')
    _acct_sub=$(az account show --query 'name' -o tsv 2>/dev/null || echo 'unknown')
    _acct_sub_id=$(az account show --query 'id' -o tsv 2>/dev/null || echo 'unknown')
    _log_to_file "── Generator ──"
    _log_to_file "  v${SCRIPT_VERSION}  ·  Schema v${SCHEMA_VERSION}  ·  bash"
    _log_to_file "  Bash ${BASH_VERSION}  ·  Azure CLI ${_az_ver}"
    _log_to_file "  User:         ${_acct_user}"
    _log_to_file "  Tenant:       ${_acct_tenant}"
    _log_to_file "  Subscription: ${_acct_sub} (${_acct_sub_id})"
    [[ -n "$STARTING_VNET_ID" ]] && _log_to_file "  Resource:     ${STARTING_VNET_ID}"
    _log_to_file "  Title:        ${DIAGRAM_TITLE}"
    _log_to_file ""
    log_info "Log file: $(cd "$(dirname "$log_file_name")" 2>/dev/null && pwd)/$(basename "$log_file_name")"

    if [[ -n "$STARTING_VNET_ID" ]] || (( ${#vnet_ids[@]} == 1 )); then
        # Single root — straightforward BFS
        local out_file="${OUTPUT_FILE:-topology.${title_slug}.$(date -u +%Y%m%d-%H%M%S).json}"
        discover_and_emit_topology \
            "$DIAGRAM_TITLE" "$starting_resource_id" "$starting_resource_type" \
            "$out_file" "$topology_version" "${vnet_ids[@]}"
    else
        # "All" mode — multiple seed networks
        # Build a filename-safe slug from the title
        local ts
        ts=$(date -u +%Y%m%d-%H%M%S)

        if (( BASH_VERSINFO[0] < 4 )); then
            # bash 3.x: no associative arrays, so skip connected-component
            # partitioning — treat all seeds as one group, single BFS pass
            log_info "bash 3.x: skipping network-group detection (needs bash 4+)"
            log_info "All ${#vnet_ids[@]} seed(s) will be discovered in a single pass"

            local out_file="${OUTPUT_FILE:-topology.${title_slug}.${ts}.json}"
            discover_and_emit_topology \
                "$DIAGRAM_TITLE" "$starting_resource_id" "$starting_resource_type" \
                "$out_file" "$topology_version" "${vnet_ids[@]}"
        else
            # bash 4+ — partition into connected components so that
            # linked networks share a single file and unlinked ones
            # get their own separate file.
            log_step "Scanning peerings to identify network groups"
            local components_json
            components_json=$(build_connected_components "${vnet_ids[@]}")

        local comp_count
        comp_count=$(printf '%s' "$components_json" | jq 'length')
        log_info "Found $comp_count network group(s) across ${#vnet_ids[@]} VNet(s)"

        local ts
        ts=$(date -u +%Y%m%d-%H%M%S)

        for (( ci = 0; ci < comp_count; ci++ )); do
            local comp_ids_json
            comp_ids_json=$(printf '%s' "$components_json" | jq -c ".[$ci]")
            local comp_size
            comp_size=$(printf '%s' "$comp_ids_json" | jq 'length')

            # Use only the first VNet in the component as the BFS root
            local root_id
            root_id=$(printf '%s' "$comp_ids_json" | jq -r '.[0]')
            local root_name
            root_name=$(basename "$root_id")

            # Build the component seed list (just the root — BFS will find the rest)
            local comp_seeds=("$root_id")

            # Determine output file name
            local comp_out
            if (( comp_count == 1 )); then
                comp_out="${OUTPUT_FILE:-topology.${title_slug}.${ts}.json}"
            else
                local base_name="${OUTPUT_FILE%.json}"
                if [[ -z "$OUTPUT_FILE" ]]; then
                    base_name="topology.${title_slug}.${ts}"
                fi
                comp_out="${base_name}.$((ci + 1)).${root_name}.json"
            fi

            # Determine title for this component
            local comp_title="$DIAGRAM_TITLE"
            if (( comp_count > 1 )); then
                comp_title="${DIAGRAM_TITLE} ($root_name)"
            fi

            local comp_scope_id="$root_id"
            local comp_scope_type="Microsoft.Network/virtualNetworks"

            log_step "Group $((ci + 1))/$comp_count — $root_name ($comp_size network(s) in local RG)"
            discover_and_emit_topology \
                "$comp_title" "$comp_scope_id" "$comp_scope_type" \
                "$comp_out" "$topology_version" "${comp_seeds[@]}"
        done
        fi  # bash version check
    fi

    log_step "Complete"
}

# ── Connected-component builder (union-find) ────────────────────────────────
# Lightweight pass: for each VNet in the RG, fetch its peering targets.
# Uses union-find to partition VNets into connected components based on
# which local VNets are directly peered to each other.
#
# Args: list of VNet ARM IDs
# Outputs: JSON array of arrays, e.g. [["id-a","id-b"],["id-c"]]
build_connected_components() {
    if (( BASH_VERSINFO[0] < 4 )); then
        log_error "Connected-component detection requires bash 4+ (associative arrays)."
        log_error "Install via: brew install bash"
        log_error "Then run:    /opt/homebrew/bin/bash $0"
        exit 1
    fi

    local ids=("$@")
    local -A parent  # union-find parent map (lowercase IDs)
    local -A id_map  # lowercase → original-case mapping

    # Initialize: each node is its own parent
    for vid in "${ids[@]}"; do
        local vid_lower
        vid_lower=$(echo "$vid" | tr '[:upper:]' '[:lower:]')
        parent["$vid_lower"]="$vid_lower"
        id_map["$vid_lower"]="$vid"
    done

    # Find with path compression
    uf_find() {
        local x="$1"
        while [[ "${parent[$x]}" != "$x" ]]; do
            parent["$x"]="${parent[${parent[$x]}]}"
            x="${parent[$x]}"
        done
        echo "$x"
    }

    # Union
    uf_union() {
        local a b
        a=$(uf_find "$1")
        b=$(uf_find "$2")
        if [[ "$a" != "$b" ]]; then
            parent["$a"]="$b"
        fi
    }

    # Scan peerings/connections and union connected networks (only within local set)
    for vid in "${ids[@]}"; do
        local vid_lower
        vid_lower=$(echo "$vid" | tr '[:upper:]' '[:lower:]')

        if is_vhub_resource_id "$vid"; then
            # For vHubs, query hub VNet connections instead of VNet peerings
            log_info "  Scanning hub connections for $(basename "$vid")…"
            local vhub_name vhub_sub vhub_rg
            vhub_name=$(basename "$vid")
            vhub_sub=$(echo "$vid" | sed -n 's|^/subscriptions/\([^/]*\)/.*|\1|p')
            vhub_rg=$(echo "$vid" | sed -n 's|^/subscriptions/[^/]*/resourceGroups/\([^/]*\)/.*|\1|p')

            local hub_conn_ids
            hub_conn_ids=$(invoke_with_retry "List vHub connections for $vhub_name" --max-retries 1 \
                az network vhub connection list \
                    --vhub-name "$vhub_name" --subscription "$vhub_sub" --resource-group "$vhub_rg" \
                    --query '[].remoteVirtualNetwork.id' -o json || echo '[]')

            while IFS= read -r peer; do
                [[ -z "$peer" ]] && continue
                local peer_lower
                peer_lower=$(echo "$peer" | tr '[:upper:]' '[:lower:]')
                if [[ -n "${parent[$peer_lower]+x}" ]]; then
                    uf_union "$vid_lower" "$peer_lower"
                fi
            done < <(printf '%s' "$hub_conn_ids" | jq -r '.[]' 2>/dev/null)
        else
            log_info "  Scanning peerings for $(basename "$vid")…"
            local peer_ids_json
            peer_ids_json=$(invoke_with_retry "Peek VNet peerings" --max-retries 1 \
                az network vnet show --ids "$vid" --query 'virtualNetworkPeerings[].remoteVirtualNetwork.id' -o json || echo '[]')

            while IFS= read -r peer; do
                [[ -z "$peer" ]] && continue
                local peer_lower
                peer_lower=$(echo "$peer" | tr '[:upper:]' '[:lower:]')
                # Only union if the peer is also in our local RG set
                if [[ -n "${parent[$peer_lower]+x}" ]]; then
                    uf_union "$vid_lower" "$peer_lower"
                fi
            done < <(printf '%s' "$peer_ids_json" | jq -r '.[]' 2>/dev/null)
        fi
    done

    # Group by root — preserving original-case IDs
    local -A groups  # root → newline-separated original IDs
    for vid in "${ids[@]}"; do
        local vid_lower
        vid_lower=$(echo "$vid" | tr '[:upper:]' '[:lower:]')
        local root
        root=$(uf_find "$vid_lower")
        groups["$root"]+="$vid"$'\n'
    done

    # Output as JSON array of arrays
    local result="["
    local first=true
    for root in "${!groups[@]}"; do
        local members="${groups[$root]}"
        local arr
        arr=$(printf '%s' "$members" | grep -v '^$' | jq -R . | jq -s .)
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi
        result+="$arr"
    done
    result+="]"
    echo "$result"
}

# ── Merge Engine (T212) ──────────────────────────────────────────────────────
# Applies user-authored content from baseline onto target using jq.
# Prints merged JSON to stdout. Logs summary to stderr.
#
# Args:
#   $1 = baseline JSON (string)
#   $2 = target JSON (string)
# Output: merged target JSON on stdout
merge_user_edits() {
    local baseline_json="$1"
    local target_json="$2"

    local merged
    merged=$(jq -n \
        --argjson baseline "$baseline_json" \
        --argjson target "$target_json" \
        '
        # Build baseline indexes
        def lower: ascii_downcase;

        # Index baseline vnets and ER circuits by lowercase id
        ($baseline.vnets // []) as $bvnets |
        ($baseline.expressRouteCircuits // []) as $ber |
        ($baseline.onPremises // []) as $bonprem |

        # Build lookup maps
        (reduce $bvnets[] as $v ({}; . + {($v.id | lower): $v})) as $bvnet_map |
        (reduce $ber[] as $e ({}; . + {($e.id | lower): $e})) as $ber_map |
        (reduce $bonprem[] as $s ({}; . + {($s.id | lower): $s})) as $bonprem_map |

        # Merge function for a single collection (vnets or expressRouteCircuits)
        def merge_collection(baseline_map):
            [.[] | . as $item |
                ($item.id | lower) as $key |
                if baseline_map[$key] then
                    # Apply _layout
                    (if baseline_map[$key]._layout then
                        . + {_layout: baseline_map[$key]._layout}
                    else . end) |
                    # Overlay x-aed-* tags from baseline
                    (baseline_map[$key].tags // {}) as $btags |
                    (reduce ($btags | to_entries[]) as $e (.;
                        if ($e.key | startswith("x-aed-")) then
                            .tags = ((.tags // {}) + {($e.key): $e.value})
                        else . end
                    ))
                else . end
            ];

        # Merge onPremises
        def merge_onprem(baseline_map):
            [.[] | . as $site |
                ($site.id | lower) as $key |
                if baseline_map[$key] then
                    (baseline_map[$key]) as $bs |
                    # Apply _layout
                    (if $bs._layout then . + {_layout: $bs._layout} else . end) |
                    # Apply user fields
                    (if $bs.name then .name = $bs.name else . end) |
                    (if $bs.description then .description = $bs.description else . end) |
                    (if ($bs.ipRanges // [] | length) > 0 then .ipRanges = $bs.ipRanges else . end) |
                    (if $bs.notes then .notes = $bs.notes else . end)
                else . end
            ];

        # Collect target IDs for orphan detection
        ([($target.vnets // [])[].id, ($target.expressRouteCircuits // [])[].id, ($target.onPremises // [])[].id] | map(lower)) as $target_ids |

        # Merge collections
        $target |
        .vnets = (.vnets // [] | merge_collection($bvnet_map)) |
        .expressRouteCircuits = ((.expressRouteCircuits // []) | merge_collection($ber_map)) |

        # Merge onPremises with user fields
        .onPremises = ((.onPremises // []) | merge_onprem($bonprem_map)) |

        # Preserve user-created onPremises from baseline not in target
        ((.onPremises // []) | map(.id | lower)) as $matched_onprem_ids |
        (reduce ($bonprem_map | to_entries[]) as $e (.;
            if ([$target_ids[] | select(. == $e.key)] | length) == 0 and
               ([$matched_onprem_ids[] | select(. == $e.key)] | length) == 0 then
                .onPremises = (.onPremises + [$e.value])
            else . end
        )) |

        # topologyVersion: increment from baseline
        (if ($baseline.topologyVersion // null) != null and
            ($baseline.topologyVersion | type) == "number" and
            $baseline.topologyVersion >= 1 then
            .topologyVersion = ($baseline.topologyVersion + 1)
        else . end) |

        # Remove empty collections
        if (.expressRouteCircuits | length) == 0 then del(.expressRouteCircuits) else . end |
        if (.onPremises // [] | length) == 0 then del(.onPremises) else . end
        ')

    # Log summary counts
    local applied_layouts merged_tags merged_edits preserved_onprem orphaned new_resources
    applied_layouts=$(jq -n --argjson b "$baseline_json" --argjson t "$merged" '
        [($t.vnets // [])[], ($t.expressRouteCircuits // [])[], ($t.onPremises // [])[]]
        | map(select(._layout)) | length' 2>/dev/null || echo 0)

    orphaned=$(jq -n --argjson b "$baseline_json" --argjson t "$merged" '
        ([($t.vnets // [])[], ($t.expressRouteCircuits // [])[]] | map(.id | ascii_downcase)) as $tids |
        [($b.vnets // [])[], ($b.expressRouteCircuits // [])[]]
        | map(.id | ascii_downcase) | map(select(. as $bid | $tids | index($bid) | not)) | length' 2>/dev/null || echo 0)

    log_info "Layouts applied: $applied_layouts"
    if (( orphaned > 0 )); then
        log_warn "Orphaned baseline resources: $orphaned"
    fi

    printf '%s' "$merged"
}

# Merge multiple topology files left-to-right (offline, no Azure login)
# Args: file1 file2 [fileN...] -o output
run_merge_subcommand() {
    local files=()
    local output_file=""

    # Parse merge-specific args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                output_file="$2"; shift 2 ;;
            -*)
                log_error "Unknown merge option: $1"; exit 1 ;;
            *)
                files+=("$1"); shift ;;
        esac
    done

    if (( ${#files[@]} < 2 )); then
        log_error "merge requires at least 2 input files"
        exit 1
    fi
    if [[ -z "$output_file" ]]; then
        log_error "merge requires -o / --output"
        exit 1
    fi

    # Validate all input files exist
    for path in "${files[@]}"; do
        if [[ ! -f "$path" ]]; then
            log_error "File not found: $path"
            exit 1
        fi
    done

    log_step "Merge Topology Files"
    log_info "Input files: ${#files[@]}"
    local i=1
    for path in "${files[@]}"; do
        log_info "  $i. $path"
        (( i++ ))
    done
    log_info "Output: $output_file"

    # Load base
    log_info "Loading base: ${files[0]}"
    local result
    result=$(cat "${files[0]}")

    # Overlay each subsequent file
    for (( fi = 1; fi < ${#files[@]}; fi++ )); do
        local step_num=$(( fi + 1 ))
        log_info "Merging file $step_num/${#files[@]}: ${files[$fi]}"
        local overlay
        overlay=$(cat "${files[$fi]}")

        # Union resources from overlay into result
        result=$(jq -n --argjson base "$result" --argjson overlay "$overlay" '
            def lower: ascii_downcase;

            # Union vnets
            ($base.vnets // []) as $bv |
            ($bv | map(.id | lower)) as $bv_ids |
            ($overlay.vnets // [] | map(select((.id | lower) as $oid | $bv_ids | index($oid) | not))) as $new_vnets |

            # Union expressRouteCircuits
            ($base.expressRouteCircuits // []) as $ber |
            ($ber | map(.id | lower)) as $ber_ids |
            ($overlay.expressRouteCircuits // [] | map(select((.id | lower) as $oid | $ber_ids | index($oid) | not))) as $new_er |

            # Union connections
            def conn_key: "\(.sourceVNet.id // "")\(.targetVNet.id // "")" | lower;
            ($base.connections // []) as $bc |
            ($bc | map(conn_key)) as $bc_keys |
            ($overlay.connections // [] | map(select(conn_key as $ck | $bc_keys | index($ck) | not))) as $new_conns |

            # Union localNetworkGateways
            ($base.localNetworkGateways // []) as $blng |
            ($blng | map(.id | lower)) as $blng_ids |
            ($overlay.localNetworkGateways // [] | map(select((.id | lower) as $oid | $blng_ids | index($oid) | not))) as $new_lngs |

            # Union gatewayConnections
            ($base.gatewayConnections // []) as $bgwc |
            ($bgwc | map(.id | lower)) as $bgwc_ids |
            ($overlay.gatewayConnections // [] | map(select((.id | lower) as $oid | $bgwc_ids | index($oid) | not))) as $new_gwc |

            # Union onPremises
            ($base.onPremises // []) as $bop |
            ($bop | map(.id | lower)) as $bop_ids |
            ($overlay.onPremises // [] | map(select((.id | lower) as $oid | $bop_ids | index($oid) | not))) as $new_op |

            $base |
            .vnets = ($bv + $new_vnets) |
            .connections = ($bc + $new_conns) |
            if (($ber + $new_er) | length) > 0 then .expressRouteCircuits = ($ber + $new_er) else . end |
            if (($blng + $new_lngs) | length) > 0 then .localNetworkGateways = ($blng + $new_lngs) else . end |
            if (($bgwc + $new_gwc) | length) > 0 then .gatewayConnections = ($bgwc + $new_gwc) else . end |
            if (($bop + $new_op) | length) > 0 then .onPremises = ($bop + $new_op) else . end
        ')

        # Apply user edits from overlay onto the union result
        result=$(merge_user_edits "$overlay" "$result")
    done

    # Write output
    printf '%s\n' "$result" > "$output_file"
    log_info "Merged ${#files[@]} files → $output_file"

    log_step "Complete"
    log_info "Output: $(cd "$(dirname "$output_file")" 2>/dev/null && pwd)/$(basename "$output_file")"
}

# ── Full discovery + emit for one topology graph ─────────────────────────────
# Runs BFS from the given seed VNet IDs, builds connections, assembles
# the schema-v2.0 JSON, and writes it to the specified output file.
#
# Args:
#   $1 = title
#   $2 = starting resource ID (for scope)
#   $3 = starting resource type (for scope)
#   $4 = output file path
#   $5..N = seed VNet IDs
discover_and_emit_topology() {
    local title="$1"
    local scope_resource_id="$2"
    local scope_resource_type="$3"
    local output_file="$4"
    local topology_version="$5"
    shift 5
    local seed_ids=("$@")

    # Accumulate results
    local all_vnets_json="[]"
    local all_connections_json="[]"

    # Reset external connectivity trackers
    ER_CIRCUITS=()
    LNGS=()
    GW_CONNECTIONS=()
    NSG_RULES=()

    # ── BFS queue-based VNet discovery ──
    local queue=()
    local seen=""

    for vid in "${seed_ids[@]}"; do
        queue+=("$vid")
        seen+="$(echo "$vid" | tr '[:upper:]' '[:lower:]')"$'\n'
    done

    log_info "Starting traversal from ${#seed_ids[@]} seed network(s)…"

    local vnet_counter=0
    while (( ${#queue[@]} > 0 )); do
        local current_id="${queue[0]}"
        queue=("${queue[@]:1}")

        local vnet_obj
        local remaining=${#queue[@]}
        vnet_counter=$((vnet_counter + 1))

        if is_vhub_resource_id "$current_id"; then
            # Direct vHub ARM ID (from inter-hub peering) — discover via vHub commands
            log_step "Processing VNet ${vnet_counter}: $(basename "$current_id")…"
            log_resource "vWAN Hub: $(basename "$current_id")  [${remaining} in queue]"
            vnet_obj=$(discover_vhub "$current_id" "$current_id")
        elif is_vhub_vnet_id "$current_id"; then
            log_step "Processing VNet ${vnet_counter}: $(basename "$current_id")…"
            log_resource "vWAN Hub VNet: $(basename "$current_id")  [${remaining} in queue]"
            local vhub_resource_id
            vhub_resource_id=$(resolve_vhub_id_from_vnet "$current_id") || true

            if [[ -n "$vhub_resource_id" ]]; then
                # Guard: skip if this vHub was already discovered via a different path
                local vhub_resolved_lower
                vhub_resolved_lower=$(echo "$vhub_resource_id" | tr '[:upper:]' '[:lower:]')
                if echo "$seen" | grep -qF "$vhub_resolved_lower"; then
                    log_detail "Already discovered — skipping duplicate"
                    continue
                fi
                vnet_obj=$(discover_vhub "$vhub_resource_id" "$current_id")
            else
                log_alert \
                    "ACCESS DENIED — $(basename "$current_id")" \
                    "Could not resolve the Virtual Hub behind this managed VNet." \
                    "The hub may be in a subscription you don't have access to." \
                    "A placeholder will be added to the topology."
                vnet_obj=$(jq -n \
                    --arg id "$current_id" \
                    --arg name "$(basename "$current_id")" \
                    '{id: $id, name: $name, addressSpace: [],
                      location: "unknown", resourceGroup: "unknown",
                      subnets: [], peerings: [],
                      _isVirtualHub: true, _accessDenied: true}')
            fi
        else
            log_step "Processing VNet ${vnet_counter}: $(basename "$current_id")…"
            log_resource "VNet: $(basename "$current_id")  [${remaining} in queue]"
            vnet_obj=$(discover_vnet "$current_id")
            discover_external_connectivity "$current_id"
        fi

        all_vnets_json=$(printf '%s' "$all_vnets_json" | jq --argjson v "$vnet_obj" '. + [$v]')

        # For vHubs, mark both the output ID and the vHub ARM ID as seen
        # to prevent double-discovery (HV_ VNet path vs direct vHub path)
        local discovered_vhub_id
        discovered_vhub_id=$(printf '%s' "$vnet_obj" | jq -r '._vhubResourceId // empty' 2>/dev/null)
        if [[ -n "$discovered_vhub_id" ]]; then
            local vhub_id_lower
            vhub_id_lower=$(echo "$discovered_vhub_id" | tr '[:upper:]' '[:lower:]')
            if ! echo "$seen" | grep -qF "$vhub_id_lower"; then
                seen+="${vhub_id_lower}"$'\n'
            fi
        fi

        # Enqueue unseen peered VNets
        local peer_ids_from_json
        peer_ids_from_json=$(printf '%s' "$vnet_obj" | jq -r '.peerings[]?.remoteVnetId // empty' 2>/dev/null)

        while IFS= read -r peer_id; do
            [[ -z "$peer_id" ]] && continue
            local peer_id_lower
            peer_id_lower=$(echo "$peer_id" | tr '[:upper:]' '[:lower:]')
            if echo "$seen" | grep -qF "$peer_id_lower"; then
                continue
            fi
            seen+="${peer_id_lower}"$'\n'
            queue+=("$peer_id")
            if is_vhub_resource_id "$peer_id"; then
                log_queue "Linked vWAN Hub: $(basename "$peer_id")"
            else
                log_queue "Peered network: $(basename "$peer_id")"
            fi
        done <<< "$peer_ids_from_json"
    done

    # ── Enrich VNets with Private DNS Zone links ──
    log_substep "Querying Private DNS Zone virtual network links…"
    local dns_zone_query
    dns_zone_query="Resources
| where type =~ 'microsoft.network/privatednszones/virtualnetworklinks'
| extend vnetId = tolower(tostring(properties.virtualNetwork.id))
| extend zoneName = tostring(split(id, '/')[8])
| project vnetId, zoneName, registrationEnabled = tobool(properties.registrationEnabled)"

    local dns_zone_links
    dns_zone_links=$(invoke_graph_query_paginated "Query Private DNS Zone links" "$dns_zone_query" "$SUB_ID" "private-dns-zone-links")
    local dns_link_count
    dns_link_count=$(printf '%s' "$dns_zone_links" | jq 'length')
    log_found "${dns_link_count} DNS zone link(s) found"

    # Attach privateDnsZones to each VNet (omit when empty)
    for (( vi = 0; vi < $(printf '%s' "$all_vnets_json" | jq 'length'); vi++ )); do
        local vi_id_lower
        vi_id_lower=$(printf '%s' "$all_vnets_json" | jq -r ".[$vi].id | ascii_downcase")
        local zones
        zones=$(printf '%s' "$dns_zone_links" | jq -c --arg vid "$vi_id_lower" \
            '[.[] | select(.vnetId == $vid) | {name: .zoneName} + (if .registrationEnabled then {registrationEnabled: true} else {} end)] | sort_by(.name)')
        if [[ "$zones" != "[]" ]]; then
            all_vnets_json=$(printf '%s' "$all_vnets_json" | jq --argjson zones "$zones" --argjson idx "$vi" '.[$idx].privateDnsZones = $zones')
        fi
    done

    # ── Build connections ──
    printf "\n${_C_GREEN}${_C_BOLD}  ● Assembling peering connections…${_C_RESET}\n" >&2
    _log_to_file "  ● Assembling peering connections…"
    local vnet_total
    vnet_total=$(printf '%s' "$all_vnets_json" | jq 'length')

    for (( vi = 0; vi < vnet_total; vi++ )); do
        local vi_id
        vi_id=$(printf '%s' "$all_vnets_json" | jq -r ".[$vi].id")
        local peering_total
        peering_total=$(printf '%s' "$all_vnets_json" | jq ".[$vi].peerings | length")

        for (( pi = 0; pi < peering_total; pi++ )); do
            local p_remote p_name p_state
            p_remote=$(printf '%s' "$all_vnets_json" | jq -r ".[$vi].peerings[$pi].remoteVnetId")
            p_name=$(printf '%s' "$all_vnets_json" | jq -r ".[$vi].peerings[$pi].name")
            p_state=$(printf '%s' "$all_vnets_json" | jq -r ".[$vi].peerings[$pi].state")

            [[ -z "$p_remote" || "$p_remote" == "null" ]] && continue

            local src_lower tgt_lower
            src_lower=$(echo "$vi_id" | tr '[:upper:]' '[:lower:]')
            tgt_lower=$(echo "$p_remote" | tr '[:upper:]' '[:lower:]')
            local exists
            exists=$(printf '%s' "$all_connections_json" | jq \
                --arg s "$src_lower" --arg t "$tgt_lower" \
                '[.[] | select(
                    ((.sourceId | ascii_downcase) == $s and (.targetId | ascii_downcase) == $t) or
                    ((.sourceId | ascii_downcase) == $t and (.targetId | ascii_downcase) == $s)
                )] | length')
            if (( exists == 0 )); then
                local conn_obj
                conn_obj=$(jq -n \
                    --arg src "$vi_id" --arg tgt "$p_remote" \
                    --arg rel "VNet peering" --arg name "$p_name" --arg state "$p_state" \
                    '{sourceId: $src, targetId: $tgt, relationship: $rel, direction: "undirected",
                     metadata: {peeringName: $name, state: $state}}')
                all_connections_json=$(printf '%s' "$all_connections_json" | jq --argjson c "$conn_obj" '. + [$c]')
            fi
        done
    done

    # ── External connectivity arrays ──
    local er_circuits_json="[]"
    for er in ${ER_CIRCUITS[@]+"${ER_CIRCUITS[@]}"}; do
        er_circuits_json=$(printf '%s' "$er_circuits_json" | jq --argjson c "$er" '. + [$c] | unique_by(.id)')
    done
    local lngs_json="[]"
    for lng in ${LNGS[@]+"${LNGS[@]}"}; do
        lngs_json=$(printf '%s' "$lngs_json" | jq --argjson l "$lng" '. + [$l] | unique_by(.id)')
    done
    local gw_connections_json="[]"
    for gwc in ${GW_CONNECTIONS[@]+"${GW_CONNECTIONS[@]}"}; do
        gw_connections_json=$(printf '%s' "$gw_connections_json" | jq --argjson g "$gwc" '. + [$g] | unique_by(.id)')
    done

    # ── Validate ER circuit ↔ VNet gateway linkage (T141, GH #35) ──
    local er_circ_count gw_conn_count_final
    er_circ_count=$(printf '%s' "$er_circuits_json" | jq 'length')
    gw_conn_count_final=$(printf '%s' "$gw_connections_json" | jq 'length')
    if (( er_circ_count > 0 && gw_conn_count_final > 0 )); then
        local er_conn_linked
        er_conn_linked=$(jq -n --argjson ers "$er_circuits_json" --argjson gws "$gw_connections_json" \
            '[$gws[] | select(.circuitId != "" and (.circuitId as $cid | [$ers[] | .id] | map(ascii_downcase) | index($cid | ascii_downcase) != null))] | length')
        if (( er_conn_linked > 0 )); then
            log_found "$er_conn_linked ER circuit(s) linked to VNet gateway(s) via connections"
        else
            log_warn "Found $er_circ_count ER circuit(s) but no gateway connections reference them — ER ↔ gateway linkage may be incomplete"
        fi
    elif (( er_circ_count > 0 && gw_conn_count_final == 0 )); then
        log_warn "Found $er_circ_count ER circuit(s) but no gateway connections — ER ↔ gateway linkage missing"
    fi

    # ── Build warnings array ──
    local warnings_json="[]"
    for warn_entry in ${DISCOVERY_ERRORS[@]+"${DISCOVERY_ERRORS[@]}"}; do
        warnings_json=$(printf '%s' "$warnings_json" | jq --argjson w "$warn_entry" '. + [$w]')
    done

    # ── Synthesise on-premises sites ──
    local on_premises_json
    on_premises_json=$(synthesize_on_premises "$er_circuits_json")

    # ── Assemble topology JSON ──
    local generated_at
    generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local topology
    topology=$(jq -n \
        --arg schemaVersion "$SCHEMA_VERSION" \
        --argjson topologyVersion "$topology_version" \
        --arg generatedAt "$generated_at" \
        --arg title "$title" \
        --arg generator "$GENERATOR_NAME" \
        --arg subId "$SUB_ID" \
        --arg subName "$SUB_NAME" \
        --arg startingResourceId "$scope_resource_id" \
        --arg startingResourceType "$scope_resource_type" \
        --argjson vnets "$all_vnets_json" \
        --argjson connections "$all_connections_json" \
        --argjson erCircuits "$er_circuits_json" \
        --argjson lngs "$lngs_json" \
        --argjson gwConns "$gw_connections_json" \
        --argjson onPrem "$on_premises_json" \
        --argjson warnings "$warnings_json" \
        '{
            schemaVersion: $schemaVersion,
            topologyVersion: $topologyVersion,
            generatedAt: $generatedAt,
            title: $title,
            generator: $generator,
            scope: {
                subscriptionId: $subId,
                subscriptionName: $subName,
                startingResourceId: $startingResourceId,
                startingResourceType: $startingResourceType
            },
            vnets: $vnets,
            connections: $connections
        }
        | if ($erCircuits | length) > 0 then .expressRouteCircuits = $erCircuits else . end
        | if ($lngs | length) > 0 then .localNetworkGateways = $lngs else . end
        | if ($gwConns | length) > 0 then .gatewayConnections = $gwConns else . end
        | if ($onPrem | length) > 0 then .onPremises = $onPrem else . end
        | if ($warnings | length) > 0 then ._warnings = $warnings else . end')

    # ── Merge user edits from baseline (T212) ──
    if [[ -n "$BASELINE_FILE" ]] && [[ -f "$BASELINE_FILE" ]]; then
        log_step "Merging Baseline User Edits"
        local baseline_json
        baseline_json=$(cat "$BASELINE_FILE")
        topology=$(merge_user_edits "$baseline_json" "$topology")
    fi

    # ── Write output ──
    printf '%s\n' "$topology" > "$output_file"

    local vnet_count conn_count er_count lng_count warn_count
    vnet_count=$(printf '%s' "$topology" | jq '.vnets | length')
    conn_count=$(printf '%s' "$topology" | jq '.connections | length')
    er_count=$(printf '%s' "$er_circuits_json" | jq 'length')
    lng_count=$(printf '%s' "$lngs_json" | jq 'length')
    local on_prem_count
    on_prem_count=$(printf '%s' "$on_premises_json" | jq 'length')
    warn_count=${#DISCOVERY_ERRORS[@]}

    log_step "Results"
    # ── Results table ──
    local _rw=23
    _result_row() {
        printf >&2 "${_C_BOLD}${_C_CYAN}  │${_C_RESET} ${_C_WHITE}%-16s${_C_RESET} ${_C_BOLD}${_C_CYAN}│${_C_RESET} %-${_rw}s ${_C_BOLD}${_C_CYAN}│${_C_RESET}\n" "$1" "$2"
        _log_to_file "  $(printf '%-16s' "$1") $2"
    }
    printf >&2 "${_C_BOLD}${_C_CYAN}  ┌──────────────────┬─────────────────────────┐${_C_RESET}\n"
    _result_row "Title" "$title"
    _result_row "Networks" "$vnet_count"
    _result_row "Connections" "$conn_count"
    if (( er_count > 0 )); then
        _result_row "ER Circuits" "$er_count"
    fi
    if (( lng_count > 0 )); then
        _result_row "Local Gateways" "$lng_count"
    fi
    if (( on_prem_count > 0 )); then
        _result_row "On-Premises" "$on_prem_count"
    fi
    # Duration row
    local elapsed=$SECONDS
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    if (( mins > 0 )); then
        _result_row "Duration" "${mins}m $(printf '%02d' $secs)s"
    else
        _result_row "Duration" "${secs}s"
    fi
    if (( warn_count > 0 )); then
        _result_row "Warnings" "$warn_count"
    fi
    printf >&2 "${_C_BOLD}${_C_CYAN}  └──────────────────┴─────────────────────────┘${_C_RESET}\n"
    local _abs_output
    _abs_output="$(cd "$(dirname "$output_file")" && pwd)/$(basename "$output_file")"
    printf >&2 "${_C_WHITE}  %-16s${_C_RESET} %s\n" "Output:" "$_abs_output"
    _log_to_file "  $(printf '%-16s' 'Output:') $_abs_output"
    if [[ -n "$_LOG_FILE" ]]; then
        local _abs_log
        _abs_log="$(cd "$(dirname "$_LOG_FILE")" 2>/dev/null && pwd)/$(basename "$_LOG_FILE")"
        printf >&2 "${_C_WHITE}  %-16s${_C_RESET} %s\n" "Log:" "$_abs_log"
        _log_to_file "  $(printf '%-16s' 'Log:') $_abs_log"
    fi

    # ── Error summary (categorized) ──
    if (( warn_count > 0 )); then
        printf >&2 "\n"
        # Group errors by category
        local categories
        categories=$(printf '%s' "$warnings_json" | jq -r '[.[] | .category // "Other"] | unique | sort | .[]')
        local cat_count
        cat_count=$(echo "$categories" | grep -c . || true)
        log_warn "Completed with $warn_count error(s) in $cat_count category/categories:"
        while IFS= read -r cat; do
            [[ -z "$cat" ]] && continue
            local cat_errors
            cat_errors=$(printf '%s' "$warnings_json" | jq --arg cat "$cat" '[.[] | select((.category // "Other") == $cat)] | length')
            log_warn "  [$cat] ($cat_errors):"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                log_warn "    - $line"
            done < <(printf '%s' "$warnings_json" | jq -r --arg cat "$cat" '.[] | select((.category // "Other") == $cat) | "\(.scope): \(.error)"')
        done <<< "$categories"
    fi

    printf >&2 "\n${_C_BOLD}${_C_CYAN}  Next Steps:${_C_RESET}\n"
    printf >&2 "${_C_DIM}  1. Load the output file into the Azure Network Topology Viewer.${_C_RESET}\n"
    printf >&2 "${_C_DIM}  2. The initial layout may look messy — drag nodes to arrange them.${_C_RESET}\n"
    printf >&2 "${_C_DIM}  3. Save the file — positions are persisted and restored on reload.${_C_RESET}\n"
    printf >&2 "${_C_DIM}  4. Use 'Export as PNG' to capture the current view.${_C_RESET}\n"

    echo "$output_file"
}

if [[ "$_MERGE_MODE" == "true" ]]; then
    show_banner
    run_merge_subcommand "${_MERGE_ARGS[@]}"
else
    main
fi
