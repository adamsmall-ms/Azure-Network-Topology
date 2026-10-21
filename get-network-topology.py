##!/usr/bin/env python3
"""
get-network-topology.py — Azure Network Topology Generator for AED/ESME [Beta]

Discovers Azure VNet topology and produces schema-v3.0 JSON
compatible with the AED ESME architecture diagram renderer.

Captures VNets, vWAN hubs, subnets (with enrichment: service endpoints,
PE/PLS network policies, delegations), peerings, gateways, ExpressRoute
circuits, VPN sites, and on-premises connections.

Cross-platform: runs on Windows, macOS, Linux, and Azure Cloud Shell.

Usage:
  python get-network-topology.py [OPTIONS]
  python get-network-topology.py merge <file1> <file2> [<fileN>...] -o <output>

Options:
  --title <TITLE>           Diagram title (prompted if omitted)
  --vnet-id <ARM_ID>        Optional starting VNet ARM resource ID
  --vhub-id <ARM_ID>        Optional starting Virtual Hub ARM resource ID
  --subscription <ID>       Subscription ID or name
  --resource-group <NAME>   Resource group name
  --output <FILE>           Output file path
  --baseline <FILE>         Previous topology JSON to preserve user edits from
  --help                    Show this help message

Subcommands:
  merge                     Merge multiple topology files offline (no Azure login)

Topology Versioning:
  Each output includes a topologyVersion field (default: 1). Pass --baseline
  with a prior topology JSON to auto-increment the version counter and
  preserve all user-authored content (_layout positions, OnPremises edits,
  x-aed-* tags, user-created OnPremises sites).

Dependencies: Python 3.8+, Azure CLI 2.50+
  The script checks for these automatically and will prompt to
  install any missing tools or log in to Azure if needed.
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import PurePosixPath
from typing import Any

# ── Constants ────────────────────────────────────────────────────────────────
SCRIPT_VERSION = "0.5.0-beta"
SCHEMA_VERSION = "3.0"
GENERATOR_NAME = "aed-esme-networking/python"
MAX_RETRIES = 3
RETRY_BASE_DELAY = 2

# ── Error accumulation (global) ──────────────────────────────────────────────
_discovery_errors: list[dict[str, str]] = []

# ── Log file (global) ───────────────────────────────────────────────────────
_log_file_handle: Any = None
_log_file_path: str = ""

# ANSI escape sequence stripper
_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def _log_file_open(path: str) -> None:
    """Open the persistent log file for this script invocation."""
    global _log_file_handle, _log_file_path
    _log_file_path = path
    _log_file_handle = open(path, "w", encoding="utf-8")  # noqa: SIM115


def _log_file_close() -> None:
    """Close the persistent log file."""
    global _log_file_handle
    if _log_file_handle:
        _log_file_handle.close()
        _log_file_handle = None


def _log_to_file(msg: str) -> None:
    """Append a plain-text line with dual timestamps to the log file."""
    if not _log_file_handle:
        return
    now_utc = datetime.now(timezone.utc)
    now_local = datetime.now()
    # Detect local timezone abbreviation
    tz_abbr = time.strftime("%Z") or "local"
    utc_str = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    local_str = now_local.strftime("%H:%M:%S")
    # Strip ANSI codes
    clean_msg = _ANSI_RE.sub("", msg)
    _log_file_handle.write(f"[{utc_str} / {local_str} {tz_abbr}] {clean_msg}\n")
    _log_file_handle.flush()

# ── Logging ──────────────────────────────────────────────────────────────────
_USE_COLOR = sys.stderr.isatty() and not os.environ.get("NO_COLOR")

_C_RESET = "\033[0m" if _USE_COLOR else ""
_C_DIM = "\033[2m" if _USE_COLOR else ""
_C_BOLD = "\033[1m" if _USE_COLOR else ""
_C_CYAN = "\033[36m" if _USE_COLOR else ""
_C_YELLOW = "\033[33m" if _USE_COLOR else ""
_C_RED = "\033[31m" if _USE_COLOR else ""
_C_GREEN = "\033[32m" if _USE_COLOR else ""
_C_BLUE = "\033[34m" if _USE_COLOR else ""
_C_MAGENTA = "\033[35m" if _USE_COLOR else ""
_C_WHITE = "\033[97m" if _USE_COLOR else ""


def _timestamp() -> str:
    """Return local time as HH:MM:SS for console timestamp prefixes."""
    return datetime.now().strftime("%H:%M:%S")


def log_info(msg: str) -> None:
    print(f"{_C_DIM}  {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  {msg}")


def log_detail(msg: str) -> None:
    print(f"{_C_DIM}      {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"      {msg}")


def log_substep(msg: str) -> None:
    print(f"{_C_DIM}{_C_CYAN}          {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"          {msg}")


def log_found(msg: str) -> None:
    print(f"{_C_DIM}{_C_GREEN}              {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"              {msg}")


def log_warn(msg: str) -> None:
    print(f"{_C_YELLOW}  ▲ {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  WARN: {msg}")


def log_error(msg: str) -> None:
    print(f"{_C_RED}  ✖ {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  ERROR: {msg}")


def log_step(msg: str) -> None:
    ts = _timestamp()
    print(f"\n{_C_DIM}[{ts}]{_C_RESET} {_C_BOLD}{_C_CYAN}── {msg} ──{_C_RESET}", file=sys.stderr)
    _log_to_file(f"── {msg} ──")


def log_resource(msg: str) -> None:
    ts = _timestamp()
    print(f"\n{_C_DIM}[{ts}]{_C_RESET} {_C_GREEN}{_C_BOLD}  ● {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  ● {msg}")


def log_queue(msg: str) -> None:
    print(f"{_C_BLUE}              ↳ queued {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"              ↳ queued {msg}")


def log_dequeue(msg: str) -> None:
    print(f"{_C_MAGENTA}    ▸ Processing: {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"    ▸ Processing: {msg}")


class Spinner:
    """Simple animated spinner for long-running operations."""
    _FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

    def __init__(self, msg: str = "Loading…"):
        self._msg = msg
        self._running = False
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if not sys.stderr.isatty() or os.environ.get("NO_COLOR"):
            log_info(self._msg)
            return
        self._running = True
        self._thread = threading.Thread(target=self._spin, daemon=True)
        self._thread.start()

    def _spin(self) -> None:
        i = 0
        while self._running:
            frame = self._FRAMES[i % len(self._FRAMES)]
            print(f"\r{_C_DIM}  {frame} {self._msg}{_C_RESET}", end="", file=sys.stderr, flush=True)
            i += 1
            time.sleep(0.1)

    def stop(self) -> None:
        self._running = False
        if self._thread:
            self._thread.join(timeout=1)
        if sys.stderr.isatty() and not os.environ.get("NO_COLOR"):
            print("\r\033[K", end="", file=sys.stderr, flush=True)


def log_alert(*lines: str) -> None:
    print(f"\n{_C_RED}{_C_BOLD}  ╔══════════════════════════════════════════════════{_C_RESET}", file=sys.stderr)
    print(f"{_C_RED}{_C_BOLD}  ║  ⚠  {lines[0]}{_C_RESET}", file=sys.stderr)
    for line in lines[1:]:
        print(f"{_C_RED}  ║     {line}{_C_RESET}", file=sys.stderr)
    print(f"{_C_RED}{_C_BOLD}  ╚══════════════════════════════════════════════════{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  ALERT: {' | '.join(lines)}")


# ── Validation ───────────────────────────────────────────────────────────────
_ARM_RE = re.compile(
    r"^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[^/]+/providers/", re.IGNORECASE
)
_GUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def validate_arm_resource_id(value: str) -> bool:
    return bool(_ARM_RE.match(value))


def validate_subscription_guid(value: str) -> bool:
    return bool(_GUID_RE.match(value))


def arm_basename(arm_id: str) -> str:
    """Return the last segment of an ARM resource ID (like basename)."""
    return PurePosixPath(arm_id).name


def extract_sub_id(arm_id: str) -> str:
    m = re.match(r"^/subscriptions/([^/]+)/", arm_id, re.IGNORECASE)
    return m.group(1) if m else ""


def extract_rg(arm_id: str) -> str:
    m = re.match(
        r"^/subscriptions/[^/]+/resourceGroups/([^/]+)/", arm_id, re.IGNORECASE
    )
    return m.group(1) if m else ""


# ── Azure CLI wrapper ───────────────────────────────────────────────────────
def _az_executable() -> str:
    """Return the Azure CLI executable name.

    On Windows, subprocess.run() with list args does NOT apply PATHEXT, so we
    must use the explicit extension.  Prefer 'az.exe' (no cmd.exe layer).
    """
    if sys.platform == "win32":
        if shutil.which("az.exe"):
            return "az.exe"
        if shutil.which("az.cmd"):
            return "az.cmd"
        return "az.cmd"
    return "az"


_AZ_EXE = _az_executable()


def az_cli(args: list[str], *, allow_failure: bool = False) -> Any:
    """Run an Azure CLI command and return parsed JSON output."""
    cmd = [_AZ_EXE] + args + ["--output", "json"]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            stdin=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            return None
        if not result.stdout.strip():
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def _az_cli_raw(args: list[str], *, timeout: int = 120) -> subprocess.CompletedProcess | None:
    """Run an Azure CLI command and return the raw CompletedProcess (for stderr inspection)."""
    cmd = [_AZ_EXE] + args + ["--output", "json"]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def az_cli_text(args: list[str]) -> str | None:
    """Run an Azure CLI command and return raw text output (tsv)."""
    cmd = [_AZ_EXE] + args + ["--output", "tsv"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        if result.returncode != 0:
            return None
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def _parse_retry_after(stderr_text: str) -> int | None:
    """Extract Retry-After value in seconds from az CLI stderr on 429 responses."""
    if "429" not in stderr_text and "Too Many Requests" not in stderr_text:
        return None
    m = re.search(r"Retry-After[:\s]+(\d+)", stderr_text, re.IGNORECASE)
    if m:
        return int(m.group(1))
    return None


def _is_access_denied(raw: subprocess.CompletedProcess | None) -> bool:
    """Detect Access Denied (403 / authorization failure) from az CLI output.

    Returns True if the response indicates the caller lacks permissions
    for the requested scope.  Used by invoke_with_retry() to skip remaining
    retries — a 403 will never succeed on retry.
    """
    if raw is None:
        return False
    stderr = raw.stderr or ""
    # HTTP 403 status code
    if "403" in stderr:
        return True
    # Azure-specific authorization error codes / messages
    _AUTH_PATTERNS = (
        "AuthorizationFailed",
        "AuthorizationPermissionMismatch",
        "does not have authorization",
        "Forbidden",
        "AccessDenied",
        "InsufficientPrivileges",
    )
    for pat in _AUTH_PATTERNS:
        if pat.lower() in stderr.lower():
            return True
    return False


def invoke_with_retry(
    label: str,
    args: list[str],
    *,
    allow_failure: bool = False,
    error_scope: str = "",
    max_retries: int = 0,
    timeout: int = 120,
) -> Any:
    """Run an az CLI command with retries, exponential backoff, and 429 Retry-After handling.

    When error_scope is provided and all retries fail, the error is recorded
    in _discovery_errors instead of aborting.
    Use max_retries=1 for fallible lookups that should not retry on failure.

    Access Denied (403) responses are detected and fast-failed — remaining
    retries are skipped because a 403 will never succeed on retry.
    """
    effective_retries = max_retries if max_retries > 0 else MAX_RETRIES
    for attempt in range(1, effective_retries + 1):
        raw = _az_cli_raw(args, timeout=timeout)
        if raw is not None and raw.returncode == 0 and raw.stdout.strip():
            try:
                return json.loads(raw.stdout)
            except json.JSONDecodeError:
                pass

        # ── Access Denied fast-fail (GH #33) ──
        if _is_access_denied(raw):
            err_msg = f"Access Denied: {label}"
            _discovery_errors.append({
                "scope": error_scope or label,
                "error": err_msg,
                "category": "Access Denied",
            })
            log_warn(f"{label} — Access Denied (403), skipping retries")
            return [] if not allow_failure else None

        # Check for 429 Retry-After
        if raw is not None and raw.stderr:
            retry_after = _parse_retry_after(raw.stderr)
            if retry_after is not None and attempt < effective_retries:
                log_warn(f"{label} — HTTP 429, waiting {retry_after}s (Retry-After)…")
                time.sleep(retry_after)
                continue

        if attempt == effective_retries:
            if error_scope:
                # Categorize the failure
                category = "Timeout" if (raw is None or (raw is not None and raw.returncode is None)) else "API Failure"
                if raw is not None and raw.stderr and ("429" in raw.stderr or "Too Many Requests" in raw.stderr):
                    category = "Throttled"
                err_msg = f"Failed after {effective_retries} retries: {label}"
                _discovery_errors.append({"scope": error_scope, "error": err_msg, "category": category})
                log_warn(f"Non-fatal: {err_msg}")
                return [] if not allow_failure else None
            if not allow_failure:
                log_error(f"Failed after {effective_retries} retries: {label}")
            return [] if not allow_failure else None

        delay = RETRY_BASE_DELAY * (1 << (attempt - 1))
        log_warn(f"{label} — attempt {attempt} failed, retrying in {delay}s…")
        time.sleep(delay)
    return [] if not allow_failure else None


def invoke_graph_query_paginated(
    label: str,
    query: str,
    subscription: str,
    *,
    error_scope: str = "",
    id_field: str = "id",
) -> list[dict]:
    """Execute an Azure Resource Graph query with $skipToken pagination.

    Returns deduplicated results (by ARM resource ID) across all pages.
    """
    # On Windows, cmd.exe interprets newline+pipe as a shell pipe operator.
    # Flatten the query to a single line to prevent this.
    if sys.platform == "win32":
        query = re.sub(r"\s+", " ", query).strip()

    all_data: list[dict] = []
    seen_ids: set[str] = set()
    skip_token: str | None = None
    page = 0

    while True:
        page += 1
        args = ["graph", "query", "-q", query, "--subscriptions", subscription, "--first", "500"]
        if skip_token:
            args += ["--skip-token", skip_token]

        result = invoke_with_retry(
            f"{label} (page {page})",
            args,
            allow_failure=True,
            error_scope=error_scope,
        )
        if result is None:
            break

        page_data = result.get("data", []) if isinstance(result, dict) else []
        for item in page_data:
            item_id = item.get(id_field, "")
            id_lower = item_id.lower()
            if id_lower not in seen_ids:
                seen_ids.add(id_lower)
                all_data.append(item)

        skip_token = result.get("$skipToken") or result.get("skipToken") if isinstance(result, dict) else None
        if not skip_token:
            break

    if page > 1:
        log_info(f"Pagination: retrieved {len(all_data)} resources across {page} pages for {label}")

    # Warn when result count hits an exact page-size boundary — may indicate a
    # missing filter or unexpected truncation.
    PAGE_BOUNDARIES = {100, 500, 1000}
    if len(all_data) in PAGE_BOUNDARIES:
        log_warn(f"Query returned exactly {len(all_data)} results for '{label}' "
                 "— possible pagination/filter issue")

    return all_data


# ── Sleep Prevention ─────────────────────────────────────────────────────────
_caffeinate_proc: subprocess.Popen | None = None


def _is_interactive_session() -> bool:
    """Return True if running in a local interactive terminal (not SSH/Cloud Shell)."""
    if os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_CLIENT"):
        return False
    if os.environ.get("ACC_CLOUD"):
        return False  # Azure Cloud Shell
    return sys.stdin.isatty()


def prevent_sleep() -> None:
    """Ask user and activate platform-native sleep prevention."""
    global _caffeinate_proc

    if not _is_interactive_session():
        return  # SSH / Cloud Shell — no local display to manage

    choice = input("Prevent this machine from sleeping during discovery? [Y/n/q=exit]: ").strip() or "Y"
    if choice.lower() == "q":
        log_info("Exiting.")
        sys.exit(0)
    if choice.upper() != "Y":
        return

    if sys.platform == "darwin":
        # macOS: caffeinate is always available (ships with macOS)
        if shutil.which("caffeinate"):
            _caffeinate_proc = subprocess.Popen(
                ["caffeinate", "-i", "-s", "-w", str(os.getpid())],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            atexit.register(_restore_sleep)
            log_info("Sleep prevention active (caffeinate)  ✓")
        else:
            log_warn("caffeinate not found — sleep prevention unavailable.")
    elif sys.platform == "win32":
        # Windows: SetThreadExecutionState — built-in Win32 API
        try:
            import ctypes
            ES_CONTINUOUS = 0x80000000
            ES_SYSTEM_REQUIRED = 0x00000001
            ctypes.windll.kernel32.SetThreadExecutionState(
                ES_CONTINUOUS | ES_SYSTEM_REQUIRED
            )
            atexit.register(_restore_sleep)
            log_info("Sleep prevention active (SetThreadExecutionState)  ✓")
        except (OSError, AttributeError):
            log_warn("Could not set sleep prevention — continuing without it.")
    else:
        # Linux: systemd-inhibit could be used, but servers rarely sleep
        log_detail("Sleep prevention not needed on this platform.")


def _restore_sleep() -> None:
    """Clean up sleep prevention on exit."""
    global _caffeinate_proc
    if _caffeinate_proc is not None:
        try:
            _caffeinate_proc.terminate()
            _caffeinate_proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            try:
                _caffeinate_proc.kill()
            except OSError:
                pass
        _caffeinate_proc = None
    elif sys.platform == "win32":
        try:
            import ctypes
            ES_CONTINUOUS = 0x80000000
            ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS)
        except (OSError, AttributeError):
            pass


# ── Prerequisites ────────────────────────────────────────────────────────────
def check_prerequisites() -> dict[str, str]:
    """Verify Azure CLI is installed and user is logged in. Returns account info."""
    log_step("Checking Prerequisites")

    # Python version
    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    log_info(f"Python {py_ver}  ✓")

    # Azure CLI
    az_version_json = az_cli(["version"])
    if az_version_json is None:
        log_error("Azure CLI (az) is not installed or not in PATH.")
        log_detail("Install via:")
        log_detail("  macOS:         brew install azure-cli")
        log_detail("  Debian/Ubuntu: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash")
        log_detail("  Windows:       winget install Microsoft.AzureCLI")
        log_detail("  pip:           pip install azure-cli")
        log_detail("  Azure Cloud Shell: pre-installed")
        sys.exit(1)

    az_ver = az_version_json.get("azure-cli", "unknown")
    log_info(f"Azure CLI {az_ver}  ✓")

    # Azure CLI minimum version check
    _MIN_AZ_VERSION = "2.60.0"
    try:
        from packaging.version import Version
        if Version(az_ver) < Version(_MIN_AZ_VERSION):
            log_warn(f"Azure CLI {az_ver} is older than recommended minimum {_MIN_AZ_VERSION}.")
            log_detail("Older versions may have bugs with resource queries or interactive prompts.")
            log_detail("Update via: az upgrade")
            cont = input(f"Continue anyway? [y/N/q=exit]: ").strip() or "N"
            if cont.lower() == "q":
                log_info("Exiting.")
                sys.exit(0)
            if cont.upper() != "Y":
                log_info("Exiting. Please update Azure CLI and try again.")
                sys.exit(1)
    except ImportError:
        # packaging not available — fall back to simple tuple comparison
        try:
            cur = tuple(int(x) for x in az_ver.split(".")[:3])
            req = tuple(int(x) for x in _MIN_AZ_VERSION.split(".")[:3])
            if cur < req:
                log_warn(f"Azure CLI {az_ver} is older than recommended minimum {_MIN_AZ_VERSION}.")
                log_detail("Older versions may have bugs with resource queries or interactive prompts.")
                log_detail("Update via: az upgrade")
                cont = input(f"Continue anyway? [y/N/q=exit]: ").strip() or "N"
                if cont.lower() == "q":
                    log_info("Exiting.")
                    sys.exit(0)
                if cont.upper() != "Y":
                    log_info("Exiting. Please update Azure CLI and try again.")
                    sys.exit(1)
        except (ValueError, TypeError):
            pass  # Can't parse version — skip check

    # Azure CLI config: suppress interactive prompts (survey/telemetry)
    # On Windows, az.cmd blocks on stdin if these aren't set, causing hangs.
    if sys.platform == "win32":
        az_config_dir = os.environ.get("AZURE_CONFIG_DIR", os.path.expanduser("~/.azure"))
        az_config_file = os.path.join(az_config_dir, "config")
        needs_config = False
        if os.path.isfile(az_config_file):
            try:
                with open(az_config_file, "r") as f:
                    config_text = f.read().lower()
                if "collect_telemetry" not in config_text:
                    needs_config = True
            except OSError:
                needs_config = True
        else:
            needs_config = True

        if needs_config:
            log_warn("Azure CLI telemetry/survey prompts are not configured.")
            log_detail("On Windows, unconfigured prompts can cause the script to hang.")
            choice = input("Allow this script to disable interactive prompts? [Y/n/q=exit]: ").strip() or "Y"
            if choice.lower() == "q":
                log_info("Exiting.")
                sys.exit(0)
            if choice.upper() == "Y":
                log_info("Configuring Azure CLI: disabling interactive prompts…")
                subprocess.run(
                    [_AZ_EXE, "config", "set", "core.collect_telemetry=false",
                     "core.survey_message=false", "core.only_show_errors=true"],
                    capture_output=True, check=False, stdin=subprocess.DEVNULL,
                )
                log_info("Azure CLI prompts disabled  ✓")
            else:
                log_warn("Skipped — the script may hang if az CLI prompts for input.")
                log_detail("You can manually run: az config set core.collect_telemetry=false core.survey_message=false")

    # Azure login check
    account = az_cli(["account", "show"])
    if account is None:
        log_warn("You are not logged into Azure.")
        login_choice = input("Would you like to log in now? [Y/n/q=exit]: ").strip() or "Y"
        if login_choice.lower() == "q":
            log_info("Exiting.")
            sys.exit(0)
        if login_choice.upper() == "Y":
            tenant_id = input("Tenant ID (leave blank for default, q=exit): ").strip()
            if tenant_id.lower() == "q":
                log_info("Exiting.")
                sys.exit(0)
            if tenant_id:
                log_info(f"Logging in to tenant {tenant_id}...")
                subprocess.run(
                    [_AZ_EXE, "login", "--tenant", tenant_id, "--output", "none"],
                    check=False,
                )
            else:
                log_info("Logging in to default tenant…")
                subprocess.run([_AZ_EXE, "login", "--output", "none"], check=False)

            account = az_cli(["account", "show"])
            if account is None:
                log_error("Login failed. Please run 'az login' manually.")
                sys.exit(2)
        else:
            log_error("Azure login is required. Run 'az login' to authenticate.")
            sys.exit(2)

    current_sub = account.get("name", "")
    current_sub_id = account.get("id", "")
    current_tenant = account.get("tenantId", "")
    current_user = account.get("user", {}).get("name", "")
    log_info(f"Logged in as: {current_user}")
    log_info(f"Tenant:       {current_tenant}")
    log_info(f"Subscription: {current_sub}")

    # Offer to switch tenant/subscription or continue with current
    switch_choice = input("Continue with this tenant and subscription? [Y/n/q=exit]: ").strip() or "Y"
    if switch_choice.lower() == "q":
        log_info("Exiting.")
        sys.exit(0)
    if switch_choice.upper() != "Y":
        # List available tenants (use az account list for tenant display names)
        log_step("Switch Tenant")
        spinner = Spinner("Fetching available tenants…")
        spinner.start()
        subs_for_tenants = invoke_with_retry(
            "List subscriptions for tenants",
            ["account", "list", "--query", "[].{tenantId:tenantId, tenantDisplayName:tenantDisplayName}"],
            allow_failure=True, max_retries=1, timeout=30,
        ) or []
        spinner.stop()
        # Deduplicate by tenantId, pick first non-empty display name
        tenant_map: dict[str, str] = {}
        for s in subs_for_tenants:
            tid = s.get("tenantId", "")
            tname = s.get("tenantDisplayName") or ""
            if tid and (tid not in tenant_map or (not tenant_map[tid] and tname)):
                tenant_map[tid] = tname
        tenants = [{"tenantId": k, "displayName": v} for k, v in tenant_map.items()]
        if tenants:
            log_info("Available tenants:")
            for i, t in enumerate(tenants, 1):
                t_id = t["tenantId"]
                t_name = t["displayName"]
                marker = " (current)" if t_id == current_tenant else ""
                label = f"{t_name}  [{t_id}]" if t_name else f"[{t_id}]"
                print(f"  {i}) {label}{marker}", file=sys.stderr)
            print("  0) Enter a Tenant ID manually", file=sys.stderr)
            print("  q) Exit", file=sys.stderr)
            t_choice = input(f"Tenant [0-{len(tenants)}, q=exit]: ").strip()
            if t_choice.lower() == "q":
                log_info("Exiting.")
                sys.exit(0)
            elif t_choice.isdigit() and 1 <= int(t_choice) <= len(tenants):
                new_tenant = tenants[int(t_choice) - 1]["tenantId"]
                log_info(f"Logging in to tenant {new_tenant} (this may open a browser for MFA)...")
                subprocess.run(
                    [_AZ_EXE, "login", "--tenant", new_tenant, "--output", "none"],
                    check=False,
                )
                verify = az_cli(["account", "show"])
                if verify is None:
                    log_error("Login to new tenant failed.")
                    sys.exit(2)
                log_info("Switched successfully.")
                account = verify
                current_sub = account.get("name", "")
                current_sub_id = account.get("id", "")
            elif t_choice == "0":
                new_tenant = input("Enter Tenant ID (q=exit): ").strip()
                if new_tenant.lower() == "q":
                    log_info("Exiting.")
                    sys.exit(0)
                if new_tenant:
                    log_info(f"Logging in to tenant {new_tenant} (this may open a browser for MFA)...")
                    subprocess.run(
                        [_AZ_EXE, "login", "--tenant", new_tenant, "--output", "none"],
                        check=False,
                    )
                    verify = az_cli(["account", "show"])
                    if verify is None:
                        log_error("Login to new tenant failed.")
                        sys.exit(2)
                    log_info("Switched successfully.")
                    account = verify
                    current_sub = account.get("name", "")
                    current_sub_id = account.get("id", "")
                else:
                    log_warn("No tenant ID provided — continuing with current tenant.")
            else:
                log_warn("Invalid selection — continuing with current tenant.")
        else:
            # Fallback: no tenant list available, ask manually
            new_tenant = input("Enter the Tenant ID to switch to (q=exit): ").strip()
            if new_tenant.lower() == "q":
                log_info("Exiting.")
                sys.exit(0)
            if new_tenant:
                log_info(f"Logging in to tenant {new_tenant} (this may open a browser for MFA)...")
                subprocess.run(
                    [_AZ_EXE, "login", "--tenant", new_tenant, "--output", "none"],
                    check=False,
                )
                verify = az_cli(["account", "show"])
                if verify is None:
                    log_error("Login to new tenant failed.")
                    sys.exit(2)
                log_info("Switched successfully.")
                account = verify
                current_sub = account.get("name", "")
                current_sub_id = account.get("id", "")
            else:
                log_warn("No tenant ID provided — continuing with current tenant.")

    # Ensure resource-graph extension
    ext_check = az_cli(["extension", "show", "--name", "resource-graph"], allow_failure=True)
    if ext_check is None:
        log_warn("The 'resource-graph' Azure CLI extension is required but not installed.")
        ext_choice = input("Install it now? [Y/n/q=exit]: ").strip() or "Y"
        if ext_choice.lower() == "q":
            log_info("Exiting.")
            sys.exit(0)
        if ext_choice.upper() == "Y":
            log_info("Installing 'resource-graph' extension…")
            result = subprocess.run(
                [_AZ_EXE, "extension", "add", "--name", "resource-graph", "--yes", "--output", "none"],
                capture_output=True,
                check=False,
                stdin=subprocess.DEVNULL,
            )
            if result.returncode == 0:
                log_info("Extension 'resource-graph' installed  ✓")
            else:
                log_error("Failed to install 'resource-graph' extension.")
                log_detail("Install manually: az extension add --name resource-graph")
                sys.exit(1)
        else:
            log_error("The 'resource-graph' extension is required for this script.")
            log_detail("Install manually: az extension add --name resource-graph")
            sys.exit(1)

    log_info("Prerequisites satisfied  ✓")
    return account, current_sub_id, current_sub


# ── Interactive selection helpers ────────────────────────────────────────────
def prompt_selection(prompt: str, max_val: int) -> int:
    while True:
        choice = input(prompt).strip()
        if choice.lower() == "q":
            log_info("Exiting.")
            sys.exit(0)
        if choice.isdigit() and 1 <= int(choice) <= max_val:
            return int(choice)
        print(f"  Enter a number between 1 and {max_val} (or 'q' to exit).", file=sys.stderr)


def select_subscription() -> tuple[str, str]:
    log_step("Select Azure Subscription")
    subs = invoke_with_retry(
        "List subscriptions",
        ["account", "list", "--query", "[?state=='Enabled']"],
    )
    if not subs:
        log_error("No enabled subscriptions found.")
        sys.exit(1)

    for i, s in enumerate(subs, 1):
        print(f"  {i}) {s['name']}  [{s['id']}]", file=sys.stderr)

    idx = prompt_selection(f"Subscription [1-{len(subs)}]: ", len(subs))
    sub = subs[idx - 1]
    log_info(f"Selected: {sub['name']} ({sub['id']})")
    return sub["id"], sub["name"]


def select_resource_group(sub_id: str) -> str:
    log_step("Select Resource Group")
    rgs = invoke_with_retry(
        "List resource groups",
        ["group", "list", "--subscription", sub_id],
    )
    if not rgs:
        log_error("No resource groups found.")
        sys.exit(1)

    for i, rg in enumerate(rgs, 1):
        print(f"  {i}) {rg['name']}  ({rg.get('location', '')})", file=sys.stderr)

    idx = prompt_selection(f"Resource Group [1-{len(rgs)}]: ", len(rgs))
    name = rgs[idx - 1]["name"]
    log_info(f"Selected: {name}")
    return name


def select_vnet(sub_id: str, rg_name: str) -> tuple[str, str]:
    """Returns (starting_id, starting_type). Empty id means 'All'."""
    log_step("Select Starting Network")
    log_info("Discovery crawls outward from the selected network, following peerings, hub connections, and vWAN links.")

    # VNets
    log_detail(f"Querying VNets in resource group '{rg_name}'…")
    vnets = invoke_with_retry(
        "List VNets",
        ["network", "vnet", "list", "--subscription", sub_id, "--resource-group", rg_name],
    ) or []
    log_detail(f"Found {len(vnets)} VNet(s)")

    # Virtual Hubs
    log_detail(f"Querying Virtual Hubs in resource group '{rg_name}'…")
    vhubs = invoke_with_retry(
        "List vHubs",
        ["network", "vhub", "list", "--subscription", sub_id, "--resource-group", rg_name],
        allow_failure=True, max_retries=1, timeout=60,
    ) or []
    log_detail(f"Found {len(vhubs)} Virtual Hub(s)")

    total = len(vnets) + len(vhubs)
    if total == 0:
        log_warn(f"No VNets or Virtual Hubs found in '{rg_name}'.")
        sys.exit(1)

    if vnets:
        print("  VNets:", file=sys.stderr)
        for i, v in enumerate(vnets, 1):
            prefixes = ", ".join(v.get("addressSpace", {}).get("addressPrefixes", []))
            print(f"    {i}) {v['name']}  [{prefixes}]", file=sys.stderr)

    if vhubs:
        print("  Virtual Hubs:", file=sys.stderr)
        for i, h in enumerate(vhubs):
            num = len(vnets) + i + 1
            prefix = h.get("addressPrefix", "")
            loc = h.get("location", "")
            print(f"    {num}) {h['name']}  [{prefix}] ({loc})", file=sys.stderr)

    print(f"  0) All VNets and Virtual Hubs in {rg_name}", file=sys.stderr)
    print("  q) Exit", file=sys.stderr)

    choice = input(f"Select [0-{total}, q=exit] (0=all): ").strip()
    if choice.lower() == "q":
        log_info("Exiting.")
        sys.exit(0)
    if not choice or choice == "0":
        # Large environment warning
        log_warn("'All' mode will discover every VNet and Virtual Hub in this")
        log_warn("resource group, including all peered networks across subscriptions.")
        log_warn("In large environments this can take a very long time.")
        log_warn("Consider selecting a specific VNet or vHub as an entry point instead.")
        confirm = input("  Continue with 'All' mode? [y/N/q=exit]: ").strip()
        if confirm.lower() == "q":
            log_info("Exiting.")
            sys.exit(0)
        if confirm.upper() != "Y":
            log_info("Cancelled. Please select a specific resource.")
            return select_vnet(sub_id, rg_name)
        log_info(f"Will discover all VNets and Virtual Hubs in {rg_name}")
        return "", "All"

    if choice.isdigit():
        idx = int(choice)
        if 1 <= idx <= len(vnets):
            v = vnets[idx - 1]
            log_info(f"Starting from VNet: {v['name']}")
            return v["id"], "Microsoft.Network/virtualNetworks"
        elif len(vnets) < idx <= total:
            h = vhubs[idx - len(vnets) - 1]
            log_info(f"Starting from vHub: {h['name']}")
            return h["id"], "Microsoft.Network/virtualHubs"

    print("  Invalid selection.", file=sys.stderr)
    return select_vnet(sub_id, rg_name)


def prompt_title(existing: str) -> str:
    if existing:
        return existing
    title = input("Diagram title (q=exit): ").strip()
    if title.lower() == "q":
        log_info("Exiting.")
        sys.exit(0)
    if not title:
        title = f"Azure Network Topology — {datetime.now(timezone.utc).strftime('%Y-%m-%d')}"
    return title


# ── vWAN Hub detection ───────────────────────────────────────────────────────
_VHUB_GUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
)


def is_vhub_vnet_id(arm_id: str) -> bool:
    """True if the ARM id looks like a vWAN-managed VNet (HV_*/RG_*)."""
    lower = arm_id.lower()
    vnet_name = arm_basename(lower)
    m = re.match(r"^/subscriptions/[^/]*/resourcegroups/([^/]*)/", lower)
    rg = m.group(1) if m else ""
    return vnet_name.startswith("hv_") and rg.startswith("rg_")


def is_vhub_resource_id(arm_id: str) -> bool:
    return "microsoft.network/virtualhubs/" in arm_id.lower()


def resolve_vhub_id_from_vnet(vnet_id: str) -> str | None:
    """Resolve a vHub-managed VNet ID to the actual virtualHubs ARM resource ID."""
    sub_id = extract_sub_id(vnet_id)
    vnet_name = arm_basename(vnet_id)

    # Strip HV_ prefix
    without_prefix = re.sub(r"^[Hh][Vv]_", "", vnet_name)
    # Strip trailing _<guid>
    hub_name_guess = re.sub(
        r"_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        "",
        without_prefix,
    ) or without_prefix

    log_substep(f"Resolving vHub '{hub_name_guess}'...")

    # Approach 1: Resource Graph query by name (same subscription)
    if hub_name_guess:
        query = f"Resources | where type =~ 'microsoft.network/virtualhubs' and name =~ '{hub_name_guess}' | project id, name"
        result = invoke_with_retry(
            "Find vHub by name (same sub)",
            ["graph", "query", "-q", query, "--subscriptions", sub_id, "--first", "10"],
            max_retries=1, allow_failure=True,
        )
        data = (result or {}).get("data", [])
        if data:
            log_found(f"Resolved → {data[0]['id']}")
            return data[0]["id"]

        # Cross-subscription
        log_substep("Not in local subscription — searching cross-subscription...")
        result = invoke_with_retry(
            "Find vHub by name (all subs)",
            ["graph", "query", "-q", query, "--first", "10"],
            max_retries=1, allow_failure=True,
        )
        data = (result or {}).get("data", [])
        if data:
            log_found(f"Resolved (cross-subscription) → {arm_basename(data[0]['id'])}")
            return data[0]["id"]

    # Approach 2: List all vHubs in the subscription, match by name
    vhub_list = invoke_with_retry(
        "List vHubs",
        ["network", "vhub", "list", "--subscription", sub_id],
        max_retries=1, allow_failure=True,
    ) or []

    for h in vhub_list:
        if h.get("name", "").lower() == hub_name_guess.lower():
            log_found(f"Resolved → {arm_basename(h['id'])}")
            return h["id"]

    # Approach 3: If only one vHub exists, use it
    if len(vhub_list) == 1:
        log_found(f"Single vHub in subscription → {arm_basename(vhub_list[0]['id'])}")
        return vhub_list[0]["id"]

    log_substep("Could not resolve vHub from managed VNet")
    return None


# ── Discovery functions ─────────────────────────────────────────────────────
def _resolve_subnet_id(resource: dict, rtype_lower: str) -> str:
    """Extract the subnet ARM ID a resource is attached to."""
    props = resource.get("properties", {})

    if "networkinterfaces" in rtype_lower:
        ip_cfgs = props.get("ipConfigurations", [])
        if ip_cfgs:
            return ip_cfgs[0].get("properties", {}).get("subnet", {}).get("id", "")

    if "applicationgateways" in rtype_lower:
        gw_cfgs = props.get("gatewayIPConfigurations", [])
        if gw_cfgs:
            return gw_cfgs[0].get("properties", {}).get("subnet", {}).get("id", "")

    if "privateendpoints" in rtype_lower:
        return props.get("subnet", {}).get("id", "")

    if "loadbalancers" in rtype_lower:
        for fe in props.get("frontendIPConfigurations", []):
            sid = fe.get("properties", {}).get("subnet", {}).get("id", "")
            if sid:
                return sid
        return ""

    if any(
        t in rtype_lower
        for t in (
            "azurefirewalls",
            "virtualnetworkgateways",
            "bastionhosts",
            "natgateways",
            "dnsresolvers",
        )
    ):
        ip_cfgs = props.get("ipConfigurations", [])
        if ip_cfgs:
            return ip_cfgs[0].get("properties", {}).get("subnet", {}).get("id", "")

    return ""


def _determine_subtype(resource: dict, rtype_lower: str, subnet_name: str) -> str:
    """Determine the subType of a network resource."""
    props = resource.get("properties", {})

    if "virtualnetworkgateways" in rtype_lower:
        return props.get("gatewayType", "")
    if "applicationgateways" in rtype_lower:
        return (props.get("sku") or {}).get("tier", "")
    if "privateendpoints" in rtype_lower:
        for conn in props.get("privateLinkServiceConnections", []):
            groups = conn.get("properties", {}).get("groupIds", [])
            if groups:
                return groups[0]
        return ""
    if "loadbalancers" in rtype_lower:
        for fe in props.get("frontendIPConfigurations", []):
            if fe.get("properties", {}).get("publicIPAddress"):
                return "Public"
        return "Internal"
    if "dnsresolvers" in rtype_lower:
        if "inbound" in subnet_name.lower():
            return "Inbound"
        if "outbound" in subnet_name.lower():
            return "Outbound"
        return ""
    return ""


def _collect_public_ips(resource: dict, rtype_lower: str) -> list[str]:
    """Collect public IP addresses for gateways/firewalls/bastions/appgws."""
    props = resource.get("properties", {})
    pip_ids: list[str] = []

    if any(t in rtype_lower for t in ("virtualnetworkgateways", "azurefirewalls", "bastionhosts")):
        for ip_cfg in props.get("ipConfigurations", []):
            pid = ip_cfg.get("properties", {}).get("publicIPAddress", {}).get("id", "")
            if pid:
                pip_ids.append(pid)
    elif "applicationgateways" in rtype_lower:
        for fe in props.get("frontendIPConfigurations", []):
            pid = fe.get("properties", {}).get("publicIPAddress", {}).get("id", "")
            if pid:
                pip_ids.append(pid)

    ips: list[str] = []
    for pid in pip_ids:
        ip = az_cli_text(["network", "public-ip", "show", "--ids", pid, "--query", "ipAddress"])
        if ip:
            ips.append(ip)
    return ips


# ── VNet-injected / delegation-based resource discovery ──────────────────────
# These resource types integrate with VNets via subnet delegation or direct
# subnet reference, rather than through NICs.  They need a separate Resource
# Graph query because their subnet-reference property paths are completely
# different from the Microsoft.Network/* types.

_DELEGATED_TYPES = (
    "microsoft.web/sites",
    "microsoft.apimanagement/service",
    "microsoft.sql/managedinstances",
    "microsoft.app/managedenvironments",
    "microsoft.containerinstance/containergroups",
    "microsoft.databricks/workspaces",
    "microsoft.netapp/netappaccounts/capacitypools/volumes",
    "microsoft.kusto/clusters",
)


def _resolve_delegated_subnet_id(resource: dict, rtype_lower: str, vnet_id: str) -> str:
    """Extract the subnet ARM ID from a VNet-injected (delegated) resource."""
    props = resource.get("properties", {})

    if "microsoft.web/sites" in rtype_lower:
        return props.get("virtualNetworkSubnetId", "")

    if "apimanagement" in rtype_lower:
        return (props.get("virtualNetworkConfiguration") or {}).get("subnetResourceId", "")

    if "managedinstances" in rtype_lower:
        return props.get("subnetId", "")

    if "managedenvironments" in rtype_lower:
        return (props.get("vnetConfiguration") or {}).get("infrastructureSubnetId", "")

    if "containergroups" in rtype_lower:
        subnet_ids = props.get("subnetIds") or []
        if subnet_ids:
            return subnet_ids[0].get("id", "")
        return ""

    if "databricks" in rtype_lower:
        params = props.get("parameters") or {}
        vnet_val = (params.get("customVirtualNetworkId") or {}).get("value", "")
        if vnet_val and vnet_val.lower().rstrip("/") == vnet_id.lower().rstrip("/"):
            pub_name = (params.get("customPublicSubnetName") or {}).get("value", "")
            priv_name = (params.get("customPrivateSubnetName") or {}).get("value", "")
            subnet_name = pub_name or priv_name
            if subnet_name:
                return f"{vnet_id}/subnets/{subnet_name}"
        return ""

    if "netapp" in rtype_lower:
        return props.get("subnetId", "")

    if "kusto" in rtype_lower:
        return (props.get("virtualNetworkConfiguration") or {}).get("subnetId", "")

    return ""


def _determine_delegated_subtype(resource: dict, rtype_lower: str) -> str:
    """Determine the subType for a VNet-injected (delegated) resource."""
    props = resource.get("properties", {})

    if "microsoft.web/sites" in rtype_lower:
        kind = (resource.get("kind") or "").lower()
        if "functionapp" in kind:
            return "Function App"
        if "linux" in kind:
            return "Linux"
        return "Windows"

    if "apimanagement" in rtype_lower:
        return (props.get("sku") or {}).get("name", "")

    if "managedinstances" in rtype_lower:
        return (props.get("sku") or {}).get("tier", "")

    if "managedenvironments" in rtype_lower:
        return "Container Apps"

    if "databricks" in rtype_lower:
        return (resource.get("sku") or {}).get("name", "")

    if "netapp" in rtype_lower:
        return props.get("serviceLevel", "")

    if "kusto" in rtype_lower:
        return (props.get("sku") or {}).get("name", "")

    return ""


def discover_vnet(vnet_id: str) -> dict:
    """Discover a single VNet and return a schema-v2.0 vnet object."""
    vnet_json = invoke_with_retry(
        f"Get VNet {arm_basename(vnet_id)}",
        ["network", "vnet", "show", "--ids", vnet_id],
    )
    if not vnet_json:
        vnet_json = {}

    vnet_name = vnet_json.get("name") or arm_basename(vnet_id)
    address_prefixes = (vnet_json.get("addressSpace") or {}).get("addressPrefixes", [])
    location = vnet_json.get("location", "unknown")
    rg = vnet_json.get("resourceGroup", "unknown")
    dns_servers = (vnet_json.get("dhcpOptions") or {}).get("dnsServers", [])

    # ── Subnets ──
    subnets: list[dict] = []
    for s in vnet_json.get("subnets") or []:
        sid = s.get("id", "")
        sname = s.get("name", "")
        sprefix = s.get("addressPrefix") or ", ".join(s.get("addressPrefixes", [])) or "unknown"

        subnet_obj: dict[str, Any] = {
            "id": sid or sname,
            "name": sname,
            "addressPrefix": sprefix,
            "resources": [],
        }

        nsg_ref = (s.get("networkSecurityGroup") or {}).get("id", "")
        if nsg_ref:
            subnet_obj["nsg"] = {"id": nsg_ref, "name": arm_basename(nsg_ref)}

        rt_ref = (s.get("routeTable") or {}).get("id", "")
        if rt_ref:
            subnet_obj["routeTable"] = {"id": rt_ref, "name": arm_basename(rt_ref)}

        # Subnet enrichment (FR-005 to FR-011)
        svc_eps = s.get("serviceEndpoints") or []
        if svc_eps:
            subnet_obj["serviceEndpoints"] = [
                {k: v for k, v in {"service": ep.get("service", ""), "provisioningState": ep.get("provisioningState")}.items() if v}
                for ep in svc_eps if ep.get("service")
            ]

        pe_policy = s.get("privateEndpointNetworkPolicies", "")
        if pe_policy and pe_policy != "Enabled":
            subnet_obj["privateEndpointNetworkPolicies"] = pe_policy

        pls_policy = s.get("privateLinkServiceNetworkPolicies", "")
        if pls_policy and pls_policy != "Enabled":
            subnet_obj["privateLinkServiceNetworkPolicies"] = pls_policy

        delegations = s.get("delegations") or []
        if delegations:
            subnet_obj["delegations"] = [
                {"serviceName": d.get("serviceName") or (d.get("properties") or {}).get("serviceName", "")}
                for d in delegations
                if d.get("serviceName") or (d.get("properties") or {}).get("serviceName")
            ]

        subnets.append(subnet_obj)

    # Build a quick lookup: subnet name -> index
    subnet_idx: dict[str, int] = {s["name"]: i for i, s in enumerate(subnets)}

    # ── Resources per subnet (via Resource Graph) ──
    sub_id = extract_sub_id(vnet_id)

    log_substep("Querying subnet resources...")
    res_query = f"""Resources
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
        | where properties.ipConfigurations[0].properties.subnet.id startswith '{vnet_id}'
            or properties.gatewayIPConfigurations[0].properties.subnet.id startswith '{vnet_id}'
            or properties.subnet.id startswith '{vnet_id}'
            or properties.ipConfigurations[0].subnet.id startswith '{vnet_id}'
            or properties.ipConfiguration.properties.subnet.id startswith '{vnet_id}'
        | project id, name, type, location, resourceGroup, subscriptionId, properties, tags
        | order by type asc, name asc"""

    res_data = invoke_graph_query_paginated(
        f"Query resources for {vnet_name}",
        res_query,
        sub_id,
        error_scope=f"vnet/{vnet_name}/subnet-resources",
    )
    log_found(f"{len(res_data)} resource(s) found")

    # Also query VMs with NICs in this VNet
    vm_query = """Resources
        | where type =~ 'microsoft.compute/virtualMachines'
        | where isnotnull(properties.networkProfile)
        | mv-expand nic = properties.networkProfile.networkInterfaces
        | project vmId=id, vmName=name, vmType=type, nicId=tolower(nic.id), location, resourceGroup, subscriptionId, tags"""

    vms_data = invoke_graph_query_paginated(
        "Query VMs",
        vm_query,
        sub_id,
        error_scope=f"vnet/{vnet_name}/vm-query",
        id_field="vmId",
    )
    vm_by_nic: dict[str, dict] = {v["nicId"]: v for v in vms_data if v.get("nicId")}

    # Also query VMSS to resolve VMSS instance NICs → parent VMSS
    vmss_query = f"""Resources
        | where type =~ 'microsoft.compute/virtualMachineScaleSets'
        | where isnotnull(properties.virtualMachineProfile.networkProfile)
        | mv-expand nicCfg = properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations
        | mv-expand ipCfg = nicCfg.properties.ipConfigurations
        | where ipCfg.properties.subnet.id startswith '{vnet_id}'
        | project vmssId=id, vmssName=name, location, resourceGroup, subscriptionId, tags, sku"""

    vmss_data = invoke_graph_query_paginated(
        "Query VMSS",
        vmss_query,
        sub_id,
        error_scope=f"vnet/{vnet_name}/vmss-query",
        id_field="vmssId",
    )
    # Build VMSS lookup by ID (deduplicated — mv-expand may produce duplicates)
    vmss_by_id: dict[str, dict] = {v["vmssId"].lower(): v for v in vmss_data if v.get("vmssId")}

    # Map resources to subnets
    for res in res_data:
        rid = res.get("id", "")
        rname = res.get("name", "")
        rtype = res.get("type", "")
        rloc = res.get("location", "")
        rtags = res.get("tags") or {}
        rtype_lower = rtype.lower()

        rsubnet_id = _resolve_subnet_id(res, rtype_lower)
        if not rsubnet_id:
            continue

        # Validate resource actually belongs to the current VNet
        if not rsubnet_id.lower().startswith(vnet_id.lower()):
            log_warn(f"Skipping resource '{rname}' ({rtype}) — subnet '{rsubnet_id}' "
                     f"does not belong to VNet '{vnet_name}'")
            continue

        subnet_name = arm_basename(rsubnet_id)

        if subnet_name not in subnet_idx:
            continue

        # Handle NICs → resolve to VM or VMSS
        if "networkinterfaces" in rtype_lower:
            vm_ref = (res.get("properties") or {}).get("virtualMachine", {}).get("id", "")
            if vm_ref:
                # Check if this NIC belongs to a VMSS instance
                vmss_match = re.match(
                    r"(.+/providers/Microsoft\.Compute/virtualMachineScaleSets/[^/]+)",
                    vm_ref, re.IGNORECASE,
                )
                if vmss_match:
                    # VMSS instance NIC → resolve to parent VMSS (deduplicated)
                    vmss_id = vmss_match.group(1)
                    vmss_info = vmss_by_id.get(vmss_id.lower(), {})
                    vmss_name = vmss_info.get("vmssName") or arm_basename(vmss_id)
                    vmss_tags = vmss_info.get("tags") or {}
                    vmss_sku = (vmss_info.get("sku") or {}).get("name", "")

                    vmss_resource: dict[str, Any] = {
                        "id": vmss_id,
                        "name": vmss_name,
                        "type": "Microsoft.Compute/virtualMachineScaleSets",
                        "location": rloc,
                        "tags": vmss_tags,
                    }
                    if vmss_sku:
                        vmss_resource["subType"] = vmss_sku

                    slist = subnets[subnet_idx[subnet_name]]["resources"]
                    if not any(r["id"].lower() == vmss_id.lower() for r in slist):
                        slist.append(vmss_resource)
                else:
                    # Standalone VM NIC
                    vm_info = vm_by_nic.get(rid.lower(), {})
                    vm_name = vm_info.get("vmName") or arm_basename(vm_ref)
                    vm_tags = vm_info.get("tags") or {}

                    vm_resource: dict[str, Any] = {
                        "id": vm_ref,
                        "name": vm_name,
                        "type": "Microsoft.Compute/virtualMachines",
                        "location": rloc,
                        "tags": vm_tags,
                    }
                    slist = subnets[subnet_idx[subnet_name]]["resources"]
                    if not any(r["id"] == vm_ref for r in slist):
                        slist.append(vm_resource)
            continue

        sub_type = _determine_subtype(res, rtype_lower, subnet_name)
        public_ips = _collect_public_ips(res, rtype_lower)

        res_obj: dict[str, Any] = {
            "id": rid,
            "name": rname,
            "type": rtype,
            "location": rloc,
            "tags": rtags,
        }
        if sub_type:
            res_obj["subType"] = sub_type
        if public_ips:
            res_obj["publicIps"] = public_ips

        slist = subnets[subnet_idx[subnet_name]]["resources"]
        if not any(r["id"] == rid for r in slist):
            slist.append(res_obj)

    # ── VNet-injected / delegation-based resources ──
    log_substep("Querying VNet-injected resources (App Service, APIM, SQL MI, etc.)...")
    delegated_type_list = ", ".join(f"'{t}'" for t in _DELEGATED_TYPES)
    deleg_query = f"""Resources
        | where type in~ ({delegated_type_list})
        | where properties.virtualNetworkSubnetId startswith '{vnet_id}'
            or properties.subnetId startswith '{vnet_id}'
            or properties.virtualNetworkConfiguration.subnetResourceId startswith '{vnet_id}'
            or properties.subnetIds[0].id startswith '{vnet_id}'
            or properties.vnetConfiguration.infrastructureSubnetId startswith '{vnet_id}'
            or properties.parameters.customVirtualNetworkId.value =~ '{vnet_id}'
            or properties.virtualNetworkConfiguration.subnetId startswith '{vnet_id}'
        | project id, name, type, location, resourceGroup, subscriptionId, properties, tags, kind
        | order by type asc, name asc"""

    deleg_data = invoke_graph_query_paginated(
        f"Query VNet-injected resources for {vnet_name}",
        deleg_query,
        sub_id,
        error_scope=f"vnet/{vnet_name}/delegated-resources",
    )
    log_found(f"{len(deleg_data)} VNet-injected resource(s) found")

    for res in deleg_data:
        rid = res.get("id", "")
        rname = res.get("name", "")
        rtype = res.get("type", "")
        rloc = res.get("location", "")
        rtags = res.get("tags") or {}
        rtype_lower = rtype.lower()

        rsubnet_id = _resolve_delegated_subnet_id(res, rtype_lower, vnet_id)
        if not rsubnet_id:
            continue

        # Validate resource actually belongs to the current VNet
        if not rsubnet_id.lower().startswith(vnet_id.lower()):
            log_warn(f"Skipping delegated resource '{rname}' ({rtype}) — subnet '{rsubnet_id}' "
                     f"does not belong to VNet '{vnet_name}'")
            continue

        subnet_name = arm_basename(rsubnet_id)

        if subnet_name not in subnet_idx:
            continue

        sub_type = _determine_delegated_subtype(res, rtype_lower)

        res_obj: dict[str, Any] = {
            "id": rid,
            "name": rname,
            "type": rtype,
            "location": rloc,
            "tags": rtags,
        }
        if sub_type:
            res_obj["subType"] = sub_type

        slist = subnets[subnet_idx[subnet_name]]["resources"]
        if not any(r["id"] == rid for r in slist):
            slist.append(res_obj)

    # ── Peerings ──
    peerings: list[dict] = []
    for p in vnet_json.get("virtualNetworkPeerings") or []:
        peerings.append(
            {
                "name": p.get("name", ""),
                "remoteVnetId": (p.get("remoteVirtualNetwork") or {}).get("id", ""),
                "state": p.get("peeringState", "Unknown"),
                "allowForwardedTraffic": p.get("allowForwardedTraffic", False),
                "allowGatewayTransit": p.get("allowGatewayTransit", False),
                "useRemoteGateways": p.get("useRemoteGateways", False),
            }
        )

    vnet_obj: dict[str, Any] = {
        "id": vnet_id,
        "name": vnet_name,
        "addressSpace": address_prefixes,
        "location": location,
        "resourceGroup": rg,
        "subnets": subnets,
        "peerings": peerings,
    }
    vnet_tags = vnet_json.get("tags") or {}
    if vnet_tags:
        vnet_obj["tags"] = vnet_tags
    if dns_servers:
        vnet_obj["dnsServers"] = dns_servers

    return vnet_obj


# ── Discover a Virtual Hub ──────────────────────────────────────────────────
def discover_vhub(
    vhub_id: str,
    original_vnet_id: str,
    er_circuits: list[dict],
    lngs: list[dict],
) -> dict:
    """Discover a vWAN Virtual Hub and return a VNet-compatible schema object."""
    sub_id = extract_sub_id(vhub_id)

    log_detail(f"Hub resource: {arm_basename(vhub_id)}")

    vhub_json = invoke_with_retry(
        "Get vHub",
        ["network", "vhub", "show", "--ids", vhub_id],
        max_retries=1, allow_failure=True,
        error_scope=f"vhub/{arm_basename(vhub_id)}",
    ) or {}

    vhub_name = vhub_json.get("name") or arm_basename(vhub_id)
    location = vhub_json.get("location", "unknown")
    rg = vhub_json.get("resourceGroup", "unknown")
    address_prefix = vhub_json.get("addressPrefix", "")
    vwan_id = (vhub_json.get("virtualWan") or {}).get("id", "")

    # Hub-level properties
    hub_routing_pref = vhub_json.get("hubRoutingPreference", "ExpressRoute")
    allow_b2b = vhub_json.get("allowBranchToBranchTraffic", False)
    routing_state = vhub_json.get("routingState", "Unknown")
    hub_sku = vhub_json.get("sku", "Basic")
    hub_asn = vhub_json.get("virtualRouterAsn", 0)
    hub_router_ips = vhub_json.get("virtualRouterIps") or []

    address_space = [address_prefix] if address_prefix else []

    hub_resources: list[dict] = []

    # ── 1. ExpressRoute Gateways ──
    log_substep("Checking ER gateways...")
    er_gw_list = invoke_with_retry(
        "List vHub ER GWs",
        ["network", "express-route", "gateway", "list", "--subscription", sub_id, "--resource-group", rg],
        max_retries=1, allow_failure=True,
    ) or []
    if isinstance(er_gw_list, dict) and "value" in er_gw_list:
        er_gw_list = er_gw_list["value"]

    for gw in er_gw_list:
        # Skip gateways that belong to a different vHub in the same RG
        gw_vhub = (gw.get("virtualHub") or {}).get("id", "")
        if gw_vhub and gw_vhub.lower() != vhub_id.lower():
            continue
        gw_id = gw.get("id", "")
        gw_name = gw.get("name", "")
        gw_loc = gw.get("location", "")
        scale_min = (gw.get("autoScaleConfiguration") or {}).get("bounds", {}).get("min", 1)

        hub_resources.append(
            {
                "id": gw_id,
                "name": gw_name,
                "type": "Microsoft.Network/expressRouteGateways",
                "subType": "ExpressRoute",
                "location": gw_loc,
                "tags": {"x-aed-solution": "core-networking"},
                "metadata": {"scaleUnits": scale_min},
            }
        )

        # ER Gateway Connections → ER Circuits
        er_conns = invoke_with_retry(
            "List ER GW connections",
            [
                "network", "express-route", "gateway", "connection", "list",
                "--gateway-name", gw_name, "--subscription", sub_id, "--resource-group", rg,
            ],
            max_retries=1, allow_failure=True,
        ) or []

        if isinstance(er_conns, dict) and "value" in er_conns:
            er_conns = er_conns["value"]

        for conn in er_conns:
            raw_peering = conn.get("expressRouteCircuitPeering") or {}
            peering_id = raw_peering if isinstance(raw_peering, str) else raw_peering.get("id", "")
            if peering_id:
                circuit_arm_id = re.sub(r"/peerings/.*$", "", peering_id)
                circuit_json = invoke_with_retry(
                    "Get ER circuit",
                    ["network", "express-route", "show", "--ids", circuit_arm_id],
                    max_retries=1, allow_failure=True,
                ) or {}
                if circuit_json.get("name"):
                    sp = circuit_json.get("serviceProviderProperties") or {}
                    sku = circuit_json.get("sku") or {}
                    er_obj: dict[str, Any] = {
                        "id": circuit_json.get("id", ""),
                        "name": circuit_json.get("name", ""),
                        "location": circuit_json.get("location", ""),
                        "serviceProviderName": sp.get("serviceProviderName", "Unknown"),
                        "peeringLocation": sp.get("peeringLocation", "Unknown"),
                        "bandwidthInMbps": sp.get("bandwidthInMbps", 0),
                        "skuTier": sku.get("tier", "Standard"),
                        "skuFamily": sku.get("family", "MeteredData"),
                        "circuitProvisioningState": circuit_json.get("circuitProvisioningState", "Unknown"),
                        "serviceProviderProvisioningState": circuit_json.get("serviceProviderProvisioningState", "Unknown"),
                    }
                    peerings = _extract_peerings(circuit_json)
                    if peerings:
                        er_obj["peerings"] = peerings
                    er_circuits.append(er_obj)

    # ── 2. S2S VPN Gateways ──
    log_substep("Checking S2S VPN gateways...")
    vpn_gw_list = invoke_with_retry(
        "List vHub VPN GWs",
        ["network", "vpn-gateway", "list", "--subscription", sub_id, "--resource-group", rg],
        max_retries=1, allow_failure=True,
    ) or []

    if isinstance(vpn_gw_list, dict) and "value" in vpn_gw_list:
        vpn_gw_list = vpn_gw_list["value"]

    for gw in vpn_gw_list:
        # Skip gateways that belong to a different vHub in the same RG
        gw_vhub = (gw.get("virtualHub") or {}).get("id", "")
        if gw_vhub and gw_vhub.lower() != vhub_id.lower():
            continue
        gw_id = gw.get("id", "")
        gw_name = gw.get("name", "")
        gw_loc = gw.get("location", "")
        gw_scale = gw.get("vpnGatewayScaleUnit", 1)

        # S2S connections
        vpn_conns = invoke_with_retry(
            "List VPN GW connections",
            [
                "network", "vpn-gateway", "connection", "list",
                "--gateway-name", gw_name, "--subscription", sub_id, "--resource-group", rg,
            ],
            max_retries=1, allow_failure=True,
        ) or []

        if isinstance(vpn_conns, dict) and "value" in vpn_conns:
            vpn_conns = vpn_conns["value"]

        s2s_conn_count = len(vpn_conns)
        s2s_site_names = [c.get("name", "") for c in vpn_conns]

        if s2s_conn_count > 0:
            log_found(f"{s2s_conn_count} S2S VPN connection(s)")
            # Collect linked VPN sites
            for conn in vpn_conns:
                for link_conn in conn.get("vpnLinkConnections") or []:
                    site_link_id = (link_conn.get("vpnSiteLink") or {}).get("id", "")
                    if not site_link_id:
                        continue
                    vpn_site_id = re.sub(r"/vpnSiteLinks/.*$", "", site_link_id)
                    site_json = invoke_with_retry(
                        "Get VPN site",
                        ["network", "vpn-site", "show", "--ids", vpn_site_id],
                        max_retries=1, allow_failure=True,
                    ) or {}
                    if site_json.get("name"):
                        dev = site_json.get("deviceProperties") or {}
                        site_links = site_json.get("vpnSiteLinks") or []
                        lngs.append(
                            {
                                "id": site_json.get("id", ""),
                                "name": site_json.get("name", ""),
                                "location": site_json.get("location", ""),
                                "gatewayIpAddress": site_json.get("ipAddress") or (
                                    site_links[0].get("ipAddress", "") if site_links else ""
                                ),
                                "localAddressSpace": (site_json.get("addressSpace") or {}).get("addressPrefixes", []),
                                "deviceVendor": dev.get("deviceVendor", ""),
                                "deviceModel": dev.get("deviceModel", ""),
                                "linkSpeedInMbps": dev.get("linkSpeedInMbps", 0),
                            }
                        )

        hub_resources.append(
            {
                "id": gw_id,
                "name": gw_name,
                "type": "Microsoft.Network/vpnGateways",
                "subType": "Vpn",
                "location": gw_loc,
                "tags": {"x-aed-solution": "core-networking"},
                "metadata": {
                    "scaleUnits": gw_scale,
                    "s2sConnectionCount": s2s_conn_count,
                    "connectedSites": s2s_site_names,
                },
            }
        )

    # ── 3. P2S VPN Gateways ──
    log_substep("Checking P2S VPN gateways...")
    p2s_gw_list = invoke_with_retry(
        "List P2S VPN GWs",
        ["network", "p2s-vpn-gateway", "list", "--subscription", sub_id, "--resource-group", rg],
        max_retries=1, allow_failure=True,
    ) or []

    if isinstance(p2s_gw_list, dict) and "value" in p2s_gw_list:
        p2s_gw_list = p2s_gw_list["value"]

    for gw in p2s_gw_list:
        # Skip gateways that belong to a different vHub in the same RG
        gw_vhub = (gw.get("virtualHub") or {}).get("id", "")
        if gw_vhub and gw_vhub.lower() != vhub_id.lower():
            continue
        gw_id = gw.get("id", "")
        gw_name = gw.get("name", "")
        gw_loc = gw.get("location", "")
        gw_scale = gw.get("vpnGatewayScaleUnit", 1)
        config_id = (gw.get("vpnServerConfiguration") or {}).get("id", "")
        config_name = arm_basename(config_id) if config_id else ""
        client_pool = (gw.get("vpnClientAddressPool") or {}).get("addressPrefixes", [])

        hub_resources.append(
            {
                "id": gw_id,
                "name": gw_name,
                "type": "Microsoft.Network/p2sVpnGateways",
                "subType": "P2S",
                "location": gw_loc,
                "tags": {"x-aed-solution": "core-networking"},
                "metadata": {
                    "scaleUnits": gw_scale,
                    "vpnServerConfig": config_name,
                    "clientAddressPool": client_pool,
                },
            }
        )

    # ── 4. Azure Firewall ──
    log_substep("Checking Azure Firewall...")
    fw_id = (vhub_json.get("azureFirewall") or {}).get("id", "")
    if fw_id:
        fw_json = invoke_with_retry("Get vHub Firewall", ["network", "firewall", "show", "--ids", fw_id], max_retries=1, allow_failure=True) or {}
        fw_name = fw_json.get("name") or arm_basename(fw_id)
        fw_loc = fw_json.get("location", "")
        fw_sku_obj = fw_json.get("sku") or {}
        fw_policy = (fw_json.get("firewallPolicy") or {}).get("id", "")

        hub_resources.append(
            {
                "id": fw_id,
                "name": fw_name,
                "type": "Microsoft.Network/azureFirewalls",
                "subType": "vHub",
                "location": fw_loc,
                "tags": {"x-aed-solution": "core-networking"},
                "metadata": {
                    "sku": fw_sku_obj.get("name", "AZFW_Hub"),
                    "tier": fw_sku_obj.get("tier", "Standard"),
                    "firewallPolicyId": fw_policy,
                },
            }
        )

    # ── 5. BGP Connections (NVAs) ──
    log_substep("Checking BGP connections (NVAs)...")
    bgp_conns = invoke_with_retry(
        "List BGP connections",
        [
            "network", "vhub", "bgpconnection", "list",
            "--vhub-name", vhub_name, "--subscription", sub_id, "--resource-group", rg,
        ],
        max_retries=1, allow_failure=True,
    ) or []

    for bgp in bgp_conns:
        hub_resources.append(
            {
                "id": bgp.get("id", ""),
                "name": bgp.get("name", ""),
                "type": "Microsoft.Network/virtualHubs/bgpConnections",
                "subType": "NVA-BGP",
                "location": "",
                "tags": {"x-aed-solution": "core-networking"},
                "metadata": {
                    "peerIp": bgp.get("peerIp", ""),
                    "peerAsn": bgp.get("peerAsn", 0),
                    "connectionState": bgp.get("connectionState", "Unknown"),
                },
            }
        )

    # ── 6. Routing Intent ──
    log_substep("Checking routing intent...")
    routing_intent = None
    ri_list = invoke_with_retry(
        "List routing intents",
        [
            "network", "vhub", "routing-intent", "list",
            "--vhub-name", vhub_name, "--subscription", sub_id, "--resource-group", rg,
        ],
        max_retries=1, allow_failure=True,
    ) or []

    if ri_list:
        routing_intent = [
            {
                "name": ri.get("name", ""),
                "provisioningState": ri.get("provisioningState", ""),
                "routingPolicies": [
                    {
                        "name": rp.get("name", ""),
                        "destinations": rp.get("destinations", []),
                        "nextHop": rp.get("nextHop", ""),
                    }
                    for rp in ri.get("routingPolicies") or []
                ],
            }
            for ri in ri_list
        ]

    # ── 7. Route Tables ──
    log_substep("Checking route tables...")
    route_tables: list[dict] = []
    rt_list = invoke_with_retry(
        "List hub route tables",
        [
            "network", "vhub", "route-table", "list",
            "--vhub-name", vhub_name, "--subscription", sub_id, "--resource-group", rg,
        ],
        max_retries=1, allow_failure=True,
    ) or []

    if rt_list:
        route_tables = [
            {
                "id": rt.get("id", ""),
                "name": rt.get("name", ""),
                "provisioningState": rt.get("provisioningState", ""),
                "labels": rt.get("labels", []),
                "routes": [
                    {
                        "name": r.get("name", ""),
                        "destinationType": r.get("destinationType", ""),
                        "destinations": r.get("destinations", []),
                        "nextHopType": r.get("nextHopType", ""),
                        "nextHop": r.get("nextHop", ""),
                    }
                    for r in rt.get("routes") or []
                ],
            }
            for rt in rt_list
        ]

    # ── Build pseudo-subnet for hub resources ──
    subnets: list[dict] = []
    if hub_resources:
        subnets = [
            {
                "id": "hub-resources",
                "name": "Hub Resources",
                "addressPrefix": address_prefix,
                "resources": hub_resources,
            }
        ]

    # ── 8. Hub VNet Connections (spoke peerings) ──
    log_substep("Checking spoke connections...")
    peerings: list[dict] = []
    hub_conns = invoke_with_retry(
        "List vHub connections",
        [
            "network", "vhub", "connection", "list",
            "--vhub-name", vhub_name, "--subscription", sub_id, "--resource-group", rg,
        ],
        max_retries=1, allow_failure=True,
    ) or []

    log_found(f"{len(hub_conns)} spoke connection(s) found")

    for conn in hub_conns:
        remote_vnet_id = (conn.get("remoteVirtualNetwork") or {}).get("id", "")
        if not remote_vnet_id:
            continue

        routing_cfg = conn.get("routingConfiguration") or {}
        assoc_rt = arm_basename((routing_cfg.get("associatedRouteTable") or {}).get("id", ""))
        prop_labels = (routing_cfg.get("propagatedRouteTables") or {}).get("labels", [])
        static_routes = [
            {"name": r.get("name", ""), "addressPrefixes": r.get("addressPrefixes", []),
             "nextHopIpAddress": r.get("nextHopIpAddress", "")}
            for r in ((routing_cfg.get("vnetRoutes") or {}).get("staticRoutes") or [])
        ]

        peerings.append(
            {
                "name": conn.get("name", ""),
                "remoteVnetId": remote_vnet_id,
                "state": conn.get("provisioningState", "Unknown"),
                "allowForwardedTraffic": conn.get("allowHubToRemoteVnetTransit", False),
                "allowGatewayTransit": conn.get("allowRemoteVnetToUseHubVnetGateways", False),
                "useRemoteGateways": False,
                "_hubConnectionMetadata": {
                    "enableInternetSecurity": conn.get("enableInternetSecurity", False),
                    "associatedRouteTable": assoc_rt,
                    "propagatedLabels": prop_labels,
                    "staticRoutes": static_routes,
                },
            }
        )

    # ── 9. Inter-hub peerings (via vWAN sibling hubs) ──
    interhub_peers: list[dict] = []
    if vwan_id:
        log_substep("Checking vWAN inter-hub links...")
        vwan_json = invoke_with_retry("Get vWAN", ["network", "vwan", "show", "--ids", vwan_id], max_retries=1, allow_failure=True) or {}

        for hub_ref in vwan_json.get("virtualHubs") or []:
            sibling_id = hub_ref.get("id", "")
            if not sibling_id or sibling_id.lower() == vhub_id.lower():
                continue
            sibling_name = arm_basename(sibling_id)
            log_found(f"Sibling hub: {sibling_name}")

            interhub_peers.append({"hubId": sibling_id, "hubName": sibling_name})
            peerings.append(
                {
                    "name": f"interhub-{sibling_name}",
                    "remoteVnetId": sibling_id,
                    "state": "Connected",
                    "allowForwardedTraffic": True,
                    "allowGatewayTransit": True,
                    "useRemoteGateways": False,
                    "_isInterHubPeering": True,
                }
            )
            log_found(f"Linked → {sibling_name}")

    # Use the original HV_ VNet ID so peering connections still match
    output_id = original_vnet_id

    # ── Build result ──
    result: dict[str, Any] = {
        "id": output_id,
        "name": vhub_name,
        "addressSpace": address_space,
        "location": location,
        "resourceGroup": rg,
        "subnets": subnets,
        "peerings": peerings,
        "_isVirtualHub": True,
        "_vhubResourceId": vhub_id,
        "_hubConfig": {
            "sku": hub_sku,
            "routingPreference": hub_routing_pref,
            "routingState": routing_state,
            "allowBranchToBranchTraffic": allow_b2b,
            "virtualRouterAsn": hub_asn,
            "virtualRouterIps": hub_router_ips,
        },
    }
    if vwan_id:
        result["_vwanId"] = vwan_id
    vhub_tags = vhub_json.get("tags") or {}
    if vhub_tags:
        result["tags"] = vhub_tags
    if routing_intent:
        result["_hubConfig"]["routingIntent"] = routing_intent
    if route_tables:
        result["_hubConfig"]["routeTables"] = route_tables
    if interhub_peers:
        result["_hubConfig"]["interhubPeers"] = interhub_peers

    return result


# ── External connectivity ────────────────────────────────────────────────────
def _extract_peerings(circuit_json: dict) -> list[dict]:
    """Extract peering details from an ER circuit JSON response."""
    raw = circuit_json.get("peerings") or []
    result: list[dict] = []
    for p in raw:
        obj: dict[str, Any] = {
            "peeringType": p.get("peeringType", ""),
            "state": p.get("state", ""),
        }
        if p.get("vlanId") is not None:
            obj["vlanId"] = p["vlanId"]
        if p.get("primaryPeerAddressPrefix"):
            obj["primaryPeerAddressPrefix"] = p["primaryPeerAddressPrefix"]
        if p.get("secondaryPeerAddressPrefix"):
            obj["secondaryPeerAddressPrefix"] = p["secondaryPeerAddressPrefix"]
        if p.get("peerASN") is not None:
            obj["peerASN"] = p["peerASN"]
        ms_cfg = p.get("microsoftPeeringConfig") or {}
        if ms_cfg.get("advertisedPublicPrefixes"):
            obj["advertisedPublicPrefixes"] = ms_cfg["advertisedPublicPrefixes"]
        if ms_cfg.get("advertisedPublicPrefixesState"):
            obj["advertisedPublicPrefixesState"] = ms_cfg["advertisedPublicPrefixesState"]
        result.append(obj)
    return result


def _synthesize_on_premises(er_circuits: list[dict], lngs_list: list[dict]) -> list[dict]:
    """Synthesise on-premises site entries from ER circuit private peerings and LNGs.

    Each AzurePrivatePeering with a peerASN produces one on-premises site keyed
    by (circuitId, peerASN).  If no private peerings expose an ASN we fall back
    to one site per circuit using peering-location as the identifier.
    """
    sites: list[dict] = []
    seen: set[str] = set()

    for circuit in er_circuits:
        circuit_id = circuit.get("id", "")
        provider = circuit.get("serviceProviderName", "")
        peering_loc = circuit.get("peeringLocation", "") or circuit.get("location", "")
        peerings = circuit.get("peerings") or []

        private_peerings = [
            p for p in peerings
            if (p.get("peeringType") or "").lower() == "azureprivatepeering"
            and p.get("peerASN") is not None
        ]

        if private_peerings:
            for p in private_peerings:
                asn = p["peerASN"]
                key = f"{circuit_id.lower()}|asn-{asn}"
                if key in seen:
                    continue
                seen.add(key)
                loc_slug = (peering_loc or "unknown").lower().replace(" ", "-")
                site_id = f"onprem-asn-{asn}-{loc_slug}"
                name = f"ASN {asn}"
                if peering_loc:
                    name += f" \u2013 {peering_loc}"
                if provider and provider != "Unknown":
                    name += f" ({provider})"
                site: dict[str, Any] = {
                    "id": site_id,
                    "name": name,
                    "location": peering_loc,
                    "circuitId": circuit_id,
                    "peerASN": asn,
                }
                if provider and provider != "Unknown":
                    site["serviceProviderName"] = provider
                sites.append(site)
        else:
            # Fallback: no ASN available — one site per circuit
            key = circuit_id.lower()
            if key in seen:
                continue
            seen.add(key)
            loc_slug = (peering_loc or "unknown").lower().replace(" ", "-")
            site_id = f"onprem-circuit-{loc_slug}-{circuit.get('name', 'unknown')}"
            name = peering_loc or circuit.get("name", "On-Premises")
            if provider and provider != "Unknown":
                name += f" ({provider})"
            site = {
                "id": site_id,
                "name": name,
                "location": peering_loc,
                "circuitId": circuit_id,
            }
            if provider and provider != "Unknown":
                site["serviceProviderName"] = provider
            sites.append(site)

    return sites


def discover_external_connectivity(
    vnet_id: str,
    er_circuits: list[dict],
    lngs_list: list[dict],
    gw_connections: list[dict],
) -> None:
    sub_id = extract_sub_id(vnet_id)
    rg = extract_rg(vnet_id)
    vnet_name = arm_basename(vnet_id)

    # ExpressRoute circuits
    er_json = invoke_with_retry(
        "List ER circuits",
        ["network", "express-route", "list", "--subscription", sub_id, "--resource-group", rg],
        max_retries=1, allow_failure=True,
        error_scope=f"vnet/{vnet_name}/er-circuits",
    ) or []

    for circuit in er_json:
        sp = circuit.get("serviceProviderProperties") or {}
        sku = circuit.get("sku") or {}
        er_obj: dict[str, Any] = {
            "id": circuit.get("id", ""),
            "name": circuit.get("name", ""),
            "location": circuit.get("location", ""),
            "serviceProviderName": sp.get("serviceProviderName", "Unknown"),
            "peeringLocation": sp.get("peeringLocation", "Unknown"),
            "bandwidthInMbps": sp.get("bandwidthInMbps", 0),
            "skuTier": sku.get("tier", "Standard"),
            "skuFamily": sku.get("family", "MeteredData"),
            "circuitProvisioningState": circuit.get("circuitProvisioningState", "Unknown"),
            "serviceProviderProvisioningState": circuit.get("serviceProviderProvisioningState", "Unknown"),
        }
        peerings = _extract_peerings(circuit)
        if peerings:
            er_obj["peerings"] = peerings
        er_circuits.append(er_obj)

    # Local Network Gateways
    lng_json = invoke_with_retry(
        "List LNGs",
        ["network", "local-gateway", "list", "--subscription", sub_id, "--resource-group", rg],
        max_retries=1, allow_failure=True,
        error_scope=f"vnet/{vnet_name}/lngs",
    ) or []

    for lng in lng_json:
        lngs_list.append(
            {
                "id": lng.get("id", ""),
                "name": lng.get("name", ""),
                "location": lng.get("location", ""),
                "gatewayIpAddress": lng.get("gatewayIpAddress", "Unknown"),
                "localAddressSpace": (lng.get("localNetworkAddressSpace") or {}).get("addressPrefixes", []),
            }
        )

    # ── VPN/ER Gateway Connections (GH #35 fix) ──
    # Primary: az CLI list in the VNet's RG
    conn_json = invoke_with_retry(
        "List GW connections",
        ["network", "vpn-connection", "list", "--subscription", sub_id, "--resource-group", rg],
        allow_failure=True,
        error_scope=f"vnet/{vnet_name}/gw-connections",
    ) or []

    # Fallback: Resource Graph query if CLI returned nothing
    # (catches connections in environments where the CLI command times out or
    # the gateway/connections are in a different RG within the same subscription)
    if not conn_json:
        log_detail(f"CLI returned no connections for {rg} — trying Resource Graph fallback…")
        graph_conns = invoke_graph_query_paginated(
            f"Query connections for {vnet_name}",
            f"""Resources
                | where type =~ 'microsoft.network/connections'
                | where resourceGroup =~ '{rg}'
                    or properties.virtualNetworkGateway1.id contains '{vnet_id}'
                | project id, name, type, resourceGroup,
                    connectionType = tostring(properties.connectionType),
                    gatewayId = tostring(properties.virtualNetworkGateway1.id),
                    circuitId = tostring(properties.peer.id),
                    localNetworkGatewayId = tostring(properties.localNetworkGateway2.id),
                    connectionStatus = tostring(properties.connectionStatus),
                    routingWeight = toint(properties.routingWeight)""",
            sub_id,
            error_scope=f"vnet/{vnet_name}/gw-connections-graph",
        )
        for c in graph_conns:
            gw_connections.append(
                {
                    "id": c.get("id", ""),
                    "name": c.get("name", ""),
                    "connectionType": c.get("connectionType", "Unknown"),
                    "gatewayId": c.get("gatewayId", ""),
                    "circuitId": c.get("circuitId", ""),
                    "localNetworkGatewayId": c.get("localNetworkGatewayId", ""),
                    "connectionStatus": c.get("connectionStatus", "Unknown"),
                    "routingWeight": c.get("routingWeight", 0),
                }
            )
        if graph_conns:
            log_found(f"{len(graph_conns)} connection(s) found via Resource Graph fallback")
    else:
        for conn in conn_json:
            gw_connections.append(
                {
                    "id": conn.get("id", ""),
                    "name": conn.get("name", ""),
                    "connectionType": conn.get("connectionType", "Unknown"),
                    "gatewayId": (conn.get("virtualNetworkGateway1") or {}).get("id", ""),
                    "circuitId": (conn.get("peer") or {}).get("id", ""),
                    "localNetworkGatewayId": (conn.get("localNetworkGateway2") or {}).get("id", ""),
                    "connectionStatus": conn.get("connectionStatus", "Unknown"),
                    "routingWeight": conn.get("routingWeight", 0),
                }
            )
        log_found(f"{len(conn_json)} connection(s) found")


# ── Connected-component builder (union-find) ────────────────────────────────
def build_connected_components(ids: list[str]) -> list[list[str]]:
    """Partition VNet IDs into connected components using union-find on peerings."""
    parent: dict[str, str] = {}
    id_map: dict[str, str] = {}  # lowercase -> original

    for vid in ids:
        lower = vid.lower()
        parent[lower] = lower
        id_map[lower] = vid

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]  # path compression
            x = parent[x]
        return x

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    # Scan peerings and union connected networks
    for vid in ids:
        vid_lower = vid.lower()

        if is_vhub_resource_id(vid):
            log_info(f"  Scanning hub connections for {arm_basename(vid)}…")
            vhub_name = arm_basename(vid)
            vhub_sub = extract_sub_id(vid)
            vhub_rg = extract_rg(vid)

            hub_conn_ids = invoke_with_retry(
                f"List vHub connections for {vhub_name}",
                [
                    "network", "vhub", "connection", "list",
                    "--vhub-name", vhub_name, "--subscription", vhub_sub,
                    "--resource-group", vhub_rg,
                    "--query", "[].remoteVirtualNetwork.id",
                ],
                max_retries=1, allow_failure=True,
            ) or []

            for peer in hub_conn_ids:
                peer_lower = peer.lower() if isinstance(peer, str) else ""
                if peer_lower in parent:
                    union(vid_lower, peer_lower)
        else:
            log_info(f"  Scanning peerings for {arm_basename(vid)}…")
            peer_ids = invoke_with_retry(
                "Peek VNet peerings",
                [
                    "network", "vnet", "show", "--ids", vid,
                    "--query", "virtualNetworkPeerings[].remoteVirtualNetwork.id",
                ],
                max_retries=1, allow_failure=True,
            ) or []

            for peer in peer_ids:
                peer_lower = peer.lower() if isinstance(peer, str) else ""
                if peer_lower in parent:
                    union(vid_lower, peer_lower)

    # Group by root
    groups: dict[str, list[str]] = defaultdict(list)
    for vid in ids:
        root = find(vid.lower())
        groups[root].append(vid)

    return list(groups.values())


# ── Merge Engine (T210) ─────────────────────────────────────────────────────

# OnPremises user-editable fields that should survive re-discovery
_ONPREM_USER_FIELDS = ("name", "description", "ipRanges", "notes")


def merge_user_edits(
    baseline_data: dict[str, Any],
    target_data: dict[str, Any],
) -> dict[str, int]:
    """Apply user-authored content from baseline onto target, matched by ARM resource ID.

    Merge rules:
      - ``_layout``: copy from baseline to matching resource
      - OnPremises ``name``, ``description``, ``ipRanges``, ``notes``: copy from baseline
      - ``x-aed-*`` tags: overlay onto target (baseline wins on conflict)
      - Non-``x-aed-*`` tags: always from target (authoritative Azure source)
      - Orphaned baseline resources (deleted from Azure): drop silently, log warning
      - New target resources (not in baseline): keep as-is
      - OnPremises entries in baseline with no match in target: preserve (append)
      - ``topologyVersion``: increment from baseline

    Returns summary dict with counts:
      ``applied_layouts``, ``merged_edits``, ``merged_tags``,
      ``preserved_onprem``, ``orphaned``, ``new_resources``
    """
    summary = {
        "applied_layouts": 0,
        "merged_edits": 0,
        "merged_tags": 0,
        "preserved_onprem": 0,
        "orphaned": 0,
        "new_resources": 0,
    }

    # ── Build baseline indexes (keyed by lowercase ARM ID) ──
    baseline_by_id: dict[str, dict] = {}
    for collection in ("vnets", "expressRouteCircuits"):
        for item in baseline_data.get(collection, []):
            baseline_by_id[item["id"].lower()] = item

    baseline_onprem_by_id: dict[str, dict] = {}
    for site in baseline_data.get("onPremises", []):
        baseline_onprem_by_id[site["id"].lower()] = site

    # ── Build target indexes ──
    target_ids: set[str] = set()
    for collection in ("vnets", "expressRouteCircuits"):
        for item in target_data.get(collection, []):
            target_ids.add(item["id"].lower())
    for site in target_data.get("onPremises", []):
        target_ids.add(site["id"].lower())

    # ── Apply layouts and x-aed-* tags to VNets and ER circuits ──
    for collection in ("vnets", "expressRouteCircuits"):
        for item in target_data.get(collection, []):
            key = item["id"].lower()
            baseline_item = baseline_by_id.get(key)
            if not baseline_item:
                summary["new_resources"] += 1
                continue

            # _layout
            if "_layout" in baseline_item:
                item["_layout"] = baseline_item["_layout"]
                summary["applied_layouts"] += 1

            # x-aed-* tags: overlay from baseline, keep non-x-aed-* from target
            baseline_tags = baseline_item.get("tags", {})
            aed_tags = {k: v for k, v in baseline_tags.items() if k.startswith("x-aed-")}
            if aed_tags:
                target_tags = item.get("tags", {})
                target_tags.update(aed_tags)
                item["tags"] = target_tags
                summary["merged_tags"] += 1

    # ── Apply layouts, user edits, and x-aed-* tags to onPremises ──
    matched_onprem_ids: set[str] = set()
    for site in target_data.get("onPremises", []):
        key = site["id"].lower()
        baseline_site = baseline_onprem_by_id.get(key)
        if not baseline_site:
            summary["new_resources"] += 1
            continue

        matched_onprem_ids.add(key)

        # _layout
        if "_layout" in baseline_site:
            site["_layout"] = baseline_site["_layout"]
            summary["applied_layouts"] += 1

        # User-editable fields
        edited = False
        for field in _ONPREM_USER_FIELDS:
            if field in baseline_site and baseline_site[field]:
                site[field] = baseline_site[field]
                edited = True
        if edited:
            summary["merged_edits"] += 1

    # ── Preserve user-created onPremises entries not in target ──
    for key, baseline_site in baseline_onprem_by_id.items():
        if key not in matched_onprem_ids and key not in target_ids:
            # User-created site that doesn't exist in the new discovery — preserve it
            if "onPremises" not in target_data:
                target_data["onPremises"] = []
            target_data["onPremises"].append(baseline_site)
            summary["preserved_onprem"] += 1

    # ── Count orphaned baseline resources (in baseline but not in target) ──
    for key in baseline_by_id:
        if key not in target_ids:
            summary["orphaned"] += 1
            log_warn(f"Orphaned baseline resource (removed from Azure): {baseline_by_id[key].get('name', key)}")

    # ── topologyVersion: increment from baseline ──
    prev = baseline_data.get("topologyVersion")
    if isinstance(prev, int) and prev >= 1:
        target_data["topologyVersion"] = prev + 1
    else:
        target_data["topologyVersion"] = target_data.get("topologyVersion", 1)

    return summary


def merge_files(file_paths: list[str], output_path: str) -> None:
    """Merge multiple topology files left-to-right and write result.

    file1 is the base, file2 overlays user edits onto it, file3 overlays
    onto the result, etc. Cross-file merge also deduplicates VNets/circuits/
    connections by ARM resource ID (union of resources from all files).
    """
    if len(file_paths) < 2:
        log_error("merge requires at least 2 input files")
        sys.exit(1)

    # Load base
    log_info(f"Loading base: {file_paths[0]}")
    with open(file_paths[0], "r", encoding="utf-8") as f:
        result = json.load(f)

    # Overlay each subsequent file
    for i, path in enumerate(file_paths[1:], start=2):
        log_info(f"Merging file {i}/{len(file_paths)}: {path}")
        with open(path, "r", encoding="utf-8") as f:
            overlay = json.load(f)

        # Deduplicate: union resources from overlay into result by ARM ID
        _union_resources(result, overlay)

        # Apply user edits from overlay onto the union result
        summary = merge_user_edits(overlay, result)

        log_info(f"  Step {i-1}: layouts={summary['applied_layouts']}, "
                 f"edits={summary['merged_edits']}, tags={summary['merged_tags']}, "
                 f"preserved_onprem={summary['preserved_onprem']}, "
                 f"orphaned={summary['orphaned']}, new={summary['new_resources']}")

    # Write output
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        f.write("\n")

    log_info(f"Merged {len(file_paths)} files → {output_path}")


def _union_resources(base: dict, overlay: dict) -> None:
    """Add resources from overlay that don't already exist in base (by ARM ID)."""
    for collection in ("vnets", "expressRouteCircuits"):
        existing_ids = {item["id"].lower() for item in base.get(collection, [])}
        for item in overlay.get(collection, []):
            if item["id"].lower() not in existing_ids:
                base.setdefault(collection, []).append(item)
                existing_ids.add(item["id"].lower())

    # connections — deduplicate by (sourceVNet + targetVNet, case-insensitive)
    def _conn_key(c: dict) -> str:
        return f"{c.get('sourceVNet', {}).get('id', '')}|{c.get('targetVNet', {}).get('id', '')}".lower()

    existing_conn_keys = {_conn_key(c) for c in base.get("connections", [])}
    for conn in overlay.get("connections", []):
        key = _conn_key(conn)
        if key not in existing_conn_keys:
            base.setdefault("connections", []).append(conn)
            existing_conn_keys.add(key)

    # localNetworkGateways
    existing_lng_ids = {item["id"].lower() for item in base.get("localNetworkGateways", [])}
    for item in overlay.get("localNetworkGateways", []):
        if item["id"].lower() not in existing_lng_ids:
            base.setdefault("localNetworkGateways", []).append(item)
            existing_lng_ids.add(item["id"].lower())

    # gatewayConnections
    existing_gwc_ids = {item["id"].lower() for item in base.get("gatewayConnections", [])}
    for item in overlay.get("gatewayConnections", []):
        if item["id"].lower() not in existing_gwc_ids:
            base.setdefault("gatewayConnections", []).append(item)
            existing_gwc_ids.add(item["id"].lower())

    # onPremises — deduplicate by id
    existing_op_ids = {item["id"].lower() for item in base.get("onPremises", [])}
    for item in overlay.get("onPremises", []):
        if item["id"].lower() not in existing_op_ids:
            base.setdefault("onPremises", []).append(item)
            existing_op_ids.add(item["id"].lower())


