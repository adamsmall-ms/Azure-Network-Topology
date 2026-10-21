#!/usr/bin/env python3
"""
get-network-topology-graph.py — Graph-First Scoped Crawl Discovery

Implements the 5-phase scoped crawl architecture for Azure network topology
discovery using Azure Resource Graph.

Architecture:
  Phase 1 — Seed Resolution (1 query)
  Phase 2 — BFS Wave Expansion (batched, ~1 query per wave)
  Phase 3 — Backbone Resources (scoped to discovered RGs)
  Phase 4 — Subnet Resources (batched by discovered VNet IDs)
  Phase 5 — Wire Back (client-side join, no API cost)

Usage:
  python3 get-network-topology-graph.py [OPTIONS]

Options:
  --title <TITLE>           Diagram title (prompted if omitted)
  --vnet-id <ARM_ID>        Starting VNet ARM resource ID (scoped crawl)
  --vhub-id <ARM_ID>        Starting Virtual Hub ARM resource ID (scoped crawl)
  --subscription <ID>       Subscription ID or name
  --resource-group <NAME>   Resource group name (for "All in RG" mode)
  --output <FILE>           Output file path
  --baseline <FILE>         Previous topology JSON to preserve user edits and
                            enable incremental discovery automatically
  --full                    Force full discovery even when a valid baseline exists
  --help                    Show this help message

Incremental Mode:
  When --baseline is provided with a valid topology file, the script
  automatically enables incremental mode \u2014 reusing subnet resource data
  from the previous run for VNets that haven't changed. Only VNets with
  different resource counts are re-queried. Backbone resources (gateways,
  ER circuits, connections) are always queried fresh.

  Use --full to force a complete re-query even when a valid baseline exists.

  Falls back to full discovery automatically when the baseline is too old
  (>30 days), has a different schema/script version, or is corrupt.

  Examples:
    # Full discovery (first run)
    python3 get-network-topology-graph.py --output topology.json

    # Incremental run (auto-detected from baseline)
    python3 get-network-topology-graph.py --baseline topology.json

    # Force full re-query despite valid baseline
    python3 get-network-topology-graph.py --baseline topology.json --full
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import PurePosixPath
from typing import Any

# ── Constants ────────────────────────────────────────────────────────────────
SCRIPT_VERSION = "0.5.0-beta"
SCRIPT_BUILD = 37
SCHEMA_VERSION = "3.0"
GENERATOR_NAME = "aed-esme-networking/python-graph"
MAX_RETRIES = 3
RETRY_BASE_DELAY = 2
GRAPH_BATCH_SIZE = 100  # Max VNet IDs per query clause (~60KB limit guard)
INCREMENTAL_MAX_AGE_DAYS = 30  # Max baseline age for incremental mode

# ── Error accumulation (global) ──────────────────────────────────────────────
_discovery_errors: list[dict[str, str]] = []

# Sentinel value: returned by invoke_graph_query_paginated when the query
# itself failed (vs returning an empty result set legitimately).
_QUERY_FAILED: list[dict] = []

# ── Log file (global) ───────────────────────────────────────────────────────
_log_file_handle: Any = None
_log_file_path: str = ""

# ── Query log file (global) ─────────────────────────────────────────────────
_query_log_handle: Any = None
_query_log_path: str = ""
_query_counter: int = 0

# ── Sleep prevention (global) ───────────────────────────────────────────────
_caffeinate_proc: subprocess.Popen | None = None

# ANSI escape codes
_C_RESET = "\033[0m"
_C_BOLD = "\033[1m"
_C_DIM = "\033[2m"
_C_RED = "\033[31m"
_C_GREEN = "\033[32m"
_C_YELLOW = "\033[33m"
_C_BLUE = "\033[34m"
_C_MAGENTA = "\033[35m"
_C_CYAN = "\033[36m"
_C_WHITE = "\033[37m"

# Disable colour when NO_COLOR is set or not a tty
if os.environ.get("NO_COLOR") or not sys.stderr.isatty():
    _C_RESET = _C_BOLD = _C_DIM = ""
    _C_RED = _C_GREEN = _C_YELLOW = _C_BLUE = _C_CYAN = _C_MAGENTA = _C_WHITE = ""

# ANSI escape sequence stripper
_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


# ── Log file management ────────────────────────────────────────────────────
def _log_file_open(path: str) -> None:
    global _log_file_handle, _log_file_path
    _log_file_path = path
    _log_file_handle = open(path, "w", encoding="utf-8")


def _log_file_close() -> None:
    global _log_file_handle
    if _log_file_handle:
        _log_file_handle.close()
        _log_file_handle = None


def _log_to_file(msg: str) -> None:
    if not _log_file_handle:
        return
    now_utc = datetime.now(timezone.utc)
    now_local = datetime.now()
    tz_abbr = time.strftime("%Z") or "local"
    utc_str = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    local_str = now_local.strftime("%H:%M:%S")
    clean_msg = _ANSI_RE.sub("", msg)
    _log_file_handle.write(f"[{utc_str} / {local_str} {tz_abbr}] {clean_msg}\n")
    _log_file_handle.flush()


# ── Query log management ───────────────────────────────────────────────────
def _query_log_open(path: str) -> None:
    global _query_log_handle, _query_log_path
    _query_log_path = path
    _query_log_handle = open(path, "w", encoding="utf-8")
    _query_log_handle.write("// Graph-First Scoped Crawl — Query Log\n")
    _query_log_handle.write(f"// Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
    _query_log_handle.write(f"// Script: get-network-topology-graph.py v{SCRIPT_VERSION} (build {SCRIPT_BUILD})\n")
    _query_log_handle.write("// Paste queries into Azure Resource Graph Explorer to test/optimise.\n\n")
    _query_log_handle.flush()


def _query_log_close() -> None:
    global _query_log_handle
    if _query_log_handle:
        _query_log_handle.close()
        _query_log_handle = None


def _query_log_emit(phase: str, label: str, query: str, subscription: str) -> None:
    """Write a query to the .kql file with context comments."""
    global _query_counter
    if not _query_log_handle:
        return
    _query_counter += 1
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _query_log_handle.write(f"// ── Query #{_query_counter}: {phase} — {label} ──\n")
    _query_log_handle.write(f"// Time: {ts}\n")
    _query_log_handle.write(f"// Subscription: {subscription}\n")
    _query_log_handle.write(f"{query.strip()}\n\n")
    _query_log_handle.flush()


# ── Log functions ───────────────────────────────────────────────────────────
def _timestamp() -> str:
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
    print(f"{_C_YELLOW}  \u25b2 {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  WARN: {msg}")


def log_error(msg: str) -> None:
    print(f"{_C_RED}  \u2716 {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  ERROR: {msg}")


def log_step(msg: str) -> None:
    ts = _timestamp()
    print(f"\n{_C_DIM}[{ts}]{_C_RESET} {_C_BOLD}{_C_CYAN}\u2500\u2500 {msg} \u2500\u2500{_C_RESET}", file=sys.stderr)
    _log_to_file(f"\u2500\u2500 {msg} \u2500\u2500")


def log_resource(msg: str) -> None:
    ts = _timestamp()
    print(f"\n{_C_DIM}[{ts}]{_C_RESET} {_C_GREEN}{_C_BOLD}  \u25cf {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  \u25cf {msg}")


def log_queue(msg: str) -> None:
    print(f"{_C_CYAN}    \u25b8 Queued: {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"    \u25b8 Queued: {msg}")


def log_dequeue(msg: str) -> None:
    print(f"{_C_MAGENTA}    \u25b8 Processing: {msg}{_C_RESET}", file=sys.stderr)
    _log_to_file(f"    \u25b8 Processing: {msg}")


def log_alert(*lines: str) -> None:
    print(f"\n{_C_RED}{_C_BOLD}  \u2554\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550{_C_RESET}", file=sys.stderr)
    print(f"{_C_RED}{_C_BOLD}  \u2551  \u26a0  {lines[0]}{_C_RESET}", file=sys.stderr)
    for line in lines[1:]:
        print(f"{_C_RED}  \u2551     {line}{_C_RESET}", file=sys.stderr)
    print(f"{_C_RED}{_C_BOLD}  \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550{_C_RESET}", file=sys.stderr)
    _log_to_file(f"  ALERT: {' | '.join(lines)}")


# ── Spinner ─────────────────────────────────────────────────────────────────
class Spinner:
    """Simple animated spinner for long-running operations."""
    _FRAMES = ['\u280b', '\u2819', '\u2839', '\u2838', '\u283c', '\u2834', '\u2826', '\u2827', '\u2807', '\u280f']

    def __init__(self, msg: str = "Loading\u2026"):
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


# ── Validation & ARM helpers ────────────────────────────────────────────────
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
    return PurePosixPath(arm_id).name


def extract_sub_id(arm_id: str) -> str:
    m = re.match(r"^/subscriptions/([^/]+)/", arm_id, re.IGNORECASE)
    return m.group(1) if m else ""


def extract_rg(arm_id: str) -> str:
    m = re.match(
        r"^/subscriptions/[^/]+/resourceGroups/([^/]+)/", arm_id, re.IGNORECASE
    )
    return m.group(1) if m else ""


def is_vhub_resource_id(arm_id: str) -> bool:
    return "/microsoft.network/virtualhubs/" in arm_id.lower()


def is_vhub_vnet_id(arm_id: str) -> bool:
    """True if the ARM id looks like a vWAN-managed VNet (HV_*/RG_*)."""
    lower = arm_id.lower()
    vnet_name = arm_basename(lower)
    m = re.match(r"^/subscriptions/[^/]*/resourcegroups/([^/]*)/", lower)
    rg = m.group(1) if m else ""
    return vnet_name.startswith("hv_") and rg.startswith("rg_")


def _parse_vhub_name_from_rg(vnet_id: str) -> str | None:
    """Extract the vHub name from an HV_* VNet's resource group name.

    Azure always creates HV_* managed VNets in a resource group named
    RG_<full-vhub-name>_<guid>.  The vHub name here is never truncated,
    unlike the VNet name itself.  Returns the vHub name if matched, else None.
    """
    rg = extract_rg(vnet_id)
    if not rg:
        return None
    m = re.match(
        r"^RG_(.+)_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        rg, re.IGNORECASE,
    )
    return m.group(1) if m else None


def _guess_vhub_name(vnet_name: str) -> str:
    """Derive the probable vHub name from an HV_* managed VNet name."""
    without_prefix = re.sub(r"^[Hh][Vv]_", "", vnet_name)
    return re.sub(
        r"_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        "", without_prefix,
    ) or without_prefix


def resolve_vhub_id_from_vnet(
    vnet_id: str,
    subscription: str,
    *,
    spoke_to_vhub: dict[str, dict] | None = None,
) -> dict | None:
    """Resolve a vHub-managed VNet ID to the actual virtualHubs ARM resource.

    Uses a 3-tier approach:
      1. **Lookup** — Parse the vHub name from the HV_* VNet's resource group
         (RG_<full-name>_<guid>) and match against the pre-fetched spoke→vHub
         lookup by name.  Query Graph by exact vHub ID for full resource data.
      2. **RG-parse + Graph query** — Parse vHub name from RG, query Graph by
         name (fallback when the pre-fetch had no data or missed this hub).
      3. **Name-guess** — Existing approach: guess the vHub name from the HV_*
         VNet name (may be truncated) and query Graph / CLI list.

    Returns a dict with the vHub resource data on success, or None on failure.
    Each successful resolution sets '_resolutionMethod' on the returned dict.
    """
    sub_id = extract_sub_id(vnet_id) or subscription
    vnet_name = arm_basename(vnet_id)
    rg_parsed_name = _parse_vhub_name_from_rg(vnet_id)
    hub_name_guess = _guess_vhub_name(vnet_name)

    # Use the most reliable name available for logging
    display_name = rg_parsed_name or hub_name_guess or vnet_name
    log_substep(f"Resolving vHub from managed VNet '{vnet_name}' "
                f"(rg-parse='{rg_parsed_name}', guess='{hub_name_guess}')...")

    # ── Tier 1: Pre-fetched lookup by vHub name ──────────────────────────
    if rg_parsed_name and spoke_to_vhub:
        by_name = spoke_to_vhub.get("_by_name", {})
        candidates = by_name.get(rg_parsed_name.lower(), [])
        if len(candidates) == 1:
            entry = candidates[0]
            vhub_id = entry["vhub_id"]
            vhub_sub = extract_sub_id(vhub_id) or sub_id
            query = (
                f"Resources"
                f" | where type =~ 'microsoft.network/virtualhubs'"
                f" and id =~ '{vhub_id}'"
                f" | project id, name, type, location, resourceGroup,"
                f" subscriptionId, properties, tags"
            )
            result = invoke_with_retry(
                "Find vHub by ID [lookup]",
                ["graph", "query", "-q", query, "--subscriptions", vhub_sub, "--first", "5"],
                max_retries=1, allow_failure=True,
            )
            data = (result or {}).get("data", [])
            if data:
                log_found(f"Resolved [lookup] → {data[0]['name']}")
                data[0]["_resolutionMethod"] = "lookup"
                data[0]["_connectionId"] = entry.get("connection_id", "")
                data[0]["_connectionState"] = entry.get("connection_state", "")
                return data[0]
            # Lookup entry existed but Graph query failed — fall through
            log_substep(f"Spoke→vHub lookup hit for '{rg_parsed_name}' but Graph query returned no data, trying RG-parse...")
        elif len(candidates) > 1:
            log_warn(f"Ambiguous spoke→vHub lookup: {len(candidates)} vHubs named '{rg_parsed_name}' "
                     f"across subscriptions — skipping lookup, falling through to RG-parse")
        # else: no candidates — fall through
    elif rg_parsed_name and not spoke_to_vhub:
        log_substep(f"No spoke→vHub lookup available, trying RG-parse...")
    elif not rg_parsed_name:
        log_substep(f"RG-parse miss for '{vnet_name}' (rg='{extract_rg(vnet_id)}'), trying name-guess...")

    # ── Tier 2: RG-parsed name → Graph query by name ────────────────────
    if rg_parsed_name:
        query = (
            f"Resources"
            f" | where type =~ 'microsoft.network/virtualhubs'"
            f" and name =~ '{rg_parsed_name}'"
            f" | project id, name, type, location, resourceGroup,"
            f" subscriptionId, properties, tags"
        )
        result = invoke_with_retry(
            "Find vHub by name [rg-parse]",
            ["graph", "query", "-q", query, "--first", "10"],
            max_retries=1, allow_failure=True,
        )
        data = (result or {}).get("data", [])
        if data:
            log_found(f"Resolved [rg-parse] → {data[0]['name']}")
            data[0]["_resolutionMethod"] = "rg-parse"
            return data[0]
        log_substep(f"RG-parse query returned no results for '{rg_parsed_name}', falling back to name-guess...")

    # ── Tier 3: Guessed name → Graph query + CLI list (existing logic) ───
    if hub_name_guess:
        query = (
            f"Resources"
            f" | where type =~ 'microsoft.network/virtualhubs'"
            f" and name =~ '{hub_name_guess}'"
            f" | project id, name, type, location, resourceGroup,"
            f" subscriptionId, properties, tags"
        )
        result = invoke_with_retry(
            "Find vHub by name [name-guess]",
            ["graph", "query", "-q", query, "--first", "10"],
            max_retries=1, allow_failure=True,
        )
        data = (result or {}).get("data", [])
        if data:
            log_found(f"Resolved [name-guess] → {data[0]['name']}")
            data[0]["_resolutionMethod"] = "name-guess"
            return data[0]

    # Last resort: list vHubs via CLI and match by best available name
    best_name = rg_parsed_name or hub_name_guess
    if best_name:
        vhub_list = invoke_with_retry(
            "List vHubs",
            ["network", "vhub", "list", "--subscription", sub_id],
            max_retries=1, allow_failure=True,
        ) or []

        for h in vhub_list:
            if h.get("name", "").lower() == best_name.lower():
                log_found(f"Resolved via CLI list → {h['name']}")
                return {
                    "id": h["id"], "name": h["name"],
                    "type": "microsoft.network/virtualhubs",
                    "location": h.get("location", ""),
                    "resourceGroup": extract_rg(h["id"]) or "",
                    "subscriptionId": extract_sub_id(h["id"]) or sub_id,
                    "properties": h, "tags": h.get("tags") or {},
                    "_resolutionMethod": "cli-list",
                }

        if len(vhub_list) == 1:
            h = vhub_list[0]
            log_found(f"Single vHub in subscription → {h['name']}")
            return {
                "id": h["id"], "name": h["name"],
                "type": "microsoft.network/virtualhubs",
                "location": h.get("location", ""),
                "resourceGroup": extract_rg(h["id"]) or "",
                "subscriptionId": extract_sub_id(h["id"]) or sub_id,
                "properties": h, "tags": h.get("tags") or {},
                "_resolutionMethod": "cli-list-single",
            }

    log_warn(f"All resolution methods failed for '{vnet_name}': "
             f"lookup={'miss' if spoke_to_vhub else 'n/a'}, "
             f"rg-parse={'miss' if rg_parsed_name else 'no-match'}, "
             f"name-guess={'miss' if hub_name_guess else 'no-match'}")
    return None


# ── Azure CLI wrapper ───────────────────────────────────────────────────────
def _az_executable() -> str:
    if sys.platform == "win32":
        if shutil.which("az.exe"):
            return "az.exe"
        if shutil.which("az.cmd"):
            return "az.cmd"
        return "az.cmd"
    return "az"


_AZ_EXE = _az_executable()


def az_cli(args: list[str], *, allow_failure: bool = False) -> Any:
    cmd = [_AZ_EXE] + args + ["--output", "json"]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL
        )
        if result.returncode != 0 or not result.stdout.strip():
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
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


def _az_cli_raw(args: list[str], *, timeout: int = 120) -> subprocess.CompletedProcess | None:
    cmd = [_AZ_EXE] + args + ["--output", "json"]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def _parse_retry_after(stderr_text: str) -> int | None:
    if "429" not in stderr_text and "Too Many Requests" not in stderr_text:
        return None
    m = re.search(r"Retry-After[:\s]+(\d+)", stderr_text, re.IGNORECASE)
    return int(m.group(1)) if m else None


def _is_access_denied(raw: subprocess.CompletedProcess | None) -> bool:
    if raw is None:
        return False
    stderr = raw.stderr or ""
    if "403" in stderr:
        return True
    for pat in ("AuthorizationFailed", "AuthorizationPermissionMismatch",
                "does not have authorization", "Forbidden", "AccessDenied",
                "InsufficientPrivileges"):
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
    """Run an az CLI command with retries, exponential backoff, and 429 handling."""
    effective_retries = max_retries if max_retries > 0 else MAX_RETRIES
    for attempt in range(1, effective_retries + 1):
        raw = _az_cli_raw(args, timeout=timeout)
        if raw is not None and raw.returncode == 0 and raw.stdout.strip():
            try:
                return json.loads(raw.stdout)
            except json.JSONDecodeError:
                pass

        if _is_access_denied(raw):
            _discovery_errors.append({
                "scope": error_scope or label,
                "error": f"Access Denied: {label}",
                "category": "Access Denied",
            })
            log_warn(f"{label} \u2014 Access Denied (403), skipping retries")
            return [] if not allow_failure else None

        if raw is not None and raw.stderr:
            retry_after = _parse_retry_after(raw.stderr)
            if retry_after is not None and attempt < effective_retries:
                log_warn(f"{label} \u2014 HTTP 429, waiting {retry_after}s (Retry-After)\u2026")
                time.sleep(retry_after)
                continue

        if attempt == effective_retries:
            if error_scope:
                category = "Timeout" if raw is None else "API Failure"
                if raw is not None and raw.stderr and ("429" in raw.stderr or "Too Many Requests" in raw.stderr):
                    category = "Throttled"
                _discovery_errors.append({"scope": error_scope, "error": f"Failed after {effective_retries} retries: {label}", "category": category})
                log_warn(f"Non-fatal: Failed after {effective_retries} retries: {label}")
                return [] if not allow_failure else None
            if not allow_failure:
                log_error(f"Failed after {effective_retries} retries: {label}")
            return [] if not allow_failure else None

        delay = RETRY_BASE_DELAY * (1 << (attempt - 1))
        log_warn(f"{label} \u2014 attempt {attempt} failed, retrying in {delay}s\u2026")
        time.sleep(delay)
    return [] if not allow_failure else None


def invoke_graph_query_paginated(
    label: str,
    query: str,
    subscription: str | list[str],
    *,
    error_scope: str = "",
    id_field: str = "id",
    phase: str = "",
) -> list[dict]:
    """Execute an Azure Resource Graph query with $skipToken pagination.

    *subscription* may be a single ID or a list of IDs (for cross-subscription
    queries).  Returns deduplicated results. Also emits the query to
    graph-queries.kql.
    """
    sub_list = subscription if isinstance(subscription, list) else [subscription]
    _query_log_emit(phase or "unknown", label, query, ", ".join(sub_list))

    exec_query = query
    if sys.platform == "win32":
        exec_query = re.sub(r"\s+", " ", exec_query).strip()

    all_data: list[dict] = []
    seen_ids: set[str] = set()
    skip_token: str | None = None
    page = 0

    while True:
        page += 1
        args = ["graph", "query", "-q", exec_query, "--subscriptions"] + sub_list + ["--first", "500"]
        if skip_token:
            args += ["--skip-token", skip_token]

        result = invoke_with_retry(
            f"{label} (page {page})",
            args,
            allow_failure=True,
            error_scope=error_scope,
        )
        if result is None:
            # Query failed entirely — return the sentinel so callers can
            # distinguish "query error" from "legitimate empty result".
            return _QUERY_FAILED

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

    PAGE_BOUNDARIES = {100, 500, 1000}
    if len(all_data) in PAGE_BOUNDARIES:
        log_warn(f"Query returned exactly {len(all_data)} results for '{label}' \u2014 possible pagination/filter issue")

    return all_data


def _build_spoke_to_vhub_lookup(subscription: str) -> dict[str, dict]:
    """Pre-fetch hub-to-spoke connection mappings and build a reverse lookup.

    Queries microsoft.network/virtualhubs/hubVirtualNetworkConnections via
    Resource Graph.  Returns a dict keyed by lowercased spoke VNet ARM ID,
    with values containing vHub details and connection metadata.

    A secondary name-based index is embedded under the '_by_name' key so that
    callers holding only an HV_* VNet (not the spoke ID) can resolve via the
    vHub name parsed from the resource group.
    """
    query = (
        "Resources"
        " | where type =~ 'microsoft.network/virtualhubs/hubvirtualnetworkconnections'"
        " | project id, name, type, properties"
    )
    results = invoke_graph_query_paginated(
        "Build spoke→vHub lookup",
        query,
        subscription,
        phase="phase0-vhub-lookup",
    )
    if results is _QUERY_FAILED:
        log_warn("Could not fetch hub connections for spoke→vHub lookup")
        return {}

    lookup: dict[str, dict] = {}
    by_name: dict[str, dict] = {}

    for conn in results:
        conn_id = conn.get("id", "")
        props = conn.get("properties", {})
        remote_vnet = props.get("remoteVirtualNetwork", {})
        spoke_vnet_id = remote_vnet.get("id", "")
        if not spoke_vnet_id:
            continue

        # Derive vHub ID by trimming /hubVirtualNetworkConnections/<name>
        parts = conn_id.rsplit("/hubVirtualNetworkConnections/", 1)
        if len(parts) != 2:
            parts = conn_id.lower().rsplit("/hubvirtualnetworkconnections/", 1)
            if len(parts) != 2:
                continue
            # Reconstruct from original case
            vhub_id = conn_id[:len(parts[0])]
        else:
            vhub_id = parts[0]

        vhub_name = vhub_id.rsplit("/", 1)[-1]
        entry = {
            "vhub_id": vhub_id,
            "vhub_name": vhub_name,
            "connection_id": conn_id,
            "connection_state": props.get("provisioningState", "Unknown"),
        }

        lookup[spoke_vnet_id.lower()] = entry
        # Name-based index — keyed by lowercased vHub name for RG-parse lookups.
        # Stores a list per name to detect ambiguity when multiple vHubs share
        # the same name across subscriptions.
        name_key = vhub_name.lower()
        if name_key not in by_name:
            by_name[name_key] = []
        # Avoid duplicate entries for the same vHub ID
        if not any(e["vhub_id"].lower() == vhub_id.lower() for e in by_name[name_key]):
            by_name[name_key].append(entry)

    log_info(f"Spoke→vHub lookup: {len(lookup)} spoke mappings, "
             f"{len(by_name)} vHub names from {len(results)} hub connections")

    lookup["_by_name"] = by_name
    return lookup


# ── Sleep prevention ────────────────────────────────────────────────────────
def _is_interactive_session() -> bool:
    if os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_CLIENT"):
        return False
    if os.environ.get("ACC_CLOUD"):
        return False
    return sys.stdin.isatty()


def prevent_sleep() -> None:
    """Ask user and activate platform-native sleep prevention."""
    global _caffeinate_proc

    if not _is_interactive_session():
        return

    choice = input("Prevent this machine from sleeping during discovery? [Y/n/q=exit]: ").strip() or "Y"
    if choice.lower() == "q":
        log_info("Exiting.")
        sys.exit(0)
    if choice.upper() != "Y":
        return

    if sys.platform == "darwin":
        if shutil.which("caffeinate"):
            _caffeinate_proc = subprocess.Popen(
                ["caffeinate", "-i", "-s", "-w", str(os.getpid())],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            atexit.register(_restore_sleep)
            log_info("Sleep prevention active (caffeinate)  \u2713")
        else:
            log_warn("caffeinate not found \u2014 sleep prevention unavailable.")
    elif sys.platform == "win32":
        try:
            import ctypes
            ES_CONTINUOUS = 0x80000000
            ES_SYSTEM_REQUIRED = 0x00000001
            ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
            atexit.register(_restore_sleep)
            log_info("Sleep prevention active (SetThreadExecutionState)  \u2713")
        except (OSError, AttributeError):
            log_warn("Could not set sleep prevention \u2014 continuing without it.")
    else:
        log_detail("Sleep prevention not needed on this platform.")


def _restore_sleep() -> None:
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
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000)
        except (OSError, AttributeError):
            pass


# ── Graph availability check ────────────────────────────────────────────────
def check_graph_available(subscription: str) -> bool:
    """Probe whether az graph query works. Returns False if unavailable."""
    log_step("Checking Resource Graph Availability")
    probe_query = "Resources | where type =~ 'microsoft.network/virtualnetworks' | take 1 | project id"
    result = invoke_with_retry(
        "Graph availability probe",
        ["graph", "query", "-q", probe_query, "--subscriptions", subscription, "--first", "1"],
        allow_failure=True,
        error_scope="graph-probe",
        max_retries=1,
    )
    if result is None:
        log_alert(
            "Resource Graph is unavailable",
            "az graph query failed \u2014 the 'resource-graph' extension may not be installed.",
            "Run: az extension add --name resource-graph",
            "Falling back to per-VNet BFS is NOT implemented in graph-first mode.",
        )
        return False
    log_info("Resource Graph available  \u2713")
    return True


# ── Resource classification helpers ─────────────────────────────────────────
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

# ── Resource Graph Gaps ─────────────────────────────────────────────────────
# Registry of resource types where Azure Resource Graph does NOT surface the
# subnet/VNet reference property, requiring an az-cli ARM fallback to discover
# VNet-injected instances.  Each entry maps the ARM resource type (lower-case)
# to a dict with:
#   az_list_args  : az cli args to list resources in a resource group
#   subnet_path   : dot-path to extract the subnet ARM ID from the ARM response
#   kind          : "delegated" or "network" (placed into the matching bucket)
#
# Add new entries here as gaps are discovered — Phase 4b will pick them up
# automatically.
_RESOURCE_GRAPH_GAPS: dict[str, dict] = {
    "microsoft.containerinstance/containergroups": {
        "az_list_args": ["container", "list"],
        "subnet_path": "subnetIds[0].id",
        "kind": "delegated",
    },
    # Example — uncomment when a gap is confirmed:
    # "microsoft.network/someresource": {
    #     "az_list_args": ["network", "someresource", "list"],
    #     "subnet_path": "properties.subnet.id",
    #     "kind": "network",
    # },
}


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

    if "natgateways" in rtype_lower:
        # NAT Gateways store a back-reference: properties.subnets[]{id}
        nat_subnets = props.get("subnets") or []
        if nat_subnets:
            return nat_subnets[0].get("id", "")
        return ""

    if any(t in rtype_lower for t in ("azurefirewalls", "virtualnetworkgateways", "bastionhosts", "dnsresolvers")):
        ip_cfgs = props.get("ipConfigurations", [])
        if ip_cfgs:
            return ip_cfgs[0].get("properties", {}).get("subnet", {}).get("id", "")
        # Bastion Developer SKU: no ipConfigurations, uses virtualNetwork.id
        # Subnet is always AzureBastionSubnet.
        if "bastionhosts" in rtype_lower:
            vnet_ref = (props.get("virtualNetwork") or {}).get("id", "")
            if vnet_ref:
                return f"{vnet_ref}/subnets/AzureBastionSubnet"

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
        return subnet_ids[0].get("id", "") if subnet_ids else ""
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
        return "Linux" if "linux" in kind else "Windows"
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


def _extract_peerings_from_circuit(circuit_props: dict) -> list[dict]:
    """Extract peering details from ER circuit properties.

    Resource Graph returns peerings as sub-resources with nested properties
    (``{id, name, type, properties: {peeringType, …}}``), whereas the az CLI
    flattens them so fields sit at the top level.  We handle both layouts.
    """
    raw = circuit_props.get("peerings") or []
    result: list[dict] = []
    for p in raw:
        # Resource Graph nests fields under "properties"; az CLI does not.
        inner = p.get("properties") or p
        obj: dict[str, Any] = {
            "peeringType": inner.get("peeringType", ""),
            "state": inner.get("state", ""),
        }
        if inner.get("vlanId") is not None:
            obj["vlanId"] = inner["vlanId"]
        if inner.get("primaryPeerAddressPrefix"):
            obj["primaryPeerAddressPrefix"] = inner["primaryPeerAddressPrefix"]
        if inner.get("secondaryPeerAddressPrefix"):
            obj["secondaryPeerAddressPrefix"] = inner["secondaryPeerAddressPrefix"]
        if inner.get("peerASN") is not None:
            obj["peerASN"] = inner["peerASN"]
        ms_cfg = inner.get("microsoftPeeringConfig") or {}
        if ms_cfg.get("advertisedPublicPrefixes"):
            obj["advertisedPublicPrefixes"] = ms_cfg["advertisedPublicPrefixes"]
        result.append(obj)
    return result


# ── OnPremises synthesis ────────────────────────────────────────────────────
def _synthesize_on_premises(er_circuits: list[dict], lngs_list: list[dict]) -> list[dict]:
    """Synthesise on-premises site entries from ER circuit private peerings and LNGs."""
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

    # LNG-based on-premises entries (VPN)
    for lng in lngs_list:
        lng_id = lng.get("id", "")
        key = lng_id.lower()
        if key in seen:
            continue
        seen.add(key)
        lng_props = lng.get("properties", {}) if "properties" in lng else lng
        gw_ip = lng_props.get("gatewayIpAddress") or lng.get("gatewayIpAddress", "")
        addr_prefixes = (lng_props.get("localNetworkAddressSpace") or {}).get("addressPrefixes", [])
        if not addr_prefixes:
            addr_prefixes = lng.get("localAddressSpace", [])
        name = lng.get("name", "VPN Site")
        if gw_ip:
            name += f" ({gw_ip})"
        site = {
            "id": f"onprem-vpn-{lng.get('name', 'unknown').lower().replace(' ', '-')}",
            "name": name,
            "location": lng.get("location", ""),
            "lngId": lng_id,
            "type": "VPN",
        }
        if gw_ip:
            site["gatewayIpAddress"] = gw_ip
        if addr_prefixes:
            site["ipRanges"] = addr_prefixes
        sites.append(site)

    return sites


# ── Merge Engine ────────────────────────────────────────────────────────────
_ONPREM_USER_FIELDS = ("name", "description", "ipRanges", "notes")


def merge_user_edits(
    baseline_data: dict[str, Any],
    target_data: dict[str, Any],
) -> dict[str, int]:
    """Apply user-authored content from baseline onto target, matched by ARM resource ID."""
    summary = {
        "applied_layouts": 0, "merged_edits": 0, "merged_tags": 0,
        "preserved_onprem": 0, "orphaned": 0, "new_resources": 0,
    }

    baseline_by_id: dict[str, dict] = {}
    for collection in ("vnets", "expressRouteCircuits"):
        for item in baseline_data.get(collection, []):
            baseline_by_id[item["id"].lower()] = item

    baseline_onprem_by_id: dict[str, dict] = {}
    for site in baseline_data.get("onPremises", []):
        baseline_onprem_by_id[site["id"].lower()] = site

    target_ids: set[str] = set()
    for collection in ("vnets", "expressRouteCircuits"):
        for item in target_data.get(collection, []):
            target_ids.add(item["id"].lower())
    for site in target_data.get("onPremises", []):
        target_ids.add(site["id"].lower())

    # Apply layouts and x-aed-* tags to VNets and ER circuits
    for collection in ("vnets", "expressRouteCircuits"):
        for item in target_data.get(collection, []):
            key = item["id"].lower()
            baseline_item = baseline_by_id.get(key)
            if not baseline_item:
                summary["new_resources"] += 1
                continue
            if "_layout" in baseline_item:
                item["_layout"] = baseline_item["_layout"]
                summary["applied_layouts"] += 1
            baseline_tags = baseline_item.get("tags", {})
            aed_tags = {k: v for k, v in baseline_tags.items() if k.startswith("x-aed-")}
            if aed_tags:
                target_tags = item.get("tags", {})
                target_tags.update(aed_tags)
                item["tags"] = target_tags
                summary["merged_tags"] += 1

    # Apply layouts, user edits, and x-aed-* tags to onPremises
    matched_onprem_ids: set[str] = set()
    for site in target_data.get("onPremises", []):
        key = site["id"].lower()
        baseline_site = baseline_onprem_by_id.get(key)
        if not baseline_site:
            summary["new_resources"] += 1
            continue
        matched_onprem_ids.add(key)
        if "_layout" in baseline_site:
            site["_layout"] = baseline_site["_layout"]
            summary["applied_layouts"] += 1
        edited = False
        for field in _ONPREM_USER_FIELDS:
            if field in baseline_site and baseline_site[field]:
                site[field] = baseline_site[field]
                edited = True
        if edited:
            summary["merged_edits"] += 1

    # Preserve user-created onPremises entries not in target
    for key, baseline_site in baseline_onprem_by_id.items():
        if key not in matched_onprem_ids and key not in target_ids:
            target_data.setdefault("onPremises", []).append(baseline_site)
            summary["preserved_onprem"] += 1

    # Count orphaned
    for key in baseline_by_id:
        if key not in target_ids:
            summary["orphaned"] += 1
            log_warn(f"Orphaned baseline resource: {baseline_by_id[key].get('name', key)}")

    # topologyVersion
    prev = baseline_data.get("topologyVersion")
    if isinstance(prev, int) and prev >= 1:
        target_data["topologyVersion"] = prev + 1
    else:
        target_data["topologyVersion"] = target_data.get("topologyVersion", 1)

    return summary


# ── Incremental Mode \u2014 Baseline Validation ──────────────────────────────────

def validate_baseline_for_incremental(
    baseline: dict[str, Any],
) -> tuple[bool, str]:
    """Validate that a baseline topology is suitable for incremental discovery.

    Checks schema version, script version, age, and discovery method.
    Returns (is_valid, reason) \u2014 reason is empty string when valid.
    """
    # Schema version must match
    baseline_schema = baseline.get("schemaVersion", "")
    if baseline_schema != SCHEMA_VERSION:
        return False, (f"Schema version mismatch: baseline={baseline_schema}, "
                       f"current={SCHEMA_VERSION}")

    # Script version must match
    baseline_script_ver = baseline.get("_scriptVersion", "")
    if baseline_script_ver != SCRIPT_VERSION:
        return False, (f"Script version mismatch: baseline={baseline_script_ver}, "
                       f"current={SCRIPT_VERSION}")

    # Discovery method must be graph-first-scoped-crawl
    baseline_method = baseline.get("_discoveryMethod", "")
    if baseline_method != "graph-first-scoped-crawl":
        return False, (f"Incompatible discovery method: baseline={baseline_method}, "
                       f"expected=graph-first-scoped-crawl")

    # Baseline must not be older than INCREMENTAL_MAX_AGE_DAYS
    generated_at = baseline.get("generatedAt", "")
    if not generated_at:
        return False, "Baseline has no generatedAt timestamp"
    try:
        baseline_time = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
        age_days = (datetime.now(timezone.utc) - baseline_time).total_seconds() / 86400
        if age_days > INCREMENTAL_MAX_AGE_DAYS:
            return False, (f"Baseline too old: {age_days:.1f} days "
                           f"(max {INCREMENTAL_MAX_AGE_DAYS} days)")
    except (ValueError, TypeError) as e:
        return False, f"Cannot parse baseline generatedAt '{generated_at}': {e}"

    # Must have vnets array
    if not baseline.get("vnets"):
        return False, "Baseline has no vnets data"

    return True, ""


# ── Incremental Mode \u2014 Seed & Verify ───────────────────────────────────────

def phase1_incremental_seed(
    baseline_data: dict[str, Any],
    *,
    vnet_id: str = "",
    vhub_id: str = "",
    resource_group: str = "",
    subscription: str = "",
) -> list[dict]:
    """Extract VNet/vHub seeds from baseline vnets[] array (T004).

    Scope handling (T021):
    - --vnet-id / --vhub-id: NOT used as filters. These are BFS starting points
      in full mode; the baseline already contains the full peered topology
      discovered from that seed, so all baseline VNets are returned.
    - --resource-group / --subscription: Used as scope restrictions to filter
      baseline VNets. Cross-subscription peers are always preserved.

    Returns list of dicts matching phase1_seed_resolution() output structure:
    each has id, name, type, location, resourceGroup, subscriptionId, properties, tags.
    """
    log_step("Phase 1 \u2014 Incremental Seed (from baseline)")
    seeds: list[dict] = []
    filtered_count = 0
    for vnet in baseline_data.get("vnets", []):
        vid = vnet.get("id", "")

        # T021: Scope filtering — only resource_group and subscription restrict
        # vnet_id / vhub_id are starting-point hints, not scope filters
        if resource_group and vnet.get("resourceGroup", "").lower() != resource_group.lower():
            # Keep cross-subscription peers (different sub = different RG)
            if subscription and vnet.get("subscriptionId", "").lower() == subscription.lower():
                filtered_count += 1
                continue

        seed = {
            "id": vid,
            "name": vnet.get("name", ""),
            "type": vnet.get("type", "microsoft.network/virtualnetworks"),
            "location": vnet.get("location", ""),
            "resourceGroup": vnet.get("resourceGroup", ""),
            "subscriptionId": vnet.get("subscriptionId", ""),
            "properties": vnet.get("properties", {}),
            "tags": vnet.get("tags", {}),
        }
        # Preserve internal flags from baseline
        for key in ("_accessDenied", "_discoveryFailed", "_hvVnetId", "_hubConnections",
                     "_siblingHubs", "_isVirtualHub", "_vhubResourceId", "_hubConfig", "_vwanId"):
            if key in vnet:
                seed[key] = vnet[key]
        seeds.append(seed)

    if filtered_count:
        log_info(f"Scope filter: {filtered_count} baseline VNet(s) outside current scope")
    log_info(f"Baseline seeds: {len(seeds)} VNet(s)/vHub(s)")
    return seeds


def phase2_incremental_verify(
    subscription: str,
    baseline_seeds: list[dict],
    *,
    spoke_to_vhub: dict[str, dict] | None = None,
) -> tuple[list[dict], list[str], list[dict]]:
    """Verify baseline VNets still exist and detect new peers (T005/T006).

    Returns (verified_vnets, deleted_ids, new_vnets):
      - verified_vnets: baseline VNets confirmed to still exist
      - deleted_ids: baseline VNet IDs no longer in Azure
      - new_vnets: newly discovered VNets not in baseline (via peering check)

    When spoke_to_vhub is provided, newly discovered HV_* peers are resolved
    using the pre-fetched lookup for deterministic vHub identification.
    """
    log_step("Phase 2 \u2014 Incremental Verify & Peer Check")

    if not baseline_seeds:
        return [], [], []

    baseline_ids = {s["id"].lower(): s for s in baseline_seeds}

    # ── T005: Bulk existence check ──
    # Skip access-denied / discovery-failed placeholders (they have no real data)
    real_seeds = [s for s in baseline_seeds
                  if not s.get("_accessDenied") and not s.get("_discoveryFailed")]

    # T024: For vHub seeds with _vhubResourceId, query the vHub resource ID
    # (accessible subscription) instead of the HV_* managed VNet ID
    query_id_to_seed_id: dict[str, str] = {}  # maps query ID → original seed ID
    query_ids: list[str] = []
    for s in real_seeds:
        seed_id = s["id"]
        vhub_rid = s.get("_vhubResourceId", "")
        if vhub_rid and vhub_rid.lower() != seed_id.lower():
            query_ids.append(vhub_rid)
            query_id_to_seed_id[vhub_rid.lower()] = seed_id.lower()
        else:
            query_ids.append(seed_id)
            query_id_to_seed_id[seed_id.lower()] = seed_id.lower()

    existing_ids: set[str] = set()
    if query_ids:
        for i in range(0, len(query_ids), GRAPH_BATCH_SIZE):
            chunk = query_ids[i:i + GRAPH_BATCH_SIZE]
            id_list = ", ".join(f"'{vid}'" for vid in chunk)
            query = f"""Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/virtualhubs')
  and id in~ ({id_list})
