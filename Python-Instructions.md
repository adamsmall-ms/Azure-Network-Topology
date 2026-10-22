# Network Topology Mapper - Python

Discover your Azure network with the standard Python script, then load the generated JSON into the [Azure Network Topology Viewer](https://app-esme-net-diagrams-wus3.azurewebsites.net/).

## Prerequisites

- Python 3.8 or later.
- Azure CLI 2.60 or later.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

No `jq` installation is required.

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
2. Save `get-network-topology.py` and open a terminal in that folder.

## 2. Check prerequisites and sign in

```text
python3 --version
az version
az login
az account list --output table
```

On Windows, substitute `python` for `python3` if that is your installed interpreter command. To sign in to a specific tenant, use:

```text
az login --tenant "<tenant-id>"
```

Replace all angle-bracket placeholders in these instructions with your own values.

## 3. Run discovery

For interactive discovery:

```text
python3 get-network-topology.py
```

To provide a subscription, diagram title, and output file:

```text
python3 get-network-topology.py --subscription "<subscription-id-or-name>" --title "Production Network" --output "topology.json"
```

On Windows, the script may offer to configure Azure CLI telemetry settings to prevent interactive prompts from blocking execution. Standard discovery uses sequential Azure CLI calls and may take several minutes in large environments.

## Optional settings

| Parameter | Purpose |
|---|---|
| `--subscription` | Subscription ID or name |
| `--title` | Diagram title |
| `--resource-group` | Resource group name |
| `--vnet-id` | Starting VNet's full ARM resource ID |
| `--vhub-id` | Starting Virtual Hub's full ARM resource ID |
| `--output` | Output JSON file path |
| `--baseline` | Previous topology JSON used to increment `topologyVersion` |

Start from a specific VNet:

```text
python3 get-network-topology.py --vnet-id "<full-vnet-resource-id>" --output "topology.json"
```

Create a versioned snapshot from an earlier run:

```text
python3 get-network-topology.py --subscription "<subscription-id-or-name>" --baseline "topology.previous.json" --output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

## 4. Open the topology

1. Wait for discovery to complete and note the generated JSON's location.
2. Send the JSON file to the Azure ACE you are working with.

## Troubleshooting and handling

- If Python or `az` is not found, install the prerequisite or correct your terminal's PATH.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If discovery reports errors, review them before treating the diagram as a complete inventory.

These instructions reflect the viewer's Python tab reviewed on October 21, 2026. Download the script from the application to obtain its current version.