# ── Full discovery + emit ────────────────────────────────────────────────────
def discover_and_emit_topology(
    title: str,
    scope_resource_id: str,
    scope_resource_type: str,
    output_file: str,
    seed_ids: list[str],
    sub_id: str,
    sub_name: str,
    topology_version: int = 1,
    start_time: float = 0.0,
    baseline_data: dict[str, Any] | None = None,
) -> str:
    """
    Run BFS from seed VNet IDs, build connections, assemble schema-v3.0 JSON,
    and write to output file. Returns the output file path.

    VNets are streamed to a JSONL temp file during discovery to reduce peak
    memory (one VNet in-memory at a time during BFS). Final assembly reads
    the temp file in a single pass.
    """
    all_connections: list[dict] = []
    er_circuits: list[dict] = []
    lngs_list: list[dict] = []
    gw_connections: list[dict] = []

    # JSONL temp file for streaming VNet writes
    vnet_tmp = tempfile.NamedTemporaryFile(
        mode="w", suffix=".vnets.jsonl", delete=False, encoding="utf-8",
    )
    vnet_tmp_path = vnet_tmp.name
    vnet_counter = 0

    try:
        # BFS
        queue = list(seed_ids)
        seen: set[str] = {vid.lower() for vid in seed_ids}

        log_info(f"Starting traversal from {len(seed_ids)} seed network(s)…")

        while queue:
            current_id = queue.pop(0)
            remaining = len(queue)
            vnet_counter += 1

            if is_vhub_resource_id(current_id):
                log_step(f"Processing VNet {vnet_counter}: {arm_basename(current_id)}…")
                log_resource(f"vWAN Hub: {arm_basename(current_id)}  [{remaining} in queue]")
                vnet_obj = discover_vhub(current_id, current_id, er_circuits, lngs_list)
            elif is_vhub_vnet_id(current_id):
                log_step(f"Processing VNet {vnet_counter}: {arm_basename(current_id)}…")
                log_resource(f"vWAN Hub VNet: {arm_basename(current_id)}  [{remaining} in queue]")
                vhub_resource_id = resolve_vhub_id_from_vnet(current_id)

                if vhub_resource_id:
                    vhub_lower = vhub_resource_id.lower()
                    if vhub_lower in seen:
                        log_detail("Already discovered — skipping duplicate")
                        continue
                    vnet_obj = discover_vhub(vhub_resource_id, current_id, er_circuits, lngs_list)
                else:
                    log_alert(
                        f"ACCESS DENIED — {arm_basename(current_id)}",
                        "Could not resolve the Virtual Hub behind this managed VNet.",
                        "The hub may be in a subscription you don't have access to.",
                        "A placeholder will be added to the topology.",
                    )
                    vnet_obj = {
                        "id": current_id,
                        "name": arm_basename(current_id),
                        "addressSpace": [],
                        "location": "unknown",
                        "resourceGroup": "unknown",
                        "subnets": [],
                        "peerings": [],
                        "_isVirtualHub": True,
                        "_accessDenied": True,
                    }
            else:
                log_step(f"Processing VNet {vnet_counter}: {arm_basename(current_id)}…")
                log_resource(f"VNet: {arm_basename(current_id)}  [{remaining} in queue]")
                vnet_obj = discover_vnet(current_id)
                discover_external_connectivity(current_id, er_circuits, lngs_list, gw_connections)

            # Stream VNet to JSONL temp file (reduce peak memory)
            vnet_tmp.write(json.dumps(vnet_obj, ensure_ascii=False) + "\n")
            vnet_tmp.flush()

            # Mark vHub ARM ID as seen too
            vhub_rid = vnet_obj.get("_vhubResourceId", "")
            if vhub_rid:
                seen.add(vhub_rid.lower())

            # Enqueue unseen peered VNets
            for p in vnet_obj.get("peerings") or []:
                peer_id = p.get("remoteVnetId", "")
                if not peer_id:
                    continue
                peer_lower = peer_id.lower()
                if peer_lower in seen:
                    continue
                seen.add(peer_lower)
                queue.append(peer_id)
                if is_vhub_resource_id(peer_id):
                    log_queue(f"Linked vWAN Hub: {arm_basename(peer_id)}")
                else:
                    log_queue(f"Peered network: {arm_basename(peer_id)}")

            # Release VNet object from memory — it's now on disk
            del vnet_obj

        # Close temp file for reading
        vnet_tmp.close()

        # ── Read all VNets from JSONL for post-processing ──
        all_vnets: list[dict] = []
        with open(vnet_tmp_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    all_vnets.append(json.loads(line))

        # ── Build connections ──
        print(f"\n{_C_GREEN}{_C_BOLD}  ● Assembling peering connections…{_C_RESET}", file=sys.stderr)
        _log_to_file(f"  ● Assembling peering connections…")
        conn_set: set[tuple[str, str]] = set()

        for vnet in all_vnets:
            vi_id = vnet["id"]
            for p in vnet.get("peerings") or []:
                p_remote = p.get("remoteVnetId", "")
                if not p_remote:
                    continue

                src_lower = vi_id.lower()
                tgt_lower = p_remote.lower()
                key = tuple(sorted((src_lower, tgt_lower)))
                if key in conn_set:
                    continue
                conn_set.add(key)

                all_connections.append(
                    {
                        "sourceId": vi_id,
                        "targetId": p_remote,
                        "relationship": "VNet peering",
                        "direction": "undirected",
                        "metadata": {
                            "peeringName": p.get("name", ""),
                            "state": p.get("state", "Unknown"),
                        },
                    }
                )

        # ── Deduplicate external resources ──
        def _unique_by_id(items: list[dict]) -> list[dict]:
            seen_ids: set[str] = set()
            result: list[dict] = []
            for item in items:
                iid = item.get("id", "")
                if iid not in seen_ids:
                    seen_ids.add(iid)
                    result.append(item)
            return result

        er_circuits = _unique_by_id(er_circuits)
        lngs_list = _unique_by_id(lngs_list)
        gw_connections = _unique_by_id(gw_connections)

        # ── Validate ER circuit ↔ VNet gateway linkage (T141, GH #35) ──
        if er_circuits and gw_connections:
            er_ids_lower = {c["id"].lower() for c in er_circuits if c.get("id")}
            er_conn_count = 0
            for gc in gw_connections:
                cid = gc.get("circuitId", "")
                if cid and cid.lower() in er_ids_lower:
                    er_conn_count += 1
            if er_conn_count > 0:
                log_found(f"{er_conn_count} ER circuit(s) linked to VNet gateway(s) via connections")
            else:
                log_warn(
                    f"Found {len(er_circuits)} ER circuit(s) but no gateway connections "
                    "reference them — ER ↔ gateway linkage may be incomplete"
                )
        elif er_circuits and not gw_connections:
            log_warn(
                f"Found {len(er_circuits)} ER circuit(s) but no gateway connections — "
                "ER ↔ gateway linkage missing"
            )

        # ── Enrich VNets with Private DNS Zone links ──
        log_substep("Querying Private DNS Zone virtual network links…")
        dns_zone_query = """Resources
            | where type =~ 'microsoft.network/privatednszones/virtualnetworklinks'
            | extend vnetId = tolower(tostring(properties.virtualNetwork.id))
            | extend zoneName = tostring(split(id, '/')[8])
            | project vnetId, zoneName,
                registrationEnabled = tobool(properties.registrationEnabled)"""

        dns_zone_links = invoke_graph_query_paginated(
            "Query Private DNS Zone links",
            dns_zone_query,
            sub_id,
            error_scope="private-dns-zone-links",
        )
        log_found(f"{len(dns_zone_links)} DNS zone link(s) found")

        # Build lookup: lowercase vnetId → list of zone objects
        dns_zones_by_vnet: dict[str, list[dict]] = {}
        for link in dns_zone_links:
            vid = link.get("vnetId", "")
            if not vid:
                continue
            zone_obj: dict[str, Any] = {"name": link.get("zoneName", "")}
            if link.get("registrationEnabled"):
                zone_obj["registrationEnabled"] = True
            dns_zones_by_vnet.setdefault(vid, []).append(zone_obj)

        # Attach to VNet objects
        for vnet in all_vnets:
            zones = dns_zones_by_vnet.get(vnet["id"].lower(), [])
            if zones:
                vnet["privateDnsZones"] = sorted(zones, key=lambda z: z["name"])

        # ── Assemble topology JSON ──
        generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        topology: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "topologyVersion": topology_version,
            "generatedAt": generated_at,
            "title": title,
            "generator": GENERATOR_NAME,
            "scope": {
                "subscriptionId": sub_id,
                "subscriptionName": sub_name,
                "startingResourceId": scope_resource_id,
                "startingResourceType": scope_resource_type,
            },
            "vnets": all_vnets,
            "connections": all_connections,
        }

        if er_circuits:
            topology["expressRouteCircuits"] = er_circuits
        if lngs_list:
            topology["localNetworkGateways"] = lngs_list
        if gw_connections:
            topology["gatewayConnections"] = gw_connections

        # ── Synthesise on-premises sites from ER circuits + LNGs ──
        on_premises = _synthesize_on_premises(er_circuits, lngs_list)
        if on_premises:
            topology["onPremises"] = on_premises

        if _discovery_errors:
            topology["_warnings"] = list(_discovery_errors)

        # ── Merge user edits from baseline (T211) ──
        if baseline_data:
            log_step("Merging Baseline User Edits")
            merge_summary = merge_user_edits(baseline_data, topology)
            log_info(f"Layouts applied: {merge_summary['applied_layouts']}")
            log_info(f"OnPremises edits merged: {merge_summary['merged_edits']}")
            log_info(f"x-aed-* tags merged: {merge_summary['merged_tags']}")
            if merge_summary["preserved_onprem"]:
                log_info(f"User-created OnPremises preserved: {merge_summary['preserved_onprem']}")
            if merge_summary["orphaned"]:
                log_warn(f"Orphaned baseline resources: {merge_summary['orphaned']}")
            log_info(f"New resources (no baseline match): {merge_summary['new_resources']}")

        # ── Write output ──
        with open(output_file, "w", encoding="utf-8") as f:
            json.dump(topology, f, indent=2, ensure_ascii=False)
            f.write("\n")

        vnet_count = len(all_vnets)
        conn_count = len(all_connections)
        er_count = len(er_circuits)
        lng_count = len(lngs_list)
        on_prem_count = len(on_premises)

        log_step("Results")
        # ── Results table ──
        _rw = 23
        def _result_row(label: str, value: str) -> None:
            print(f"{_C_BOLD}{_C_CYAN}  │{_C_RESET} {_C_WHITE}{label:<16}{_C_RESET} {_C_BOLD}{_C_CYAN}│{_C_RESET} {value:<{_rw}} {_C_BOLD}{_C_CYAN}│{_C_RESET}", file=sys.stderr)
            _log_to_file(f"  {label:<16} {value}")
        print(f"{_C_BOLD}{_C_CYAN}  ┌──────────────────┬─────────────────────────┐{_C_RESET}", file=sys.stderr)
        _result_row("Title", title)
        _result_row("Networks", str(vnet_count))
        _result_row("Connections", str(conn_count))
        if er_count > 0:
            _result_row("ER Circuits", str(er_count))
        if lng_count > 0:
            _result_row("Local Gateways", str(lng_count))
        if on_prem_count > 0:
            _result_row("On-Premises", str(on_prem_count))
        # Duration row
        if start_time > 0:
            elapsed = time.monotonic() - start_time
            mins, secs = divmod(int(elapsed), 60)
            duration_str = f"{mins}m {secs:02d}s" if mins > 0 else f"{secs}s"
            _result_row("Duration", duration_str)
        if _discovery_errors:
            _result_row("Warnings", str(len(_discovery_errors)))
        print(f"{_C_BOLD}{_C_CYAN}  └──────────────────┴─────────────────────────┘{_C_RESET}", file=sys.stderr)
        print(f"{_C_WHITE}  {'Output:':<16}{_C_RESET} {os.path.abspath(output_file)}", file=sys.stderr)
        _log_to_file(f"  {'Output:':<16} {os.path.abspath(output_file)}")
        if _log_file_path:
            print(f"{_C_WHITE}  {'Log:':<16}{_C_RESET} {os.path.abspath(_log_file_path)}", file=sys.stderr)
            _log_to_file(f"  {'Log:':<16} {os.path.abspath(_log_file_path)}")

        # ── Error summary (categorized) ──
        if _discovery_errors:
            print("", file=sys.stderr)
            # Group errors by category
            by_category: dict[str, list[dict]] = {}
            for e in _discovery_errors:
                cat = e.get("category", "Other")
                by_category.setdefault(cat, []).append(e)
            log_warn(f"Completed with {len(_discovery_errors)} error(s) in {len(by_category)} category/categories:")
            for cat, errors in sorted(by_category.items()):
                log_warn(f"  [{cat}] ({len(errors)}):")
                for e in errors:
                    log_warn(f"    - {e['scope']}: {e['error']}")

        print("", file=sys.stderr)
        print(f"{_C_BOLD}{_C_CYAN}  Next Steps:{_C_RESET}", file=sys.stderr)
        print(f"{_C_DIM}  1. Load the output file into the Azure Network Topology Viewer.{_C_RESET}", file=sys.stderr)
        print(f"{_C_DIM}  2. The initial layout may look messy — drag nodes to arrange them.{_C_RESET}", file=sys.stderr)
        print(f"{_C_DIM}  3. Save the file — positions are persisted and restored on reload.{_C_RESET}", file=sys.stderr)
        print(f"{_C_DIM}  4. Use 'Export as PNG' to capture the current view.{_C_RESET}", file=sys.stderr)

        return output_file
    finally:
        # Clean up JSONL temp file
        try:
            os.unlink(vnet_tmp_path)
        except OSError:
            pass