| project id"""
            target_subs = list({extract_sub_id(v) for v in chunk if extract_sub_id(v)}) or [subscription]
            results = invoke_graph_query_paginated(
                f"Incremental verify batch {i // GRAPH_BATCH_SIZE + 1} ({len(chunk)} IDs)",
                query, target_subs,
                error_scope="incremental/verify",
                phase="Phase 2 \u2014 Incremental Verify",
            )
            if results is not _QUERY_FAILED:
                for r in results:
                    found_id = r["id"].lower()
                    # Map query result back to original seed ID
                    seed_id = query_id_to_seed_id.get(found_id, found_id)
                    existing_ids.add(seed_id)
            else:
                # If verify query fails, assume all exist (safe fallback)
                log_warn("Verify query failed \u2014 assuming all baseline VNets exist")
                for v in chunk:
                    seed_id = query_id_to_seed_id.get(v.lower(), v.lower())
                    existing_ids.add(seed_id)

    # Include access-denied/discovery-failed as "existing" (we can't verify them)
    placeholder_ids = {s["id"].lower() for s in baseline_seeds
                       if s.get("_accessDenied") or s.get("_discoveryFailed")}
    existing_ids |= placeholder_ids

    # Build verified list and deleted list
    verified: list[dict] = []
    deleted: list[str] = []
    for seed in baseline_seeds:
        if seed["id"].lower() in existing_ids:
            verified.append(seed)
        else:
            deleted.append(seed["id"])
            log_warn(f"Deleted since baseline: {seed.get('name', '?')} ({arm_basename(seed['id'])})")

    log_info(f"Verified: {len(verified)} exist, {len(deleted)} deleted")

    # ── T006: Peering check for new VNets ──
    verified_ids_lower = {v["id"].lower() for v in verified}
    # Also include HV_ aliases and resolved vHub resource IDs
    for v in verified:
        hv = v.get("_hvVnetId", "")
        if hv:
            verified_ids_lower.add(hv.lower())
        vhub_rid = v.get("_vhubResourceId", "")
        if vhub_rid:
            verified_ids_lower.add(vhub_rid.lower())

    # Query current peerings of all verified VNets (skip placeholders)
    verifiable = [v["id"] for v in verified
                  if not v.get("_accessDenied") and not v.get("_discoveryFailed")
                  and "virtualnetworks" in v.get("type", "").lower()]

    new_peer_ids: set[str] = set()
    if verifiable:
        for i in range(0, len(verifiable), GRAPH_BATCH_SIZE):
            chunk = verifiable[i:i + GRAPH_BATCH_SIZE]
            id_list = ", ".join(f"'{vid}'" for vid in chunk)
            query = f"""Resources