# ── Banner ───────────────────────────────────────────────────────────────────
def show_banner() -> None:
    W = 60
    def _line(text: str, color: str = "") -> None:
        pad = W - len(text)
        print(f"{_C_BOLD}{_C_CYAN}  ║{_C_RESET}  {color}{text}{_C_RESET}{' ' * pad}  {_C_BOLD}{_C_CYAN}║{_C_RESET}", file=sys.stderr)
    bar = "═" * (W + 4)
    print(f"\n{_C_BOLD}{_C_CYAN}  ╔{bar}╗{_C_RESET}", file=sys.stderr)
    _line("")
    _line("  ▄▀█ █▀▀ █▀▄   █▀▀ █▀ █▀▄▀█ █▀▀", f"{_C_BOLD}{_C_GREEN}")
    _line("  █▀█ ██▄ █▄▀   ██▄ ▄█ █ ▀ █ ██▄", f"{_C_BOLD}{_C_GREEN}")
    _line("")
    _line("  Azure Network Topology Generator", f"{_C_BOLD}{_C_WHITE}")
    _line(f"  v{SCRIPT_VERSION}  ·  Schema v{SCHEMA_VERSION}  ·  python", _C_DIM)
    _line("  Author: johnfern@", _C_DIM)
    _line("")
    print(f"{_C_BOLD}{_C_CYAN}  ╚{bar}╝{_C_RESET}", file=sys.stderr)


# ── Main ─────────────────────────────────────────────────────────────────────
def _run_merge_subcommand(args: argparse.Namespace) -> None:
    """Handle the ``merge`` subcommand — offline file merge, no Azure login."""
    if len(args.files) < 2:
        log_error("merge requires at least 2 input files")
        sys.exit(1)
    if not args.output:
        log_error("merge requires -o / --output")
        sys.exit(1)

    # Validate all input files exist
    for path in args.files:
        if not os.path.isfile(path):
            log_error(f"File not found: {path}")
            sys.exit(1)

    log_step("Merge Topology Files")
    log_info(f"Input files: {len(args.files)}")
    for i, path in enumerate(args.files, 1):
        log_info(f"  {i}. {path}")
    log_info(f"Output: {args.output}")

    merge_files(args.files, args.output)

    log_step("Complete")
    log_info(f"Output: {os.path.abspath(args.output)}")


def main() -> None:
    # Check if the first positional arg is the 'merge' subcommand
    if len(sys.argv) > 1 and sys.argv[1] == "merge":
        merge_parser = argparse.ArgumentParser(
            prog="get-network-topology.py merge",
            description="Merge multiple topology JSON files offline (no Azure login required)",
        )
        merge_parser.add_argument("_subcmd", help=argparse.SUPPRESS)  # consume 'merge'
        merge_parser.add_argument("files", nargs="+", help="Topology JSON files to merge (left-to-right)")
        merge_parser.add_argument("-o", "--output", required=True, help="Output file path")
        args = merge_parser.parse_args()
        show_banner()
        _run_merge_subcommand(args)
        return

    parser = argparse.ArgumentParser(
        description="Azure Network Topology Generator for AED/ESME (Python) [Beta]",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--title", default="", help="Diagram title (prompted if omitted)")
    parser.add_argument("--vnet-id", default="", help="Starting VNet ARM resource ID")
    parser.add_argument("--vhub-id", default="", help="Starting Virtual Hub ARM resource ID")
    parser.add_argument("--subscription", default="", help="Subscription ID or name")
    parser.add_argument("--resource-group", default="", help="Resource group name")
    parser.add_argument("--output", default="", help="Output file path")
    parser.add_argument("--baseline", default="", help="Previous topology JSON file to preserve user edits from and increment topologyVersion")
    args = parser.parse_args()

    show_banner()

    # Capture script start time for duration reporting
    script_start_time = time.monotonic()

    starting_vnet_id = args.vnet_id or args.vhub_id
    starting_vnet_type = "Microsoft.Network/virtualNetworks"
    if args.vhub_id:
        starting_vnet_type = "Microsoft.Network/virtualHubs"

    sub_id = args.subscription
    sub_name = ""
    rg_name = args.resource_group
    diagram_title = args.title

    # Prerequisites
    _account, accepted_sub_id, accepted_sub_name = check_prerequisites()

    # Sleep prevention
    prevent_sleep()

    # Step 1: Subscription
    if sub_id:
        if validate_subscription_guid(sub_id):
            sub_name = az_cli_text(["account", "show", "--subscription", sub_id, "--query", "name"]) or sub_id
        else:
            sub_name = sub_id
            resolved = az_cli_text(["account", "show", "--subscription", sub_name, "--query", "id"])
            if not resolved:
                log_error(f"Could not resolve subscription: {sub_name}")
                sys.exit(1)
            sub_id = resolved
        log_info(f"Using subscription: {sub_name} ({sub_id})")

    # Step 2: Direct VNet/vHub ID
    if starting_vnet_id:
        if not validate_arm_resource_id(starting_vnet_id):
            log_error(f"Invalid resource ID: {starting_vnet_id}")
            sys.exit(1)
        sub_id = extract_sub_id(starting_vnet_id)
        rg_name = extract_rg(starting_vnet_id)
        sub_name = az_cli_text(["account", "show", "--subscription", sub_id, "--query", "name"]) or sub_id
        log_info(f"Direct mode: {starting_vnet_id}")

    # Step 3: Interactive selection for missing values
    if not sub_id:
        if accepted_sub_id:
            sub_id = accepted_sub_id
            sub_name = accepted_sub_name
            log_info(f"Using subscription: {sub_name} ({sub_id})")
        else:
            sub_id, sub_name = select_subscription()
    if not rg_name:
        rg_name = select_resource_group(sub_id)
    if not starting_vnet_id:
        starting_vnet_id, starting_vnet_type = select_vnet(sub_id, rg_name)

    # Step 4: Title
    diagram_title = prompt_title(diagram_title)
    log_info(f"Title: {diagram_title}")

    # Step 5: Build scope
    scope_resource_id = starting_vnet_id or f"/subscriptions/{sub_id}/resourceGroups/{rg_name}"
    scope_resource_type = starting_vnet_type if starting_vnet_id else "ResourceGroup"

    # Step 6: Collect VNet IDs
    log_step("Discovering Network Topology")

    vnet_ids: list[str] = []
    if starting_vnet_id:
        vnet_ids.append(starting_vnet_id)
    else:
        # All VNets in RG
        all_vnets = invoke_with_retry(
            "List VNets",
            ["network", "vnet", "list", "--subscription", sub_id, "--resource-group", rg_name, "--query", "[].id"],
            max_retries=1, allow_failure=True,
        ) or []
        vnet_ids.extend(all_vnets)

        # All Virtual Hubs in RG
        all_vhubs = invoke_with_retry(
            "List vHubs",
            ["network", "vhub", "list", "--subscription", sub_id, "--resource-group", rg_name, "--query", "[].id"],
            max_retries=1, allow_failure=True,
        ) or []
        vnet_ids.extend(all_vhubs)

    if not vnet_ids:
        log_error("No VNets or Virtual Hubs to discover.")
        sys.exit(1)

    # Step 7: Resolve topology version from baseline
    topology_version = 1
    baseline_doc: dict[str, Any] | None = None
    if args.baseline:
        try:
            with open(args.baseline, "r", encoding="utf-8") as bf:
                baseline_doc = json.load(bf)
            prev = baseline_doc.get("topologyVersion")
            if isinstance(prev, int) and prev >= 1:
                topology_version = prev + 1
            log_info(f"Baseline topology version {prev} → new version {topology_version}")
            log_info(f"Baseline merge enabled — user edits will be preserved")
        except (OSError, json.JSONDecodeError) as e:
            log_warn(f"Could not read baseline file '{args.baseline}': {e} — defaulting to version 1")
            baseline_doc = None

    # Step 8: Single or multi-seed discovery
    title_slug = re.sub(r"[^a-z0-9._-]", "", diagram_title.lower().replace(" ", "-"))
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")

    # Open persistent log file (same directory as output, .log extension)
    log_file_name = f"topology.{title_slug}.{ts}.log"
    if args.output:
        log_file_name = os.path.join(os.path.dirname(os.path.abspath(args.output)), log_file_name)
    _log_file_open(log_file_name)
    atexit.register(_log_file_close)

    # Retroactively write prerequisite context to log file
    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    az_ver_json = az_cli(["version"])
    az_ver_str = (az_ver_json or {}).get("azure-cli", "unknown")
    acct = az_cli(["account", "show"])
    _log_to_file(f"── Generator ──")
    _log_to_file(f"  v{SCRIPT_VERSION}  ·  Schema v{SCHEMA_VERSION}  ·  python")
    _log_to_file(f"  Python {py_ver}  ·  Azure CLI {az_ver_str}")
    if acct:
        _log_to_file(f"  User:         {acct.get('user', {}).get('name', 'unknown')}")
        _log_to_file(f"  Tenant:       {acct.get('tenantId', 'unknown')}")
        _log_to_file(f"  Subscription: {acct.get('name', 'unknown')} ({acct.get('id', '')})")
    if starting_vnet_id:
        _log_to_file(f"  Resource:     {starting_vnet_id}")
    _log_to_file(f"  Title:        {diagram_title}")
    _log_to_file(f"")
    log_info(f"Log file: {os.path.abspath(log_file_name)}")

    if starting_vnet_id or len(vnet_ids) == 1:
        out_file = args.output or f"topology.{title_slug}.{ts}.json"
        discover_and_emit_topology(
            diagram_title, scope_resource_id, scope_resource_type,
            out_file, vnet_ids, sub_id, sub_name, topology_version,
            start_time=script_start_time,
            baseline_data=baseline_doc,
        )
    else:
        # "All" mode — partition into connected components
        log_step("Scanning peerings to identify network groups")
        components = build_connected_components(vnet_ids)
        log_info(f"Found {len(components)} network group(s) across {len(vnet_ids)} VNet(s)")

        for ci, comp in enumerate(components):
            root_id = comp[0]
            root_name = arm_basename(root_id)

            if len(components) == 1:
                comp_out = args.output or f"topology.{title_slug}.{ts}.json"
                comp_title = diagram_title
            else:
                base = args.output.replace(".json", "") if args.output else f"topology.{title_slug}.{ts}"
                comp_out = f"{base}.{ci + 1}.{root_name}.json"
                comp_title = f"{diagram_title} ({root_name})"

            comp_scope_id = root_id
            comp_scope_type = "Microsoft.Network/virtualNetworks"

            log_step(f"Group {ci + 1}/{len(components)} — {root_name} ({len(comp)} network(s) in local RG)")
            # Use only root as seed — BFS discovers the rest
            discover_and_emit_topology(
                comp_title, comp_scope_id, comp_scope_type,
                comp_out, [root_id], sub_id, sub_name, topology_version,
                start_time=script_start_time,
                baseline_data=baseline_doc,
            )

    log_step("Complete")


if __name__ == "__main__":
    main()