| where type =~ 'microsoft.network/virtualnetworks' and id in~ ({id_list})
| mv-expand peering = properties.virtualNetworkPeerings
| project remoteVnetId = tolower(peering.properties.remoteVirtualNetwork.id)
| where isnotempty(remoteVnetId)
| distinct remoteVnetId"""
            target_subs = list({extract_sub_id(v) for v in chunk if extract_sub_id(v)}) or [subscription]
            results = invoke_graph_query_paginated(
                f"Peering check batch {i // GRAPH_BATCH_SIZE + 1}",
                query, target_subs,
                id_field="remoteVnetId",
                error_scope="incremental/peering-check",
                phase="Phase 2 \u2014 Incremental Peer Check",
            )
            if results is not _QUERY_FAILED:
                for r in results:
                    remote_id = r.get("remoteVnetId", "")
                    if remote_id and remote_id.lower() not in verified_ids_lower:
                        new_peer_ids.add(remote_id)

    # Fetch full data for newly discovered VNets
    new_vnets: list[dict] = []
    if new_peer_ids:
        # Separate HV_* managed VNets from regular targets — HV_* VNets
        # can't be fetched via Graph and need vHub resolution instead.
        hv_peers = {p for p in new_peer_ids if is_vhub_vnet_id(p)}
        regular_peers = new_peer_ids - hv_peers
        seen_resolved_ids: set[str] = set()

        for hv_id in sorted(hv_peers):
            vhub_data = resolve_vhub_id_from_vnet(hv_id, subscription, spoke_to_vhub=spoke_to_vhub)
            if vhub_data and isinstance(vhub_data, dict):
                vhub_id_lower = vhub_data["id"].lower()
                if vhub_id_lower in verified_ids_lower or vhub_id_lower in seen_resolved_ids:
                    log_substep(f"Resolved HV_* → {vhub_data.get('name', '?')} (already known, skipping)")
                    continue
                seen_resolved_ids.add(vhub_id_lower)
                vhub_data["_hvVnetId"] = hv_id
                new_vnets.append(vhub_data)
                log_found(f"New (resolved vHub): {vhub_data.get('name', '?')}")
            else:
                rg_name = _parse_vhub_name_from_rg(hv_id)
                display_name = rg_name or _guess_vhub_name(arm_basename(hv_id)) or arm_basename(hv_id)
                log_warn(f"Unresolvable new HV_ peer \u2192 placeholder: {display_name}")
                new_vnets.append({
                    "id": hv_id, "name": display_name,
                    "type": "microsoft.network/virtualhubs",
                    "location": "unknown",
                    "resourceGroup": extract_rg(hv_id) or "unknown",
                    "subscriptionId": extract_sub_id(hv_id) or "",
                    "properties": {}, "tags": {},
                    "_accessDenied": True, "_hvVnetId": hv_id,
                })

        log_info(f"Detected {len(new_peer_ids)} new peered VNet(s) not in baseline"
                 f" ({len(hv_peers)} HV_*, {len(regular_peers)} regular)")
        new_list = sorted(regular_peers)
        for i in range(0, len(new_list), GRAPH_BATCH_SIZE):
            chunk = new_list[i:i + GRAPH_BATCH_SIZE]
            id_list = ", ".join(f"'{vid}'" for vid in chunk)
            query = f"""Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/virtualhubs')
  and id in~ ({id_list})
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
            target_subs = list({extract_sub_id(v) for v in chunk if extract_sub_id(v)}) or [subscription]
            results = invoke_graph_query_paginated(
                f"Fetch new VNets batch {i // GRAPH_BATCH_SIZE + 1} ({len(chunk)} IDs)",
                query, target_subs,
                error_scope="incremental/new-vnets",
                phase="Phase 2 \u2014 Incremental New VNets",
            )
            if results is not _QUERY_FAILED:
                new_vnets.extend(results)
                for r in results:
                    log_found(f"New: {r.get('name', '?')} ({r.get('type', '').split('/')[-1]}) in {r.get('resourceGroup', '?')}")
    else:
        log_info("No new peered VNets detected")

    return verified, deleted, new_vnets


# ── Incremental Mode \u2014 Selective Subnet Refresh ─────────────────────────────

def extract_baseline_subnet_resources(
    baseline_vnets: list[dict],
) -> dict[str, dict[str, list[dict]]]:
    """Extract subnet resources from baseline VNets back into Phase 4 format (T009).

    For each VNet, iterates subnets and extracts resources back into flat lists
    keyed by 'network_resources' and 'delegated_resources'. Synthesises minimal
    'properties' with subnet ID back-reference so _resolve_subnet_id() can
    re-wire them in Phase 5.

    Returns {vnet_id_lower: {"network_resources": [...], "delegated_resources": [...]}}.
    """
    _NETWORK_TYPE_PREFIXES = (
        "microsoft.network/networkinterfaces",
        "microsoft.network/applicationgateways",
        "microsoft.network/azurefirewalls",
        "microsoft.network/privateendpoints",
        "microsoft.network/loadbalancers",
        "microsoft.network/bastionhosts",
        "microsoft.network/natgateways",
        "microsoft.network/dnsresolvers",
    )

    result: dict[str, dict[str, list[dict]]] = {}

    for vnet in baseline_vnets:
        vnet_id = vnet.get("id", "")
        if not vnet_id:
            continue
        vid_lower = vnet_id.lower()

        net_resources: list[dict] = []
        deleg_resources: list[dict] = []

        for subnet in vnet.get("subnets", []):
            subnet_id = subnet.get("id", "")
            if not subnet_id:
                continue

            for res in subnet.get("resources", []):
                rtype = res.get("type", "")
                rtype_lower = rtype.lower()

                # Skip VMs — they are resolved from NICs, not queried directly
                if "virtualmachines" in rtype_lower:
                    continue

                # Reconstruct resource with synthetic properties for subnet resolution
                reconstructed: dict[str, Any] = {
                    "id": res.get("id", ""),
                    "name": res.get("name", ""),
                    "type": rtype,
                    "location": res.get("location", ""),
                    "resourceGroup": extract_rg(res.get("id", "")) or vnet.get("resourceGroup", ""),
                    "subscriptionId": extract_sub_id(res.get("id", "")) or vnet.get("subscriptionId", ""),
                    "tags": res.get("tags") or {},
                }

                # Preserve subType and publicIps if present
                if "subType" in res:
                    reconstructed["subType"] = res["subType"]
                if "publicIps" in res:
                    reconstructed["publicIps"] = res["publicIps"]

                # Synthesise properties with subnet back-reference
                is_network = any(rtype_lower.startswith(t) for t in _NETWORK_TYPE_PREFIXES)
                if is_network:
                    if "networkinterfaces" in rtype_lower:
                        reconstructed["properties"] = {
                            "ipConfigurations": [{"properties": {"subnet": {"id": subnet_id}}}]
                        }
                    elif "applicationgateways" in rtype_lower:
                        reconstructed["properties"] = {
                            "gatewayIPConfigurations": [{"properties": {"subnet": {"id": subnet_id}}}]
                        }
                    elif "privateendpoints" in rtype_lower:
                        reconstructed["properties"] = {"subnet": {"id": subnet_id}}
                    elif "loadbalancers" in rtype_lower:
                        reconstructed["properties"] = {
                            "frontendIPConfigurations": [{"properties": {"subnet": {"id": subnet_id}}}]
                        }
                    elif "natgateways" in rtype_lower:
                        reconstructed["properties"] = {"subnets": [{"id": subnet_id}]}
                    else:
                        # azurefirewalls, bastionhosts, dnsresolvers, virtualnetworkgateways
                        reconstructed["properties"] = {
                            "ipConfigurations": [{"properties": {"subnet": {"id": subnet_id}}}]
                        }
                    net_resources.append(reconstructed)
                else:
                    # Delegated resource — synthesise the most common subnet reference
                    reconstructed["properties"] = {"virtualNetworkSubnetId": subnet_id}
                    if "kind" in res:
                        reconstructed["kind"] = res["kind"]
                    deleg_resources.append(reconstructed)

        result[vid_lower] = {
            "network_resources": net_resources,
            "delegated_resources": deleg_resources,
        }

    return result


def phase4_incremental_fingerprint(
    subscription: str,
    vnet_ids: list[str],
) -> dict[str, int] | None:
    """Query lightweight resource counts per VNet for change detection (T010).

    Returns {vnet_id_lower: count} or None if the query fails.
    """
    if not vnet_ids:
        return {}

    all_subs = list({extract_sub_id(v) for v in vnet_ids if extract_sub_id(v)}) or [subscription]

    # Build a list of all resource types we care about (network + delegated)
    all_types = [
        "microsoft.network/networkinterfaces",
        "microsoft.network/applicationgateways",
        "microsoft.network/azurefirewalls",
        "microsoft.network/privateendpoints",
        "microsoft.network/loadbalancers",
        "microsoft.network/bastionhosts",
        "microsoft.network/natgateways",
        "microsoft.network/dnsresolvers",
    ] + list(_DELEGATED_TYPES)
    type_list = ", ".join(f"'{t}'" for t in all_types)

    counts: dict[str, int] = {}
    for i in range(0, len(vnet_ids), GRAPH_BATCH_SIZE):
        chunk = vnet_ids[i:i + GRAPH_BATCH_SIZE]
        id_list = ", ".join(f"'{vid}'" for vid in chunk)
        query = f"""Resources
| where type in~ ({type_list})
| extend subnetId = coalesce(
    properties.ipConfigurations[0].properties.subnet.id,
    properties.gatewayIPConfigurations[0].properties.subnet.id,
    properties.subnet.id,
    properties.ipConfigurations[0].subnet.id,
    properties.ipConfiguration.properties.subnet.id,
    properties.frontendIPConfigurations[0].properties.subnet.id,
    properties.subnets[0].id,
    properties.virtualNetwork.id,
    properties.virtualNetworkSubnetId,
    properties.subnetId,
    properties.virtualNetworkConfiguration.subnetResourceId,
    properties.subnetIds[0].id,
    properties.vnetConfiguration.infrastructureSubnetId,
    properties.parameters.customVirtualNetworkId.value,
    properties.virtualNetworkConfiguration.subnetId
  )
| where isnotempty(subnetId)
| extend vnetId = tolower(extract('(/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\\\\.network/virtualnetworks/[^/]+)', 1, tostring(subnetId)))
| where vnetId in~ ({id_list})
| summarize resourceCount=count() by vnetId"""

        target_subs = list({extract_sub_id(v) for v in chunk if extract_sub_id(v)}) or [subscription]
        results = invoke_graph_query_paginated(
            f"Fingerprint batch {i // GRAPH_BATCH_SIZE + 1} ({len(chunk)} VNets)",
            query, target_subs,
            id_field="vnetId",
            error_scope="incremental/fingerprint",
            phase="Phase 4 \u2014 Incremental Fingerprint",
        )
        if results is _QUERY_FAILED:
            log_warn("Fingerprint query failed \u2014 cannot determine changed VNets")
            return None
        for r in results:
            vid = r.get("vnetId", "").lower()
            if vid:
                counts[vid] = r.get("resourceCount", 0)

    return counts


def compare_fingerprints(
    fingerprints: dict[str, int],
    baseline_resources: dict[str, dict[str, list[dict]]],
    all_vnet_ids: list[str],
) -> tuple[list[str], list[str], list[str]]:
    """Compare live fingerprints against baseline resource counts (T011).

    Returns (changed_ids, unchanged_ids, new_ids):
      - changed_ids: VNets where count differs (need refresh)
      - unchanged_ids: VNets where count matches (reuse baseline)
      - new_ids: VNets not in baseline (need full query)
    """
    changed: list[str] = []
    unchanged: list[str] = []
    new: list[str] = []

    for vid in all_vnet_ids:
        vid_lower = vid.lower()
        if vid_lower not in baseline_resources:
            new.append(vid)
            continue

        baseline_data = baseline_resources[vid_lower]
        baseline_count = (len(baseline_data.get("network_resources", []))
                          + len(baseline_data.get("delegated_resources", [])))
        live_count = fingerprints.get(vid_lower, 0)

        if live_count != baseline_count:
            changed.append(vid)
        else:
            unchanged.append(vid)

    return changed, unchanged, new


def phase4_incremental(
    subscription: str,
    all_vnets: list[dict],
    baseline_data: dict[str, Any],
) -> tuple[dict[str, list[dict]], list[str]]:
    """Orchestrate selective subnet refresh for incremental mode (T012).

    Returns (subnet_resources, changed_vnet_ids) where subnet_resources has the
    same structure as phase4_subnet_resources() output, and changed_vnet_ids
    lists VNets that were re-queried (for phase4b fallback scoping).
    """
    log_step("Phase 4 \u2014 Incremental Subnet Refresh")

    # Extract baseline subnet resources for all baseline VNets
    baseline_vnets = baseline_data.get("vnets", [])
    baseline_resources = extract_baseline_subnet_resources(baseline_vnets)
    log_info(f"Extracted baseline subnet data for {len(baseline_resources)} VNet(s)")

    # Identify accessible VNets for fingerprinting
    accessible = [v for v in all_vnets
                  if not v.get("_accessDenied") and not v.get("_discoveryFailed")
                  and "virtualnetworks" in v.get("type", "").lower()]
    accessible_ids = [v["id"] for v in accessible]

    if not accessible_ids:
        log_warn("No accessible VNets \u2014 skipping incremental subnet refresh")
        return {"network_resources": [], "delegated_resources": [], "vms": []}, []

    # Run fingerprint query
    fingerprints = phase4_incremental_fingerprint(subscription, accessible_ids)
    if fingerprints is None:
        # Fingerprint failed — fall back to full Phase 4 (T020)
        log_warn("Fingerprint failed \u2014 falling back to full Phase 4 for all VNets")
        full_result = phase4_subnet_resources(subscription, all_vnets)
        return full_result, accessible_ids

    # Compare fingerprints against baseline
    changed, unchanged, new = compare_fingerprints(fingerprints, baseline_resources, accessible_ids)
    log_info(f"Fingerprint: {len(unchanged)} unchanged, {len(changed)} changed, {len(new)} new")

    # Merge subnet resources
    all_network: list[dict] = []
    all_delegated: list[dict] = []

    # Reuse baseline data for unchanged VNets
    for vid in unchanged:
        vid_lower = vid.lower()
        if vid_lower in baseline_resources:
            all_network.extend(baseline_resources[vid_lower]["network_resources"])
            all_delegated.extend(baseline_resources[vid_lower]["delegated_resources"])

    # Build a synthetic all_vnets list for changed + new VNets only
    refresh_ids = set(v.lower() for v in changed + new)
    refresh_vnets = [v for v in all_vnets if v["id"].lower() in refresh_ids]

    if refresh_vnets:
        log_info(f"Querying subnet resources for {len(refresh_vnets)} changed/new VNet(s)")
        refreshed = phase4_subnet_resources(subscription, refresh_vnets)
        all_network.extend(refreshed.get("network_resources", []))
        all_delegated.extend(refreshed.get("delegated_resources", []))
        vms = refreshed.get("vms", [])
    else:
        # Still need VM data for NIC resolution of reused resources
        log_substep("Querying VMs for NIC resolution (reused VNets)...")
        all_subs = list({extract_sub_id(v["id"]) for v in all_vnets if extract_sub_id(v["id"])}) or [subscription]
        vm_query = """Resources
| where type =~ 'microsoft.compute/virtualMachines' and isnotnull(properties.networkProfile)
| mv-expand nic = properties.networkProfile.networkInterfaces
| project vmId=id, vmName=name, vmType=type, nicId=tolower(nic.id), location, resourceGroup, subscriptionId, tags"""
        vm_data = invoke_graph_query_paginated(
            "Query VMs", vm_query, all_subs,
            error_scope="incremental/vm-query", id_field="vmId",
            phase="Phase 4 \u2014 VM Resolution (incremental)",
        )
        vms = [] if vm_data is _QUERY_FAILED else vm_data

    result = {
        "network_resources": all_network,
        "delegated_resources": all_delegated,
        "vms": vms,
    }
    return result, changed + new


# ═════════════════════════════════════════════════════════════════════════════
# Phase 1 \u2014 Seed Resolution
# ═════════════════════════════════════════════════════════════════════════════

def phase1_seed_resolution(
    subscription: str,
    vnet_id: str = "",
    vhub_id: str = "",
    resource_group: str = "",
) -> list[dict]:
    """Resolve initial VNet/vHub seeds via a single Graph query."""
    log_step("Phase 1 \u2014 Seed Resolution")

    if vnet_id:
        query = f"""Resources
| where type =~ 'microsoft.network/virtualnetworks' and id =~ '{vnet_id}'
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
        label = f"Seed VNet: {arm_basename(vnet_id)}"
    elif vhub_id:
        query = f"""Resources
| where type =~ 'microsoft.network/virtualhubs' and id =~ '{vhub_id}'
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
        label = f"Seed vHub: {arm_basename(vhub_id)}"
    elif resource_group:
        query = f"""Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/virtualhubs') and resourceGroup =~ '{resource_group}'
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
        label = f"All VNets/vHubs in RG: {resource_group}"
    else:
        query = """Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/virtualhubs')
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
        label = "All VNets/vHubs in subscription"

    seeds = invoke_graph_query_paginated(
        label, query, subscription,
        error_scope="phase1/seed-resolution",
        phase="Phase 1 \u2014 Seed Resolution",
    )
    log_info(f"Seeds resolved: {len(seeds)} VNet(s)/vHub(s)")
    for s in seeds:
        log_found(f"{s.get('name', '?')} ({s.get('type', '').split('/')[-1]}) in {s.get('resourceGroup', '?')}")
    return seeds


# ═════════════════════════════════════════════════════════════════════════════
# Phase 2 \u2014 BFS Wave Expansion
# ═════════════════════════════════════════════════════════════════════════════

def _discover_vhub_connections(hub: dict, subscription: str) -> list[dict]:
    """Call az network vhub connection list to get spoke VNet connections.

    Resource Graph does NOT include virtualHubConnections in vHub properties,
    so we must use an explicit CLI call per vHub.  The returned connections
    are stored on the hub dict under '_hubConnections' for later use by
    _build_vnet_object.
    """
    hub_name = hub.get("name", "")
    rg = hub.get("resourceGroup", "")
    if not hub_name or not rg:
        return []
    # Use the vHub's own subscription — cross-sub vHubs won't be found
    # under the crawl subscription.
    hub_sub = hub.get("subscriptionId") or extract_sub_id(hub.get("id", "")) or subscription
    log_substep(f"Fetching spoke connections for vHub {hub_name}...")
    conns = invoke_with_retry(
        f"List vHub connections ({hub_name})",
        ["network", "vhub", "connection", "list",
         "--vhub-name", hub_name, "--subscription", hub_sub, "--resource-group", rg],
        max_retries=1, allow_failure=True,
    ) or []
    log_found(f"{len(conns)} spoke connection(s) found for {hub_name}")
    hub["_hubConnections"] = conns
    return conns


def _extract_peering_targets(resources: list[dict]) -> set[str]:
    """Extract peered VNet/vHub IDs from Resource Graph VNet properties.

    For vHubs, targets come from '_hubConnections' populated by
    _discover_vhub_connections() (not from Graph properties).
    """
    targets: set[str] = set()
    for r in resources:
        props = r.get("properties", {})
        rtype = r.get("type", "").lower()

        if "virtualnetworks" in rtype:
            for p in props.get("virtualNetworkPeerings", []):
                remote = (p.get("properties", {}).get("remoteVirtualNetwork") or {}).get("id", "")
                if remote:
                    targets.add(remote)
        elif "virtualhubs" in rtype:
            # Use stored CLI connection data (Graph doesn't include these)
            for conn in r.get("_hubConnections", []):
                remote = (conn.get("remoteVirtualNetwork") or {}).get("id", "")
                if remote:
                    targets.add(remote)
    return targets


def _discover_vwan_siblings(vwan_id: str, current_hub_id: str, subscription: str) -> list[str]:
    """Discover sibling hub IDs from a vWAN resource."""
    if not vwan_id:
        return []
    log_substep(f"Checking vWAN inter-hub links for {arm_basename(vwan_id)}...")
    vwan_json = invoke_with_retry(
        "Get vWAN", ["network", "vwan", "show", "--ids", vwan_id],
        max_retries=1, allow_failure=True,
    ) or {}
    siblings: list[str] = []
    for hub_ref in vwan_json.get("virtualHubs") or []:
        sibling_id = hub_ref.get("id", "")
        if sibling_id and sibling_id.lower() != current_hub_id.lower():
            siblings.append(sibling_id)
            log_found(f"Sibling hub: {arm_basename(sibling_id)}")
    return siblings


def phase2_bfs_expansion(
    subscription: str,
    seeds: list[dict],
    *,
    spoke_to_vhub: dict[str, dict] | None = None,
) -> list[dict]:
    """BFS wave expansion \u2014 fetch peered VNets in batched Graph queries.

    When spoke_to_vhub is provided, HV_* managed VNet resolution uses the
    pre-fetched lookup for deterministic vHub identification.
    """
    log_step("Phase 2 \u2014 BFS Wave Expansion")

    all_discovered: list[dict] = list(seeds)
    seen_ids: set[str] = {r["id"].lower() for r in seeds}
    wave = 0

    # Collect vWAN sibling targets from any vHub seeds
    vwan_targets: set[str] = set()
    for s in seeds:
        if "virtualhubs" in s.get("type", "").lower():
            # Fetch spoke connections via CLI (Graph doesn't include them)
            _discover_vhub_connections(s, subscription)
            vwan_id = s.get("properties", {}).get("virtualWan", {}).get("id", "")
            if vwan_id:
                sibling_ids = _discover_vwan_siblings(vwan_id, s["id"], subscription)
                s.setdefault("_siblingHubs", []).extend(sibling_ids)
                for sib in sibling_ids:
                    if sib.lower() not in seen_ids:
                        vwan_targets.add(sib)

    new_targets = _extract_peering_targets(seeds) | vwan_targets
    new_targets = {t for t in new_targets if t.lower() not in seen_ids}

    while new_targets:
        wave += 1
        target_list = sorted(new_targets)
        log_resource(f"Wave {wave}: {len(target_list)} peered VNet(s)/vHub(s) to fetch")

        # ── Separate HV_* managed VNets from regular targets ──
        # HV_* VNets are hidden vWAN-managed VNets that can't be fetched via
        # Graph.  We resolve them to real vHub ARM IDs and query those instead.
        regular_targets: list[str] = []
        resolved_vhubs: list[dict] = []
        resolved_hvnet_ids: set[str] = set()  # track original HV_ IDs that were resolved

        for t in target_list:
            if is_vhub_vnet_id(t):
                vhub_data = resolve_vhub_id_from_vnet(t, subscription, spoke_to_vhub=spoke_to_vhub)
                if vhub_data and isinstance(vhub_data, dict):
                    vhub_id_lower = vhub_data["id"].lower()
                    if vhub_id_lower not in seen_ids:
                        resolved_vhubs.append(vhub_data)
                        # Keep the original HV_ VNet ID as an alias so peering
                        # connections still match in the output
                        vhub_data["_hvVnetId"] = t
                    resolved_hvnet_ids.add(t.lower())
                else:
                    # Could not resolve the vHub — emit an access-denied
                    # placeholder so the viewer still shows a vHub card
                    # instead of silently dropping it or creating a phantom VNet.
                    # Prefer RG-parsed name (always untruncated) over guessed name.
                    rg_name = _parse_vhub_name_from_rg(t)
                    hub_guess = rg_name or _guess_vhub_name(arm_basename(t))
                    display_name = hub_guess if hub_guess else arm_basename(t)
                    log_warn(f"Unresolvable HV_ managed VNet → access-denied vHub placeholder: {display_name}")
                    placeholder = {
                        "id": t, "name": display_name,
                        "type": "microsoft.network/virtualhubs",
                        "location": "unknown",
                        "resourceGroup": extract_rg(t) or "unknown",
                        "subscriptionId": extract_sub_id(t) or "",
                        "properties": {}, "tags": {},
                        "_accessDenied": True, "_hvVnetId": t,
                    }
                    resolved_vhubs.append(placeholder)
                    resolved_hvnet_ids.add(t.lower())
            else:
                regular_targets.append(t)

        wave_results: list[dict] = []
        failed_batch_ids: list[str] = []  # VNet IDs from batches that failed entirely

        # Add resolved vHubs directly
        wave_results.extend(resolved_vhubs)

        # Query Graph for remaining regular targets
        if regular_targets:
            for i in range(0, len(regular_targets), GRAPH_BATCH_SIZE):
                chunk = regular_targets[i:i + GRAPH_BATCH_SIZE]
                id_list = ", ".join(f"'{vid}'" for vid in chunk)
                query = f"""Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/virtualhubs') and
 id in~ ({id_list})
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""

                # Collect all unique subscription IDs from the ARM resource IDs
                target_subs = list({extract_sub_id(t) for t in chunk if extract_sub_id(t)}) or [subscription]

                chunk_label = f"Wave {wave} batch {i // GRAPH_BATCH_SIZE + 1} ({len(chunk)} IDs)"
                results = invoke_graph_query_paginated(
                    chunk_label, query, target_subs,
                    error_scope=f"phase2/wave-{wave}/batch-{i // GRAPH_BATCH_SIZE + 1}",
                    phase=f"Phase 2 \u2014 BFS Wave {wave}",
                )
                if results is _QUERY_FAILED:
                    # Batch failed entirely — queue individual retries instead
                    # of assuming access-denied
                    log_warn(f"Batch query failed — will retry {len(chunk)} VNet(s) individually")
                    failed_batch_ids.extend(chunk)
                else:
                    wave_results.extend(results)

            # Per-VNet retry for failed batches (T220 fix)
            access_denied_ids: set[str] = set()  # track 403s from individual retries
            if failed_batch_ids:
                log_info(f"Retrying {len(failed_batch_ids)} VNet(s) individually after batch failure...")
                for vid in failed_batch_ids:
                    single_query = f"""Resources
| where type in~ ('microsoft.network/virtualnetworks', 'microsoft.network/virtualhubs') and id =~ '{vid}'
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
                    vid_sub = extract_sub_id(vid) or subscription
                    single_result = invoke_graph_query_paginated(
                        f"Retry VNet {arm_basename(vid)}",
                        single_query, vid_sub,
                        error_scope=f"phase2/wave-{wave}/retry-{arm_basename(vid)}",
                        phase=f"Phase 2 \u2014 BFS Wave {wave} (individual retry)",
                    )
                    if single_result is not _QUERY_FAILED and single_result:
                        wave_results.extend(single_result)
                    elif single_result is _QUERY_FAILED:
                        # Check whether this was access-denied so the placeholder
                        # uses _accessDenied rather than _discoveryFailed.
                        last_err = _discovery_errors[-1] if _discovery_errors else {}
                        if last_err.get("category") == "Access Denied":
                            access_denied_ids.add(vid.lower())

        for r in wave_results:
            rid = r["id"].lower()
            if rid not in seen_ids:
                seen_ids.add(rid)
                all_discovered.append(r)
                log_found(f"{r.get('name', '?')} ({r.get('type', '').split('/')[-1]}) in {r.get('resourceGroup', '?')}")
                # Also mark the original HV_ VNet ID as seen so it isn't flagged
                hv_alias = r.get("_hvVnetId", "")
                if hv_alias:
                    seen_ids.add(hv_alias.lower())

        # Placeholders for unreturned peers (skip resolved HV_ VNets)
        # Distinguish genuine access-denied (batch succeeded, VNet absent)
        # from discovery failure (batch or individual retry failed).
        returned_ids = {r["id"].lower() for r in wave_results}
        failed_ids_lower = {v.lower() for v in failed_batch_ids} if regular_targets else set()
        missing = [t for t in target_list
                   if t.lower() not in returned_ids
                   and t.lower() not in seen_ids
                   and t.lower() not in resolved_hvnet_ids]
        for m in missing:
            m_lower = m.lower()
            if m_lower in failed_ids_lower and m_lower not in access_denied_ids:
                # Query failed — NOT access denied, just couldn't reach the API
                log_warn(f"VNet not retrieved (API failure, not access-denied): {arm_basename(m)}")
                all_discovered.append({
                    "id": m, "name": arm_basename(m),
                    "type": "microsoft.network/virtualnetworks",
                    "location": "unknown", "resourceGroup": extract_rg(m) or "unknown",
                    "subscriptionId": extract_sub_id(m) or "",
                    "properties": {}, "tags": {}, "_discoveryFailed": True,
                })
            else:
                # Batch succeeded but VNet absent, or individual retry returned 403
                log_warn(f"Peered VNet not returned by Graph (access denied): {arm_basename(m)}")
                all_discovered.append({
                    "id": m, "name": arm_basename(m),
                    "type": "microsoft.network/virtualnetworks",
                    "location": "unknown", "resourceGroup": extract_rg(m) or "unknown",
                    "subscriptionId": extract_sub_id(m) or "",
                    "properties": {}, "tags": {}, "_accessDenied": True,
                })
            seen_ids.add(m_lower)

        # Collect vWAN siblings from newly discovered hubs
        new_vwan_targets: set[str] = set()
        for r in wave_results:
            if "virtualhubs" in r.get("type", "").lower():
                # Fetch spoke connections via CLI for newly discovered hubs
                _discover_vhub_connections(r, subscription)
                vwan_id = r.get("properties", {}).get("virtualWan", {}).get("id", "")
                if vwan_id:
                    sibling_ids = _discover_vwan_siblings(vwan_id, r["id"], subscription)
                    r.setdefault("_siblingHubs", []).extend(sibling_ids)
                    for sib in sibling_ids:
                        if sib.lower() not in seen_ids:
                            new_vwan_targets.add(sib)

        new_targets = _extract_peering_targets(wave_results) | new_vwan_targets
        new_targets = {t for t in new_targets if t.lower() not in seen_ids}

    log_info(f"BFS complete: {len(all_discovered)} total VNet(s)/vHub(s) across {wave} wave(s)")
    return all_discovered


# ═════════════════════════════════════════════════════════════════════════════
# Phase 3 \u2014 Backbone Resources (scoped to discovered RGs)
# ═════════════════════════════════════════════════════════════════════════════

def phase3_backbone_resources(
    subscription: str,
    discovered_vnets: list[dict],
) -> dict[str, list[dict]]:
    """Query backbone resources only in resource groups containing discovered VNets."""
    log_step("Phase 3 \u2014 Backbone Resources (scoped to discovered RGs)")

    rgs: set[str] = set()
    for v in discovered_vnets:
        rg = v.get("resourceGroup", "")
        if rg:
            rgs.add(rg)

    if not rgs:
        log_warn("No resource groups found \u2014 skipping backbone discovery")
        return {"gateways": [], "er_circuits": [], "connections": [], "lngs": [], "firewalls": []}

    log_info(f"Scoped to {len(rgs)} resource group(s): {', '.join(sorted(rgs))}")

    # Collect all unique subscription IDs from discovered VNets
    all_subs = list({v.get("subscriptionId", "") for v in discovered_vnets if v.get("subscriptionId")}) or [subscription]

    rg_list_sorted = sorted(rgs)
    all_backbone: list[dict] = []

    for i in range(0, len(rg_list_sorted), GRAPH_BATCH_SIZE):
        chunk = rg_list_sorted[i:i + GRAPH_BATCH_SIZE]
        rg_clause = ", ".join(f"'{rg}'" for rg in chunk)

        query = f"""Resources
| where type in~ (
    'microsoft.network/virtualnetworkgateways',
    'microsoft.network/expressroutecircuits',
    'microsoft.network/expressroutegateways',
    'microsoft.network/connections',
    'microsoft.network/localnetworkgateways',
    'microsoft.network/azurefirewalls',
    'microsoft.network/vpngateways',
    'microsoft.network/p2svpngateways'
) and resourceGroup in~ ({rg_clause})
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""

        chunk_label = f"Backbone in {len(chunk)} RG(s) (batch {i // GRAPH_BATCH_SIZE + 1})"
        results = invoke_graph_query_paginated(
            chunk_label, query, all_subs,
            error_scope=f"phase3/backbone-batch-{i // GRAPH_BATCH_SIZE + 1}",
            phase="Phase 3 \u2014 Backbone Resources",
        )
        all_backbone.extend(results)

    categorised: dict[str, list[dict]] = {
        "gateways": [], "er_circuits": [], "connections": [], "lngs": [], "firewalls": [],
    }
    for r in all_backbone:
        rtype = r.get("type", "").lower()
        if "virtualnetworkgateways" in rtype or "vpngateways" in rtype or "expressroutegateways" in rtype or "p2svpngateways" in rtype:
            categorised["gateways"].append(r)
        elif "expressroutecircuits" in rtype:
            categorised["er_circuits"].append(r)
        elif "connections" in rtype:
            categorised["connections"].append(r)
        elif "localnetworkgateways" in rtype:
            categorised["lngs"].append(r)
        elif "azurefirewalls" in rtype:
            categorised["firewalls"].append(r)

    for cat, items in categorised.items():
        if items:
            log_found(f"{len(items)} {cat.replace('_', ' ')}")

    return categorised


# ═════════════════════════════════════════════════════════════════════════════
# Phase 4 \u2014 Subnet Resources (batched by discovered VNet IDs)
# ═════════════════════════════════════════════════════════════════════════════

def _build_subnet_filter_clauses(vnet_ids: list[str]) -> str:
    clauses: list[str] = []
    for vid in vnet_ids:
        clauses.append(f"properties.ipConfigurations[0].properties.subnet.id startswith '{vid}'")
        clauses.append(f"properties.gatewayIPConfigurations[0].properties.subnet.id startswith '{vid}'")
        clauses.append(f"properties.subnet.id startswith '{vid}'")
        clauses.append(f"properties.ipConfigurations[0].subnet.id startswith '{vid}'")
        clauses.append(f"properties.ipConfiguration.properties.subnet.id startswith '{vid}'")
        clauses.append(f"properties.frontendIPConfigurations[0].properties.subnet.id startswith '{vid}'")
        clauses.append(f"properties.subnets[0].id startswith '{vid}'")
        # Bastion Developer SKU: no ipConfigurations, just virtualNetwork.id
        clauses.append(f"properties.virtualNetwork.id =~ '{vid}'")
    return "\n    or ".join(clauses)


def _build_delegated_filter_clauses(vnet_ids: list[str]) -> str:
    clauses: list[str] = []
    for vid in vnet_ids:
        clauses.append(f"properties.virtualNetworkSubnetId startswith '{vid}'")
        clauses.append(f"properties.subnetId startswith '{vid}'")
        clauses.append(f"properties.virtualNetworkConfiguration.subnetResourceId startswith '{vid}'")
        clauses.append(f"properties.subnetIds[0].id startswith '{vid}'")
        clauses.append(f"properties.vnetConfiguration.infrastructureSubnetId startswith '{vid}'")
        clauses.append(f"properties.parameters.customVirtualNetworkId.value =~ '{vid}'")
        clauses.append(f"properties.virtualNetworkConfiguration.subnetId startswith '{vid}'")
    return "\n    or ".join(clauses)


def phase4_subnet_resources(
    subscription: str,
    discovered_vnets: list[dict],
) -> dict[str, list[dict]]:
    """Query subnet-level resources batched by discovered VNet IDs."""
    log_step("Phase 4 \u2014 Subnet Resources (batched by VNet IDs)")

    vnet_ids = [v["id"] for v in discovered_vnets
                if not v.get("_accessDenied") and not v.get("_discoveryFailed")
                and "virtualnetworks" in v.get("type", "").lower()]
    if not vnet_ids:
        log_warn("No accessible VNets \u2014 skipping subnet resource discovery")
        return {"network_resources": [], "delegated_resources": [], "vms": []}

    log_info(f"Querying subnet resources for {len(vnet_ids)} VNet(s)")

    # Collect all unique subscription IDs from accessible VNets
    all_subs = list({extract_sub_id(vid) for vid in vnet_ids if extract_sub_id(vid)}) or [subscription]

    all_network_resources: list[dict] = []
    all_delegated_resources: list[dict] = []
    subnet_batch_size = 10  # Reduced from 20 to improve reliability under throttling

    for i in range(0, len(vnet_ids), subnet_batch_size):
        chunk = vnet_ids[i:i + subnet_batch_size]
        batch_num = i // subnet_batch_size + 1

        # Network resources
        filter_clauses = _build_subnet_filter_clauses(chunk)
        net_query = f"""Resources
| where type in~ (
    'microsoft.network/networkinterfaces',
    'microsoft.network/applicationgateways',
    'microsoft.network/azurefirewalls',
    'microsoft.network/privateendpoints',
    'microsoft.network/loadbalancers',
    'microsoft.network/bastionhosts',
    'microsoft.network/natgateways',
    'microsoft.network/dnsresolvers'
)
| where {filter_clauses}
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags
| order by type asc, name asc"""

        net_results = invoke_graph_query_paginated(
            f"Subnet resources batch {batch_num} ({len(chunk)} VNets)",
            net_query, all_subs,
            error_scope=f"phase4/network-batch-{batch_num}",
            phase="Phase 4 \u2014 Subnet Resources (network)",
        )

        # T221 fix: per-VNet fallback when batch fails
        if net_results is _QUERY_FAILED:
            log_warn(f"Network batch {batch_num} failed — retrying {len(chunk)} VNet(s) individually")
            for single_vid in chunk:
                single_filter = _build_subnet_filter_clauses([single_vid])
                single_net_query = f"""Resources
| where type in~ (
    'microsoft.network/networkinterfaces',
    'microsoft.network/applicationgateways',
    'microsoft.network/azurefirewalls',
    'microsoft.network/privateendpoints',
    'microsoft.network/loadbalancers',
    'microsoft.network/bastionhosts',
    'microsoft.network/natgateways',
    'microsoft.network/dnsresolvers'
)
| where {single_filter}
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags
| order by type asc, name asc"""
                single_sub = extract_sub_id(single_vid) or subscription
                single_net = invoke_graph_query_paginated(
                    f"Retry network resources ({arm_basename(single_vid)})",
                    single_net_query, single_sub,
                    error_scope=f"phase4/network-retry-{arm_basename(single_vid)}",
                    phase="Phase 4 \u2014 Subnet Resources (network retry)",
                )
                if single_net is not _QUERY_FAILED:
                    all_network_resources.extend(single_net)
        else:
            all_network_resources.extend(net_results)

        # Delegated resources
        delegated_type_list = ", ".join(f"'{t}'" for t in _DELEGATED_TYPES)
        deleg_filter = _build_delegated_filter_clauses(chunk)
        deleg_query = f"""Resources
| where type in~ ({delegated_type_list})
| where {deleg_filter}
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags, kind
| order by type asc, name asc"""

        deleg_results = invoke_graph_query_paginated(
            f"Delegated resources batch {batch_num} ({len(chunk)} VNets)",
            deleg_query, all_subs,
            error_scope=f"phase4/delegated-batch-{batch_num}",
            phase="Phase 4 \u2014 Subnet Resources (delegated)",
        )

        # T221 fix: per-VNet fallback for delegated batch failure
        if deleg_results is _QUERY_FAILED:
            log_warn(f"Delegated batch {batch_num} failed — retrying {len(chunk)} VNet(s) individually")
            for single_vid in chunk:
                single_deleg_filter = _build_delegated_filter_clauses([single_vid])
                single_deleg_query = f"""Resources
| where type in~ ({delegated_type_list})
| where {single_deleg_filter}
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags, kind
| order by type asc, name asc"""
                single_sub = extract_sub_id(single_vid) or subscription
                single_deleg = invoke_graph_query_paginated(
                    f"Retry delegated resources ({arm_basename(single_vid)})",
                    single_deleg_query, single_sub,
                    error_scope=f"phase4/delegated-retry-{arm_basename(single_vid)}",
                    phase="Phase 4 \u2014 Subnet Resources (delegated retry)",
                )
                if single_deleg is not _QUERY_FAILED:
                    all_delegated_resources.extend(single_deleg)
        else:
            all_delegated_resources.extend(deleg_results)

    # Query VMs (to resolve NICs \u2192 VMs)
    log_substep("Querying VMs for NIC resolution...")
    vm_query = """Resources
| where type =~ 'microsoft.compute/virtualMachines' and isnotnull(properties.networkProfile)
| mv-expand nic = properties.networkProfile.networkInterfaces
| project vmId=id, vmName=name, vmType=type, nicId=tolower(nic.id), location, resourceGroup, subscriptionId, tags"""
    vm_data = invoke_graph_query_paginated(
        "Query VMs", vm_query, all_subs,
        error_scope="phase4/vm-query", id_field="vmId",
        phase="Phase 4 \u2014 VM Resolution",
    )
    if vm_data is _QUERY_FAILED:
        log_warn("VM query failed \u2014 NIC \u2192 VM resolution will be incomplete")
        vm_data = []

    # Deduplicate
    def _unique(items: list[dict]) -> list[dict]:
        seen: set[str] = set()
        result: list[dict] = []
        for item in items:
            iid = item.get("id", "").lower()
            if iid not in seen:
                seen.add(iid)
                result.append(item)
        return result

    all_network_resources = _unique(all_network_resources)
    all_delegated_resources = _unique(all_delegated_resources)

    log_found(f"{len(all_network_resources)} network resource(s)")
    log_found(f"{len(all_delegated_resources)} delegated resource(s)")
    log_found(f"{len(vm_data)} VM(s) discovered for NIC resolution")

    return {
        "network_resources": all_network_resources,
        "delegated_resources": all_delegated_resources,
        "vms": vm_data,
    }


# ═════════════════════════════════════════════════════════════════════════════
# Phase 4b — az-cli Fallback for Resource Graph Gaps
# ═════════════════════════════════════════════════════════════════════════════

def _extract_by_dot_path(obj: dict, dot_path: str) -> str:
    """Walk a dot/bracket path like 'subnetIds[0].id' into an object."""
    parts = re.split(r"\.|(?=\[)", dot_path)
    current: Any = obj
    for part in parts:
        if current is None:
            return ""
        m = re.match(r"^(.*)\[(\d+)\]$", part)
        if m:
            key, idx = m.group(1), int(m.group(2))
            if key:
                current = current.get(key) if isinstance(current, dict) else None
            if isinstance(current, list) and len(current) > idx:
                current = current[idx]
            else:
                return ""
        else:
            current = current.get(part) if isinstance(current, dict) else None
    return current if isinstance(current, str) else ""


def phase4b_azcli_fallback(
    subscription: str,
    discovered_vnets: list[dict],
    subnet_resources: dict[str, list[dict]],
) -> dict[str, list[dict]]:
    """az-cli ARM fallback for resource types where Resource Graph omits VNet references.

    Iterates _RESOURCE_GRAPH_GAPS, queries each type via az-cli per resource group,
    matches results to discovered VNets by subnet ID, and appends to the appropriate
    bucket (network_resources or delegated_resources).
    """
    if not _RESOURCE_GRAPH_GAPS:
        return subnet_resources

    # Collect accessible VNet IDs and their resource groups
    vnet_ids_lower: set[str] = set()
    rg_set: set[str] = set()
    for v in discovered_vnets:
        if v.get("_accessDenied") or v.get("_discoveryFailed"):
            continue
        if "virtualnetworks" not in v.get("type", "").lower():
            continue
        vnet_ids_lower.add(v["id"].lower())
        rg_set.add(v.get("resourceGroup", ""))

    if not vnet_ids_lower:
        return subnet_resources

    # Build set of already-discovered resource IDs to avoid duplicates
    existing_ids: set[str] = set()
    for r in subnet_resources.get("network_resources", []):
        existing_ids.add(r.get("id", "").lower())
    for r in subnet_resources.get("delegated_resources", []):
        existing_ids.add(r.get("id", "").lower())

    gap_types = list(_RESOURCE_GRAPH_GAPS.keys())
    log_step(f"Phase 4b — az-cli Fallback ({len(gap_types)} tracked gap(s))")

    added_net: list[dict] = []
    added_deleg: list[dict] = []

    for rtype, gap_cfg in _RESOURCE_GRAPH_GAPS.items():
        az_args = gap_cfg["az_list_args"]
        subnet_path = gap_cfg["subnet_path"]
        kind = gap_cfg.get("kind", "delegated")

        type_count = 0
        for rg in sorted(rg_set):
            if not rg:
                continue
            cmd_args = az_args + [
                "--resource-group", rg,
                "--subscription", subscription,
            ]
            result = az_cli(cmd_args, allow_failure=True)
            if not result or not isinstance(result, list):
                continue

            for item in result:
                rid = item.get("id", "")
                if rid.lower() in existing_ids:
                    continue

                # Extract subnet ID via the configured dot-path
                subnet_id = _extract_by_dot_path(item, subnet_path)
                if not subnet_id:
                    continue

                # Check if subnet belongs to one of our discovered VNets
                sid_lower = subnet_id.lower()
                matched = any(sid_lower.startswith(vid + "/subnets/") for vid in vnet_ids_lower)
                if not matched:
                    continue

                # Build a resource dict matching the shape Phase 5 expects
                res = {
                    "id": rid,
                    "name": item.get("name", ""),
                    "type": item.get("type", rtype),
                    "location": item.get("location", ""),
                    "resourceGroup": item.get("resourceGroup", rg),
                    "subscriptionId": subscription,
                    "properties": item,
                    "tags": item.get("tags") or {},
                    "_azcli_fallback": True,
                }
                if item.get("kind"):
                    res["kind"] = item["kind"]

                existing_ids.add(rid.lower())

                if kind == "network":
                    added_net.append(res)
                else:
                    added_deleg.append(res)
                type_count += 1

        if type_count:
            log_found(f"{type_count} {arm_basename(rtype)}(s) via az-cli fallback")

    # Merge into existing results
    if added_net:
        subnet_resources["network_resources"].extend(added_net)
    if added_deleg:
        subnet_resources["delegated_resources"].extend(added_deleg)

    total = len(added_net) + len(added_deleg)
    if total:
        log_info(f"Phase 4b added {total} resource(s) from az-cli fallback")
    else:
        log_info("Phase 4b — no additional resources found via az-cli fallback")

    return subnet_resources




# ═════════════════════════════════════════════════════════════════════════════
# Phase 5 \u2014 Wire Back (client-side join)
# ═════════════════════════════════════════════════════════════════════════════

def _build_vnet_object(raw: dict) -> dict:
    """Transform a raw Resource Graph VNet/vHub dict into the topology output shape."""
    props = raw.get("properties", {})
    rtype = raw.get("type", "").lower()
    is_vhub = "virtualhubs" in rtype

    addr_space = props.get("addressSpace", {}).get("addressPrefixes", [])
    if is_vhub and not addr_space:
        ap = props.get("addressPrefix", "")
        if ap:
            addr_space = [ap]

    # Subnets
    subnets: list[dict] = []
    if not is_vhub:
        for s in props.get("subnets", []):
            s_props = s.get("properties", {})
            subnet_obj: dict[str, Any] = {
                "id": s.get("id", "") or s.get("name", ""),
                "name": s.get("name", ""),
                "addressPrefix": s_props.get("addressPrefix", ""),
                "resources": [],
            }
            nsg_ref = (s_props.get("networkSecurityGroup") or {}).get("id", "")
            if nsg_ref:
                subnet_obj["nsg"] = {"id": nsg_ref, "name": arm_basename(nsg_ref)}
            rt_ref = (s_props.get("routeTable") or {}).get("id", "")
            if rt_ref:
                subnet_obj["routeTable"] = {"id": rt_ref, "name": arm_basename(rt_ref)}
            svc_eps = s_props.get("serviceEndpoints") or []
            if svc_eps:
                subnet_obj["serviceEndpoints"] = [
                    {k: v for k, v in {"service": ep.get("service", ""), "provisioningState": ep.get("provisioningState")}.items() if v}
                    for ep in svc_eps if ep.get("service")
                ]
            pe_policy = s_props.get("privateEndpointNetworkPolicies", "")
            if pe_policy and pe_policy != "Enabled":
                subnet_obj["privateEndpointNetworkPolicies"] = pe_policy
            pls_policy = s_props.get("privateLinkServiceNetworkPolicies", "")
            if pls_policy and pls_policy != "Enabled":
                subnet_obj["privateLinkServiceNetworkPolicies"] = pls_policy
            delegations = s_props.get("delegations") or []
            if delegations:
                subnet_obj["delegations"] = [
                    {"serviceName": d.get("serviceName") or (d.get("properties") or {}).get("serviceName", "")}
                    for d in delegations
                    if d.get("serviceName") or (d.get("properties") or {}).get("serviceName")
                ]
            subnets.append(subnet_obj)

    # Peerings
    peerings: list[dict] = []
    if not is_vhub:
        for p in props.get("virtualNetworkPeerings", []):
            p_props = p.get("properties", {})
            peerings.append({
                "name": p.get("name", ""),
                "remoteVnetId": (p_props.get("remoteVirtualNetwork") or {}).get("id", ""),
                "state": p_props.get("peeringState", "Unknown"),
                "allowForwardedTraffic": p_props.get("allowForwardedTraffic", False),
                "allowGatewayTransit": p_props.get("allowGatewayTransit", False),
                "useRemoteGateways": p_props.get("useRemoteGateways", False),
            })
    else:
        # vHub connections as peerings — use stored CLI data (_hubConnections)
        for conn in raw.get("_hubConnections", []):
            remote = (conn.get("remoteVirtualNetwork") or {}).get("id", "")
            if not remote:
                continue
            routing_cfg = conn.get("routingConfiguration") or {}
            assoc_rt = arm_basename((routing_cfg.get("associatedRouteTable") or {}).get("id", ""))
            prop_labels = (routing_cfg.get("propagatedRouteTables") or {}).get("labels", [])
            static_routes = [
                {"name": r.get("name", ""), "addressPrefixes": r.get("addressPrefixes", []),
                 "nextHopIpAddress": r.get("nextHopIpAddress", "")}
                for r in ((routing_cfg.get("vnetRoutes") or {}).get("staticRoutes") or [])
            ]
            peerings.append({
                "name": conn.get("name", ""),
                "remoteVnetId": remote,
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
            })
        # Inter-hub peerings (vWAN siblings)
        for sib_id in raw.get("_siblingHubs", []):
            peerings.append({
                "name": f"interhub-{arm_basename(sib_id)}",
                "remoteVnetId": sib_id,
                "state": "Connected",
                "allowForwardedTraffic": True,
                "allowGatewayTransit": True,
                "useRemoteGateways": False,
                "_isInterHubPeering": True,
            })
        # vHub \u2014 add "Hub Resources" pseudo-subnet for UI display
        subnets = [{
            "id": "hub-resources",
            "name": "Hub Resources",
            "addressPrefix": addr_space[0] if addr_space else "",
            "resources": [],
        }]

    dns = props.get("dhcpOptions", {}).get("dnsServers", [])

    # For resolved HV_* vHub VNets, use the original HV_ VNet ID so peering
    # connections from other VNets still match in the output.
    output_id = raw.get("_hvVnetId") or raw.get("id", "")

    vnet_obj: dict[str, Any] = {
        "id": output_id,
        "name": raw.get("name", ""),
        "addressSpace": addr_space,
        "location": raw.get("location", ""),
        "resourceGroup": raw.get("resourceGroup", ""),
        "subscriptionId": raw.get("subscriptionId", ""),
        "subnets": subnets,
        "peerings": peerings,
    }
    vnet_tags = raw.get("tags") or {}
    if vnet_tags:
        vnet_obj["tags"] = vnet_tags
    if dns:
        vnet_obj["dnsServers"] = dns
    if is_vhub:
        vnet_obj["_isVirtualHub"] = True
        vnet_obj["_vhubResourceId"] = raw.get("id", "")
        hub_cfg: dict[str, Any] = {
            "sku": props.get("sku", "Basic"),
            "routingPreference": props.get("hubRoutingPreference", "ExpressRoute"),
            "routingState": props.get("routingState", "Unknown"),
            "allowBranchToBranchTraffic": props.get("allowBranchToBranchTraffic", False),
            "virtualRouterAsn": props.get("virtualRouterAsn", 0),
            "virtualRouterIps": props.get("virtualRouterIps") or [],
        }
        vnet_obj["_hubConfig"] = hub_cfg
        vwan_id = (props.get("virtualWan") or {}).get("id", "")
        if vwan_id:
            vnet_obj["_vwanId"] = vwan_id
    if raw.get("_accessDenied"):
        vnet_obj["_accessDenied"] = True
    if raw.get("_discoveryFailed"):
        vnet_obj["_discoveryFailed"] = True

    return vnet_obj


def phase5_wire_back(
    discovered_vnets: list[dict],
    backbone: dict[str, list[dict]],
    subnet_resources: dict[str, list[dict]],
    *,
    reused_baseline_vnets: list[dict] | None = None,
) -> dict:
    """Client-side join \u2014 assemble the final topology JSON.

    Args:
        reused_baseline_vnets: T025 — For incremental mode, baseline VNet objects
            that are unchanged and should be injected directly (not rebuilt).
            Their subnets/resources/peerings are already in output format.
    """
    log_step("Phase 5 \u2014 Wire Back (client-side assembly)")

    # Build VNet objects and stream to JSONL temp file to cap memory
    vnet_tmp_path = ""
    vnet_tmp = None
    try:
        vnet_tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".vnets.jsonl", delete=False, encoding="utf-8"
        )
        vnet_tmp_path = vnet_tmp.name

        vnet_map: dict[str, dict] = {}
        for raw in discovered_vnets:
            vnet_obj = _build_vnet_object(raw)
            vnet_map[vnet_obj["id"]] = vnet_obj
            vnet_tmp.write(json.dumps(vnet_obj, ensure_ascii=False) + "\n")
            vnet_tmp.flush()

        # T025: Inject reused baseline VNets directly (no rebuild)
        reused_count = 0
        if reused_baseline_vnets:
            for bvnet in reused_baseline_vnets:
                bvnet_id = bvnet.get("id", "")
                if bvnet_id not in vnet_map:
                    # Clear existing subnet resources for vHub backbone re-wiring (T026)
                    # For vHubs, clear "Hub Resources" so fresh backbone can be placed
                    if bvnet.get("_isVirtualHub"):
                        for s in bvnet.get("subnets", []):
                            if s.get("name") == "Hub Resources":
                                s["resources"] = []
                        # Fix truncated vHub names carried forward from stale baselines.
                        # Azure truncates vHub names to 20 chars in HV_* VNet names;
                        # the RG (RG_<full-name>_<guid>) always has the full name.
                        corrected_name = _parse_vhub_name_from_rg(bvnet_id)
                        if corrected_name and corrected_name != bvnet.get("name", ""):
                            log_substep(f"Correcting truncated vHub name: "
                                        f"'{bvnet.get('name', '')}' → '{corrected_name}'")
                            bvnet["name"] = corrected_name
                    vnet_map[bvnet_id] = bvnet
                    vnet_tmp.write(json.dumps(bvnet, ensure_ascii=False) + "\n")
                    vnet_tmp.flush()
                    reused_count += 1

        vnet_tmp.close()

        # Read back
        vnets: list[dict] = []
        with open(vnet_tmp_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    vnets.append(json.loads(line))
    finally:
        if vnet_tmp_path and os.path.exists(vnet_tmp_path):
            try:
                os.unlink(vnet_tmp_path)
            except OSError:
                pass

    built_count = len(vnets) - reused_count
    if reused_count:
        log_info(f"Built {built_count} VNet object(s), reused {reused_count} from baseline")
    else:
        log_info(f"Built {len(vnets)} VNet object(s)")

    # Build subnet lookup
    subnet_lookup: dict[str, list[dict]] = {}
    for vnet_obj in vnets:
        for subnet in vnet_obj.get("subnets", []):
            key = f"{vnet_obj['id'].lower()}/subnets/{subnet['name'].lower()}"
            subnet_lookup[key] = subnet["resources"]

    # Build VM lookup for NIC \u2192 VM resolution
    vm_by_nic: dict[str, dict] = {}
    for v in subnet_resources.get("vms", []):
        if v.get("nicId"):
            vm_by_nic[v["nicId"]] = v

    # Wire network resources into subnets
    placed_count = 0
    unplaced: list[str] = []

    for resource in subnet_resources.get("network_resources", []):
        rtype = resource.get("type", "")
        rtype_lower = rtype.lower()
        rsubnet_id = _resolve_subnet_id(resource, rtype_lower)
        if not rsubnet_id:
            unplaced.append(resource.get("name", "?"))
            continue

        # Find which VNet this belongs to
        matched_vnet_id = ""
        for vid in vnet_map:
            if rsubnet_id.lower().startswith(vid.lower()):
                matched_vnet_id = vid
                break
        if not matched_vnet_id:
            unplaced.append(resource.get("name", "?"))
            continue

        subnet_name = arm_basename(rsubnet_id)
        key = f"{matched_vnet_id.lower()}/subnets/{subnet_name.lower()}"
        if key not in subnet_lookup:
            unplaced.append(resource.get("name", "?"))
            continue

        slist = subnet_lookup[key]

        # Handle NICs \u2192 resolve to VM
        if "networkinterfaces" in rtype_lower:
            vm_ref = (resource.get("properties") or {}).get("virtualMachine", {}).get("id", "")
            if vm_ref:
                vm_info = vm_by_nic.get(resource.get("id", "").lower(), {})
                vm_name = vm_info.get("vmName") or arm_basename(vm_ref)
                vm_tags = vm_info.get("tags") or {}
                vm_resource: dict[str, Any] = {
                    "id": vm_ref, "name": vm_name,
                    "type": "Microsoft.Compute/virtualMachines",
                    "location": resource.get("location", ""),
                    "tags": vm_tags,
                }
                if not any(r["id"].lower() == vm_ref.lower() for r in slist):
                    slist.append(vm_resource)
                    placed_count += 1
            continue

        sub_type = _determine_subtype(resource, rtype_lower, subnet_name)
        public_ips = _collect_public_ips(resource, rtype_lower)

        res_obj: dict[str, Any] = {
            "id": resource.get("id", ""),
            "name": resource.get("name", ""),
            "type": rtype,
            "location": resource.get("location", ""),
            "tags": resource.get("tags") or {},
        }
        if sub_type:
            res_obj["subType"] = sub_type
        if public_ips:
            res_obj["publicIps"] = public_ips

        if not any(r["id"] == resource.get("id", "") for r in slist):
            slist.append(res_obj)
            placed_count += 1

    # Wire delegated resources
    for resource in subnet_resources.get("delegated_resources", []):
        rtype = resource.get("type", "")
        rtype_lower = rtype.lower()

        matched_vnet_id = ""
        rsubnet_id = ""
        for vid in vnet_map:
            sid = _resolve_delegated_subnet_id(resource, rtype_lower, vid)
            if sid and sid.lower().startswith(vid.lower()):
                matched_vnet_id = vid
                rsubnet_id = sid
                break
        if not matched_vnet_id or not rsubnet_id:
            unplaced.append(resource.get("name", "?"))
            continue

        subnet_name = arm_basename(rsubnet_id)
        key = f"{matched_vnet_id.lower()}/subnets/{subnet_name.lower()}"
        if key not in subnet_lookup:
            unplaced.append(resource.get("name", "?"))
            continue

        slist = subnet_lookup[key]
        sub_type = _determine_delegated_subtype(resource, rtype_lower)

        res_obj = {
            "id": resource.get("id", ""),
            "name": resource.get("name", ""),
            "type": rtype,
            "location": resource.get("location", ""),
            "tags": resource.get("tags") or {},
        }
        if sub_type:
            res_obj["subType"] = sub_type

        if not any(r["id"] == resource.get("id", "") for r in slist):
            slist.append(res_obj)
            placed_count += 1

    log_found(f"{placed_count} resource(s) placed into subnets")
    if unplaced:
        log_warn(f"{len(unplaced)} resource(s) could not be matched to a subnet")

    # ── Place backbone VNet gateways into their GatewaySubnets ──
    # VNet gateways (virtualNetworkGateways) discovered in Phase 3 aren't
    # included in the Phase 4 subnet resource query, so we wire them in here
    # using ipConfigurations[0].properties.subnet.id.
    vnet_gw_placed = 0
    for gw in backbone.get("gateways", []):
        gw_type = gw.get("type", "").lower()
        if "virtualnetworkgateways" not in gw_type:
            continue
        gw_subnet_id = _resolve_subnet_id(gw, gw_type)
        if not gw_subnet_id:
            continue
        matched_vnet_id = ""
        for vid in vnet_map:
            if gw_subnet_id.lower().startswith(vid.lower()):
                matched_vnet_id = vid
                break
        if not matched_vnet_id:
            continue
        subnet_name = arm_basename(gw_subnet_id)
        key = f"{matched_vnet_id.lower()}/subnets/{subnet_name.lower()}"
        slist = subnet_lookup.get(key)
        if slist is None:
            continue
        sub_type = _determine_subtype(gw, gw_type, subnet_name)
        public_ips = _collect_public_ips(gw, gw_type)
        res_obj: dict[str, Any] = {
            "id": gw.get("id", ""),
            "name": gw.get("name", ""),
            "type": gw.get("type", ""),
            "location": gw.get("location", ""),
            "tags": gw.get("tags") or {},
        }
        if sub_type:
            res_obj["subType"] = sub_type
        if public_ips:
            res_obj["publicIps"] = public_ips
        if not any(r["id"] == gw.get("id", "") for r in slist):
            slist.append(res_obj)
            vnet_gw_placed += 1

    if vnet_gw_placed:
        log_found(f"{vnet_gw_placed} VNet gateway(s) placed into GatewaySubnets")

    # ── Place backbone resources into vHub "Hub Resources" pseudo-subnets ──
    # Gateways (vpnGateways, expressRouteGateways) and firewalls discovered in
    # Phase 3 have properties.virtualHub.id pointing to the parent vHub.
    #
    # Build a lookup from real vHub ARM ID → "Hub Resources" resource list.
    vhub_res_lookup: dict[str, list[dict]] = {}
    for vnet_obj in vnets:
        if not vnet_obj.get("_isVirtualHub"):
            continue
        vhub_real_id = vnet_obj.get("_vhubResourceId", "").lower()
        if not vhub_real_id:
            continue
        for s in vnet_obj.get("subnets", []):
            if s.get("name") == "Hub Resources":
                vhub_res_lookup[vhub_real_id] = s["resources"]
                break

    hub_placed = 0
    _VHUB_GATEWAY_TYPES = {
        "microsoft.network/vpngateways",
        "microsoft.network/expressroutegateways",
        "microsoft.network/p2svpngateways",
    }
    for gw in backbone.get("gateways", []):
        gw_type = gw.get("type", "").lower()
        gw_props = gw.get("properties", {})
        vhub_ref = (gw_props.get("virtualHub") or {}).get("id", "").lower()
        if not vhub_ref or gw_type not in _VHUB_GATEWAY_TYPES:
            continue
        rlist = vhub_res_lookup.get(vhub_ref)
        if rlist is None:
            continue
        sub_type_map = {
            "microsoft.network/vpngateways": "Vpn",
            "microsoft.network/expressroutegateways": "ExpressRoute",
            "microsoft.network/p2svpngateways": "P2S",
        }
        res_obj = {
            "id": gw.get("id", ""),
            "name": gw.get("name", ""),
            "type": gw.get("type", ""),
            "subType": sub_type_map.get(gw_type, ""),
            "location": gw.get("location", ""),
            "tags": gw.get("tags") or {},
        }
        if not any(r["id"] == gw.get("id", "") for r in rlist):
            rlist.append(res_obj)
            hub_placed += 1

    for fw in backbone.get("firewalls", []):
        fw_props = fw.get("properties", {})
        vhub_ref = (fw_props.get("virtualHub") or {}).get("id", "").lower()
        if not vhub_ref:
            continue
        rlist = vhub_res_lookup.get(vhub_ref)
        if rlist is None:
            continue
        res_obj = {
            "id": fw.get("id", ""),
            "name": fw.get("name", ""),
            "type": fw.get("type", ""),
            "subType": "vHub",
            "location": fw.get("location", ""),
            "tags": fw.get("tags") or {},
        }
        if not any(r["id"] == fw.get("id", "") for r in rlist):
            rlist.append(res_obj)
            hub_placed += 1

    if hub_placed:
        log_found(f"{hub_placed} backbone resource(s) placed into vHub pseudo-subnets")

    # Build connections from peerings
    connections: list[dict] = []
    conn_set: set[tuple[str, str]] = set()
    for vnet_obj in vnets:
        for p in vnet_obj.get("peerings", []):
            remote = p.get("remoteVnetId", "")
            if not remote:
                continue
            key = tuple(sorted((vnet_obj["id"].lower(), remote.lower())))
            if key in conn_set:
                continue
            conn_set.add(key)
            connections.append({
                "sourceId": vnet_obj["id"],
                "targetId": remote,
                "relationship": "VNet peering",
                "direction": "undirected",
                "metadata": {
                    "peeringName": p.get("name", ""),
                    "state": p.get("state", "Unknown"),
                },
            })

    # Build ER circuit output objects with full detail
    er_circuits: list[dict] = []
    for er in backbone.get("er_circuits", []):
        er_props = er.get("properties", {})
        sp = er_props.get("serviceProviderProperties") or {}
        sku = er_props.get("sku") or er.get("sku") or {}
        er_obj: dict[str, Any] = {
            "id": er.get("id", ""),
            "name": er.get("name", ""),
            "location": er.get("location", ""),
            "serviceProviderName": sp.get("serviceProviderName", "Unknown"),
            "peeringLocation": sp.get("peeringLocation", "Unknown"),
            "bandwidthInMbps": sp.get("bandwidthInMbps", 0),
            "skuTier": sku.get("tier", "Standard"),
            "skuFamily": sku.get("family", "MeteredData"),
            "circuitProvisioningState": er_props.get("circuitProvisioningState", "Unknown"),
            "serviceProviderProvisioningState": er_props.get("serviceProviderProvisioningState", "Unknown"),
        }
        peerings = _extract_peerings_from_circuit(er_props)
        if peerings:
            er_obj["peerings"] = peerings
        er_circuits.append(er_obj)

    # Build LNG output objects
    lngs: list[dict] = []
    for lng in backbone.get("lngs", []):
        lng_props = lng.get("properties", {})
        lngs.append({
            "id": lng.get("id", ""),
            "name": lng.get("name", ""),
            "location": lng.get("location", ""),
            "gatewayIpAddress": lng_props.get("gatewayIpAddress", "Unknown"),
            "localAddressSpace": (lng_props.get("localNetworkAddressSpace") or {}).get("addressPrefixes", []),
        })

    # Build gateway connections
    gw_connections: list[dict] = []
    for gc in backbone.get("connections", []):
        gc_props = gc.get("properties", {})
        gw_connections.append({
            "id": gc.get("id", ""),
            "name": gc.get("name", ""),
            "connectionType": gc_props.get("connectionType", "Unknown"),
            "gatewayId": (gc_props.get("virtualNetworkGateway1") or {}).get("id", ""),
            "circuitId": (gc_props.get("peer") or {}).get("id", ""),
            "localNetworkGatewayId": (gc_props.get("localNetworkGateway2") or {}).get("id", ""),
            "connectionStatus": gc_props.get("connectionStatus", "Unknown"),
            "routingWeight": gc_props.get("routingWeight", 0),
        })

    # ER circuit \u2194 gateway linkage validation
    if er_circuits and gw_connections:
        er_ids_lower = {c["id"].lower() for c in er_circuits if c.get("id")}
        er_conn_count = sum(1 for gc in gw_connections if gc.get("circuitId", "").lower() in er_ids_lower)
        if er_conn_count:
            log_found(f"{er_conn_count} ER circuit(s) linked to VNet gateway(s) via connections")
        else:
            log_warn(
                f"Found {len(er_circuits)} ER circuit(s) but no gateway connections "
                "reference them \u2014 ER \u2194 gateway linkage may be incomplete"
            )

    # OnPremises synthesis
    on_premises = _synthesize_on_premises(er_circuits, lngs)
    if on_premises:
        log_found(f"{len(on_premises)} on-premises site(s) synthesised")

    return {
        "vnets": vnets,
        "connections": connections,
        "expressRouteCircuits": er_circuits,
        "localNetworkGateways": lngs,
        "gatewayConnections": gw_connections,
        "onPremises": on_premises,
    }


# ═════════════════════════════════════════════════════════════════════════════
# Prerequisites & Interactive Prompts
# ═════════════════════════════════════════════════════════════════════════════

def check_prerequisites() -> tuple[dict, str, str]:
    """Verify Azure CLI and login. Returns (account_info, sub_id, sub_name)."""
    log_step("Checking Prerequisites")

    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    log_info(f"Python {py_ver}  \u2713")

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
    log_info(f"Azure CLI {az_ver}  \u2713")

    _MIN_AZ_VERSION = "2.60.0"
    try:
        cur = tuple(int(x) for x in az_ver.split(".")[:3])
        req = tuple(int(x) for x in _MIN_AZ_VERSION.split(".")[:3])
        if cur < req:
            log_warn(f"Azure CLI {az_ver} is older than recommended minimum {_MIN_AZ_VERSION}.")
            log_detail("Older versions may have bugs with resource queries or interactive prompts.")
            log_detail("Update via: az upgrade")
            if _is_interactive_session():
                cont = input(f"Continue anyway? [y/N/q=exit]: ").strip() or "N"
                if cont.lower() == "q":
                    sys.exit(0)
                if cont.upper() != "Y":
                    log_info("Exiting. Please update Azure CLI and try again.")
                    sys.exit(1)
    except (ValueError, TypeError):
        pass

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
            if _is_interactive_session():
                choice = input("Allow this script to disable interactive prompts? [Y/n/q=exit]: ").strip() or "Y"
                if choice.lower() == "q":
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
            else:
                log_warn("Auto-configuring Azure CLI: disabling interactive prompts…")
                subprocess.run(
                    [_AZ_EXE, "config", "set", "core.collect_telemetry=false",
                     "core.survey_message=false", "core.only_show_errors=true"],
                    capture_output=True, check=False, stdin=subprocess.DEVNULL,
                )

    account = az_cli(["account", "show"])
    if account is None:
        log_warn("You are not logged into Azure.")
        if _is_interactive_session():
            login_choice = input("Log in now? [Y/n/q=exit]: ").strip() or "Y"
            if login_choice.lower() == "q":
                sys.exit(0)
            if login_choice.upper() == "Y":
                tenant_id = input("Tenant ID (leave blank for default, q=exit): ").strip()
                if tenant_id.lower() == "q":
                    sys.exit(0)
                if tenant_id:
                    log_info(f"Logging in to tenant {tenant_id}...")
                    subprocess.run(
                        [_AZ_EXE, "login", "--tenant", tenant_id, "--output", "none"],
                        check=False,
                    )
                else:
                    log_info("Logging in to default tenant\u2026")
                    subprocess.run([_AZ_EXE, "login", "--output", "none"], check=False)
                account = az_cli(["account", "show"])
                if account is None:
                    log_error("Login failed. Run: az login")
                    sys.exit(2)
            else:
                log_error("Azure login is required.")
                sys.exit(2)
        else:
            log_error("Not logged into Azure. Run: az login")
            sys.exit(2)

    sub_id = account.get("id", "")
    sub_name = account.get("name", "")
    user = account.get("user", {}).get("name", "")
    tenant = account.get("tenantId", "")
    log_info(f"Logged in as: {user}")
    log_info(f"Tenant:       {tenant}")
    log_info(f"Subscription: {sub_name} ({sub_id})")

    ext_check = az_cli(["extension", "show", "--name", "resource-graph"], allow_failure=True)
    if ext_check is None:
        log_warn("The 'resource-graph' extension is required.")
        if _is_interactive_session():
            choice = input("Install it now? [Y/n]: ").strip() or "Y"
            if choice.upper() == "Y":
                subprocess.run(
                    [_AZ_EXE, "extension", "add", "--name", "resource-graph", "--yes", "--output", "none"],
                    capture_output=True, check=False, stdin=subprocess.DEVNULL,
                )
                log_info("Extension 'resource-graph' installed  \u2713")
            else:
                log_error("Install manually: az extension add --name resource-graph")
                sys.exit(1)
        else:
            log_error("Install: az extension add --name resource-graph")
            sys.exit(1)

    log_info("Prerequisites satisfied  \u2713")
    return account, sub_id, sub_name


def prompt_selection(prompt: str, max_val: int) -> int:
    while True:
        choice = input(prompt).strip()
        if choice.lower() == "q":
            sys.exit(0)
        if choice.isdigit() and 1 <= int(choice) <= max_val:
            return int(choice)
        print(f"  Enter a number between 1 and {max_val} (or 'q' to exit).", file=sys.stderr)


def select_tenant(current_tenant: str) -> bool:
    """Offer tenant switching. Returns True if tenant was switched."""
    log_step("Switch Tenant")
    spinner = Spinner("Fetching available tenants\u2026")
    spinner.start()
    subs_for_tenants = invoke_with_retry(
        "List subscriptions for tenants",
        ["account", "list", "--query", "[].{tenantId:tenantId, tenantDisplayName:tenantDisplayName}"],
        allow_failure=True, max_retries=1, timeout=30,
    ) or []
    spinner.stop()
    # Deduplicate by tenantId
    tenant_map: dict[str, str] = {}
    for s in subs_for_tenants:
        tid = s.get("tenantId", "")
        tname = s.get("tenantDisplayName") or ""
        if tid and (tid not in tenant_map or (not tenant_map[tid] and tname)):
            tenant_map[tid] = tname
    tenants = [{"tenantId": k, "displayName": v} for k, v in tenant_map.items()]

    new_tenant = ""
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
            sys.exit(0)
        elif t_choice.isdigit() and 1 <= int(t_choice) <= len(tenants):
            new_tenant = tenants[int(t_choice) - 1]["tenantId"]
        elif t_choice == "0":
            new_tenant = input("Enter Tenant ID (q=exit): ").strip()
            if new_tenant.lower() == "q":
                sys.exit(0)
        else:
            log_warn("Invalid selection \u2014 continuing with current tenant.")
            return False
    else:
        new_tenant = input("Enter the Tenant ID to switch to (q=exit): ").strip()
        if new_tenant.lower() == "q":
            sys.exit(0)

    if not new_tenant:
        log_warn("No tenant ID provided \u2014 continuing with current tenant.")
        return False

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
    return True


def select_subscription() -> tuple[str, str]:
    log_step("Select Azure Subscription")
    spinner = Spinner("Fetching subscriptions\u2026")
    spinner.start()
    subs = invoke_with_retry("List subscriptions", ["account", "list", "--query", "[?state=='Enabled']"]) or []
    spinner.stop()
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
    spinner = Spinner("Fetching resource groups\u2026")
    spinner.start()
    rgs = invoke_with_retry("List resource groups", ["group", "list", "--subscription", sub_id]) or []
    spinner.stop()
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
    log_info("Discovery crawls outward from the selected network, following peerings.")

    spinner = Spinner("Fetching networks\u2026")
    spinner.start()
    vnets = invoke_with_retry("List VNets", ["network", "vnet", "list", "--subscription", sub_id, "--resource-group", rg_name]) or []
    vhubs = invoke_with_retry("List vHubs", ["network", "vhub", "list", "--subscription", sub_id, "--resource-group", rg_name], allow_failure=True, max_retries=1) or []
    spinner.stop()

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
            print(f"    {num}) {h['name']}  [{h.get('addressPrefix', '')}] ({h.get('location', '')})", file=sys.stderr)

    print(f"  0) All VNets and Virtual Hubs in {rg_name}", file=sys.stderr)
    print("  q) Exit", file=sys.stderr)

    choice = input(f"Select [0-{total}, q=exit] (0=all): ").strip()
    if choice.lower() == "q":
        sys.exit(0)
    if not choice or choice == "0":
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
    if _is_interactive_session():
        title = input("Diagram title (q=exit): ").strip()
        if title.lower() == "q":
            sys.exit(0)
        if not title:
            title = f"Azure Network Topology \u2014 {datetime.now(timezone.utc).strftime('%Y-%m-%d')}"
        return title
    return "Graph-First Discovery"


# ═════════════════════════════════════════════════════════════════════════════
# Banner
# ═════════════════════════════════════════════════════════════════════════════

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
    _line("  Azure Network Topology Generator (Graph)", f"{_C_BOLD}{_C_WHITE}")
    _line("  AED · EngOps · ESME Networking", _C_DIM)
    _line(f"  v{SCRIPT_VERSION} (b{SCRIPT_BUILD})  ·  Schema v{SCHEMA_VERSION}  ·  python", _C_DIM)
    _line("  Author: johnfern@  ·  Team: esme-networking@", _C_DIM)
    _line("")
    print(f"{_C_BOLD}{_C_CYAN}  ╚{bar}╝{_C_RESET}", file=sys.stderr)


# ═════════════════════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Graph-First Scoped Crawl Discovery for AED/ESME",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--title", default="", help="Diagram title")
    parser.add_argument("--vnet-id", default="", help="Starting VNet ARM resource ID")
    parser.add_argument("--vhub-id", default="", help="Starting Virtual Hub ARM resource ID")
    parser.add_argument("--subscription", default="", help="Subscription ID or name")
    parser.add_argument("--resource-group", default="", help="Resource group (All in RG mode)")
    parser.add_argument("--output", default="", help="Output file path")
    parser.add_argument("--baseline", default="", help="Previous topology JSON for edit preservation")
    parser.add_argument("--incremental", action="store_true", default=False,
                        help="(Deprecated) Incremental mode is now auto-detected from --baseline. Kept for backward compat.")
    parser.add_argument("--full", action="store_true", default=False,
                        help="Force full discovery even when a valid baseline exists")
    args = parser.parse_args()

    show_banner()
    start_time = time.monotonic()

    # \u2500\u2500 Prerequisites \u2500\u2500
    account, default_sub, default_sub_name = check_prerequisites()
    sub_id = args.subscription or default_sub
    sub_name = default_sub_name

    if args.subscription and not validate_subscription_guid(args.subscription):
        resolved = az_cli(["account", "show", "--subscription", args.subscription])
        if resolved:
            sub_id = resolved.get("id", sub_id)
            sub_name = resolved.get("name", sub_name)
        else:
            log_warn(f"Could not resolve subscription '{args.subscription}' \u2014 using default")
    elif args.subscription:
        resolved = az_cli(["account", "show", "--subscription", args.subscription])
        if resolved:
            sub_name = resolved.get("name", sub_name)

    # \u2500\u2500 Interactive mode (no CLI args for scope) \u2500\u2500
    scope_vnet_id = args.vnet_id
    scope_vhub_id = args.vhub_id
    scope_rg = args.resource_group
    scope_resource_id = scope_vnet_id or scope_vhub_id or ""
    scope_resource_type = (
        "Microsoft.Network/virtualNetworks" if scope_vnet_id
        else "Microsoft.Network/virtualHubs" if scope_vhub_id
        else ""
    )

    if not scope_vnet_id and not scope_vhub_id and not scope_rg and _is_interactive_session():
        switch = input("Continue with this tenant and subscription? [Y/n/q=exit]: ").strip() or "Y"
        if switch.lower() == "q":
            sys.exit(0)
        if switch.upper() != "Y":
            current_tenant = account.get("tenantId", "")
            tenant_switched = select_tenant(current_tenant)
            if tenant_switched:
                # az login --tenant already prompted for subscription selection;
                # just read the resulting account context — no second prompt needed
                account = az_cli(["account", "show"]) or account
                sub_id = account.get("id", sub_id)
                sub_name = account.get("name", sub_name)
                log_info(f"Using subscription: {sub_name} ({sub_id})")
            else:
                # Same tenant — offer subscription switch only
                sub_id, sub_name = select_subscription()

        scope_rg = select_resource_group(sub_id)
        starting_id, starting_type = select_vnet(sub_id, scope_rg)
        if starting_type == "Microsoft.Network/virtualNetworks":
            scope_vnet_id = starting_id
            scope_resource_id = starting_id
            scope_resource_type = starting_type
        elif starting_type == "Microsoft.Network/virtualHubs":
            scope_vhub_id = starting_id
            scope_resource_id = starting_id
            scope_resource_type = starting_type
        elif starting_type == "All":
            scope_resource_id = f"/subscriptions/{sub_id}/resourceGroups/{scope_rg}"
            scope_resource_type = "ResourceGroup"

    # \u2500\u2500 Sleep prevention \u2500\u2500
    prevent_sleep()

    # \u2500\u2500 Validate scope \u2500\u2500
    if scope_vnet_id and not validate_arm_resource_id(scope_vnet_id):
        log_error(f"Invalid ARM resource ID: {scope_vnet_id}")
        sys.exit(1)
    if scope_vhub_id and not validate_arm_resource_id(scope_vhub_id):
        log_error(f"Invalid ARM resource ID: {scope_vhub_id}")
        sys.exit(1)

    # \u2500\u2500 Output paths \u2500\u2500
    title = prompt_title(args.title)
    slug = title.replace(" ", "-").lower()[:40] if title else "graph-discovery"
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = os.path.dirname(os.path.abspath(__file__))

    output_path = args.output or os.path.join(output_dir, f"topology.{slug}.{ts}.json")
    log_path = output_path.rsplit(".", 1)[0] + ".log"
    query_path = os.path.join(output_dir, "graph-queries.kql")

    _log_file_open(log_path)
    _query_log_open(query_path)
    atexit.register(_log_file_close)
    atexit.register(_query_log_close)

    log_info(f"Output: {output_path}")
    log_info(f"Log: {log_path}")

    # \u2500\u2500 Check Graph availability \u2500\u2500
    if not check_graph_available(sub_id):
        log_error("Cannot proceed without Resource Graph. Exiting.")
        sys.exit(1)

    # \u2500\u2500 Incremental mode validation \u2500\u2500
    incremental_mode = False
    baseline_data: dict[str, Any] | None = None

    if args.baseline and os.path.isfile(args.baseline):
        if args.full:
            log_info("--full specified \u2014 forcing full discovery (baseline used for edit preservation only)")
        else:
            try:
                with open(args.baseline, "r", encoding="utf-8") as f:
                    baseline_data = json.load(f)
                is_valid, reason = validate_baseline_for_incremental(baseline_data)
                if is_valid:
                    incremental_mode = True
                    log_info(f"Incremental mode: baseline validated ({len(baseline_data.get('vnets', []))} VNets)")
                else:
                    log_warn(f"Incremental mode disabled: {reason} \u2014 falling back to full discovery")
                    baseline_data = None
            except (json.JSONDecodeError, OSError) as e:
                log_warn(f"Cannot load baseline for incremental: {e} \u2014 falling back to full discovery")
                baseline_data = None

    # \u2550\u2550\u2550 Execute 5-phase scoped crawl \u2550\u2550\u2550

    if incremental_mode and baseline_data:
        # Incremental path: seed from baseline, verify, detect new peers
        baseline_seeds = phase1_incremental_seed(
            baseline_data,
            vnet_id=scope_vnet_id, vhub_id=scope_vhub_id,
            resource_group=scope_rg, subscription=sub_id,
        )
        if not baseline_seeds:
            log_warn("Baseline has no VNets \u2014 falling back to full discovery")
            incremental_mode = False

    if incremental_mode and baseline_data:
        spoke_to_vhub = _build_spoke_to_vhub_lookup(sub_id)
        verified, deleted_ids, new_vnets = phase2_incremental_verify(sub_id, baseline_seeds, spoke_to_vhub=spoke_to_vhub)
        all_vnets = verified + new_vnets
        if not all_vnets:
            log_error("No VNets remain after incremental verify. Exiting.")
            sys.exit(1)
        log_info(f"Incremental: {len(verified)} verified + {len(new_vnets)} new, {len(deleted_ids)} deleted")
    else:
        # Full discovery path
        seeds = phase1_seed_resolution(sub_id, vnet_id=scope_vnet_id, vhub_id=scope_vhub_id, resource_group=scope_rg)
        if not seeds:
            log_error("No VNets/vHubs found for the given scope. Exiting.")
            sys.exit(1)
        spoke_to_vhub = _build_spoke_to_vhub_lookup(sub_id)
        all_vnets = phase2_bfs_expansion(sub_id, seeds, spoke_to_vhub=spoke_to_vhub)

    if incremental_mode:
        log_info("Backbone: always queried fresh (incremental mode)")
    backbone = phase3_backbone_resources(sub_id, all_vnets)

    if incremental_mode and baseline_data:
        subnet_resources, changed_vnet_ids = phase4_incremental(sub_id, all_vnets, baseline_data)
        # Phase 4b fallback only for changed/new VNets
        if changed_vnet_ids:
            changed_vnets = [v for v in all_vnets if v["id"].lower() in {c.lower() for c in changed_vnet_ids}]
            subnet_resources_fallback = phase4b_azcli_fallback(sub_id, changed_vnets, subnet_resources)
            subnet_resources = subnet_resources_fallback

        # T025: Split VNets into refreshed (rebuild) and reused (passthrough)
        changed_ids_lower = {c.lower() for c in changed_vnet_ids}
        new_ids_lower = {v["id"].lower() for v in new_vnets} if new_vnets else set()
        refresh_ids_lower = changed_ids_lower | new_ids_lower

        # T025: Identify vHubs — they can't be rebuilt via _build_vnet_object()
        # (HV_* IDs are 403, vHub ARM IDs aren't type=virtualnetworks).
        # Changed vHubs get passthrough from baseline with Hub Resources cleared
        # so fresh backbone (T026) is placed.
        # Note: baseline type field may be empty, so check _isVirtualHub flag.
        vhub_ids_lower: set[str] = set()
        for v in all_vnets:
            if v.get("_isVirtualHub"):
                vhub_ids_lower.add(v["id"].lower())

        # T025: Fetch full Resource Graph objects for changed/new regular VNets.
        # Seeds from phase1_incremental_seed lack properties.subnets[], addressSpace,
        # virtualNetworkPeerings[] etc. that _build_vnet_object() requires.
        regular_refresh_ids = [v["id"] for v in all_vnets
                               if v["id"].lower() in refresh_ids_lower
                               and v["id"].lower() not in vhub_ids_lower]
        refreshed_vnets: list[dict] = []

        if regular_refresh_ids:
            log_info(f"Fetching full VNet data for {len(regular_refresh_ids)} changed/new VNet(s)")
            fetched_map: dict[str, dict] = {}
            for i in range(0, len(regular_refresh_ids), GRAPH_BATCH_SIZE):
                chunk = regular_refresh_ids[i:i + GRAPH_BATCH_SIZE]
                id_list = ", ".join(f"'{vid}'" for vid in chunk)
                query = f"""Resources
| where type =~ 'microsoft.network/virtualnetworks' and id in~ ({id_list})
| project id, name, type, location, resourceGroup, subscriptionId, properties, tags"""
                target_subs = list({extract_sub_id(t) for t in chunk if extract_sub_id(t)}) or [sub_id]
                results = invoke_graph_query_paginated(
                    f"Refresh VNets batch {i // GRAPH_BATCH_SIZE + 1} ({len(chunk)} IDs)",
                    query, target_subs,
                    error_scope=f"incremental/refresh-fetch/batch-{i // GRAPH_BATCH_SIZE + 1}",
                    phase="Incremental \u2014 fetch changed VNets",
                )
                if results is not _QUERY_FAILED:
                    for r in results:
                        fetched_map[r["id"].lower()] = r
            # Build refreshed list: use fetched Graph data when available, fall back to seed
            for vid in regular_refresh_ids:
                full = fetched_map.get(vid.lower())
                if full:
                    refreshed_vnets.append(full)
                else:
                    seed = next((v for v in all_vnets if v["id"].lower() == vid.lower()), None)
                    if seed:
                        log_warn(f"Could not fetch full data for {arm_basename(vid)}, using seed")
                        refreshed_vnets.append(seed)

        # New vHubs (from new_vnets) have full properties from phase2 fetch
        new_vhub_seeds = [v for v in all_vnets if v["id"].lower() in new_ids_lower
                          and v["id"].lower() in vhub_ids_lower]
        refreshed_vnets.extend(new_vhub_seeds)

        # Reused VNets: get full objects from baseline (not seeds — seeds lack subnets/peerings)
        # Changed vHubs are also passed through from baseline (can't rebuild them)
        baseline_vnet_by_id = {v["id"].lower(): v for v in baseline_data.get("vnets", [])}
        reused_baseline_vnets = []
        for v in all_vnets:
            vid_lower = v["id"].lower()
            if vid_lower not in baseline_vnet_by_id:
                continue
            # Unchanged VNets → passthrough
            if vid_lower not in refresh_ids_lower:
                reused_baseline_vnets.append(baseline_vnet_by_id[vid_lower])
            # Changed vHubs → also passthrough (can't rebuild via _build_vnet_object)
            elif vid_lower in vhub_ids_lower:
                reused_baseline_vnets.append(baseline_vnet_by_id[vid_lower])

        # T014: Build incremental stats
        _incremental_stats = {
            "baseline_total": len(baseline_data.get("vnets", [])),
            "reused": len(reused_baseline_vnets),
            "refreshed": len(changed_vnet_ids),
            "new": len(new_vnets),
            "deleted": len(deleted_ids),
        }
    else:
        _incremental_stats = None
        refreshed_vnets = None
        reused_baseline_vnets = None
        subnet_resources = phase4_subnet_resources(sub_id, all_vnets)
        subnet_resources = phase4b_azcli_fallback(sub_id, all_vnets, subnet_resources)

    # T025: Pass refreshed VNets for rebuild, reused VNets as passthrough
    if refreshed_vnets is not None:
        topology_data = phase5_wire_back(
            refreshed_vnets, backbone, subnet_resources,
            reused_baseline_vnets=reused_baseline_vnets,
        )
    else:
        topology_data = phase5_wire_back(all_vnets, backbone, subnet_resources)

    # \u2550\u2550\u2550 Assemble output JSON \u2550\u2550\u2550

    log_step("Assembling Output")

    # Resolve scope resource ID from seeds if not set yet ("All in subscription" mode)
    if not scope_resource_id and all_vnets:
        scope_resource_id = all_vnets[0].get("id", f"/subscriptions/{sub_id}")
        scope_resource_type = all_vnets[0].get("type", "Microsoft.Network/virtualNetworks")

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    output: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "topologyVersion": 1,
        "generatedAt": generated_at,
        "title": title,
        "generator": GENERATOR_NAME,
        "scope": {
            "subscriptionId": sub_id,
            "subscriptionName": sub_name,
            "startingResourceId": scope_resource_id,
            "startingResourceType": scope_resource_type,
        },
        "vnets": topology_data["vnets"],
        "connections": topology_data["connections"],
        "expressRouteCircuits": topology_data["expressRouteCircuits"],
        "localNetworkGateways": topology_data["localNetworkGateways"],
        "gatewayConnections": topology_data["gatewayConnections"],
        "onPremises": topology_data["onPremises"],
        "_discoveryErrors": _discovery_errors if _discovery_errors else [],
        "_discoveryMethod": "graph-first-scoped-crawl",
        "_discoveryMode": "incremental" if incremental_mode else "full",
        "_scriptVersion": SCRIPT_VERSION,
        "_scriptBuild": SCRIPT_BUILD,
    }

    # Baseline merge (full merge engine)
    # When incremental mode already loaded the baseline, reuse it
    if args.baseline and os.path.isfile(args.baseline):
        try:
            if incremental_mode and baseline_data:
                baseline = baseline_data
            else:
                with open(args.baseline, "r", encoding="utf-8") as f:
                    baseline = json.load(f)
            summary = merge_user_edits(baseline, output)
            log_info(f"Baseline merge: layouts={summary['applied_layouts']}, "
                     f"edits={summary['merged_edits']}, tags={summary['merged_tags']}, "
                     f"preserved_onprem={summary['preserved_onprem']}, "
                     f"orphaned={summary['orphaned']}, new={summary['new_resources']}")
        except (json.JSONDecodeError, OSError) as e:
            log_warn(f"Could not load baseline: {e}")

    # Write output
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
        f.write("\n")

    # \u2500\u2500 Summary \u2500\u2500
    elapsed = time.monotonic() - start_time
    mins, secs = divmod(int(elapsed), 60)
    duration_str = f"{mins}m {secs}s" if mins else f"{secs}s"

    log_step("Discovery Complete")
    n_onprem = len(topology_data["onPremises"])
    mode_banner = " [INCREMENTAL]" if incremental_mode else ""
    incremental_rows = ""
    if _incremental_stats:
        incremental_rows = f"""  \u2502  Baseline VNets:  {_incremental_stats['baseline_total']:<6}                            \u2502
  \u2502  Reused VNets:    {_incremental_stats['reused']:<6}                            \u2502
  \u2502  Refreshed VNets: {_incremental_stats['refreshed']:<6}                            \u2502
  \u2502  New VNets:       {_incremental_stats['new']:<6}                            \u2502
  \u2502  Deleted VNets:   {_incremental_stats['deleted']:<6}                            \u2502
  \u251c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2524
"""
    print(f"""
{_C_GREEN}{_C_BOLD}  \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510
  \u2502  Graph-First Scoped Crawl \u2014 Results{mode_banner:<18}\u2502
  \u251c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2524
  \u2502  VNets/vHubs:     {len(topology_data['vnets']):<6}                            \u2502
  \u2502  Connections:     {len(topology_data['connections']):<6}                            \u2502
  \u2502  ER Circuits:     {len(topology_data['expressRouteCircuits']):<6}                            \u2502
  \u2502  LNGs:            {len(topology_data['localNetworkGateways']):<6}                            \u2502
  \u2502  GW Connections:  {len(topology_data['gatewayConnections']):<6}                            \u2502
  \u2502  OnPremises:      {n_onprem:<6}                            \u2502
  \u2502  Errors:          {len(_discovery_errors):<6}                            \u2502
  \u2502  Duration:        {duration_str:<10}                        \u2502
  \u251c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2524
{incremental_rows}  \u2502  Output: {os.path.basename(output_path):<42}\u2502
  \u2502  Log:    {os.path.basename(log_path):<42}\u2502
  \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518{_C_RESET}
""", file=sys.stderr)

    _log_to_file(f"Duration: {duration_str}")
    _log_to_file(f"Output: {output_path}")


if __name__ == "__main__":
    main()
