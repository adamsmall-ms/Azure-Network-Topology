# Network Topology Mapper - Graph (Python)

Discover your Azure network using Azure Resource Graph, then load the generated JSON into the [Azure Network Topology Viewer](https://app-esme-net-diagrams-wus3.azurewebsites.net/).

**Status: Under Test.** This variant is under active testing. It uses Azure Resource Graph for faster discovery but may not cover every edge case handled by the standard Python, PowerShell, and Bash scripts.

## Prerequisites

- Python 3.8 or later.
- Azure CLI 2.60 or later.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

The script supports Windows, macOS, Linux, and Azure Cloud Shell.

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
4. Save `get-network-topology-graph.py` and open a terminal in that folder.
5. If using Cloud Shell, upload the script into that environment first.

## 2. Check prerequisites and sign in

```text
python3 --version
az version
az login
az account list --output table
```

On Windows, substitute `python` for `python3` if that is your installed interpreter command. Cloud Shell normally provides an authenticated Azure session; check that it is using the intended account and tenant.

To sign in to a specific tenant when needed:

```text
az login --tenant "<tenant-id>"
```

Replace all angle-bracket placeholders in these instructions with your own values.

## 3. Run discovery

For interactive discovery:

```text
python3 get-network-topology-graph.py
```

To provide a subscription, diagram title, and output file:

```text
python3 get-network-topology-graph.py --subscription "<subscription-id-or-name>" --title "Production Network" --output "topology.json"
```

The Graph variant uses a five-phase scoped crawl instead of enumerating resources entirely through sequential Azure CLI calls. Actual runtime depends on environment size and service responses.

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
python3 get-network-topology-graph.py --vnet-id "<full-vnet-resource-id>" --output "topology.json"
```

Create a versioned snapshot from an earlier run:

```text
python3 get-network-topology-graph.py --subscription "<subscription-id-or-name>" --baseline "topology.previous.json" --output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

## 4. Open the topology

1. Wait for discovery to complete and note the generated JSON's location.
2. If discovery ran in Cloud Shell, download the generated JSON to your computer.
3. Send the JSON file to the Azure ACE you are working with.

## Troubleshooting and handling

- If Python or `az` is not found, install the prerequisite or correct your terminal's PATH.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If the script reports a missing Azure CLI extension or another prerequisite, follow its explicit guidance using your organization's approved installation process.
- If results appear incomplete, run a standard discovery script against the same intended scope and compare the results. Report Graph-script issues through the application's available feedback route.
- Review discovery errors before treating the diagram as a complete inventory.
- Handle the JSON and exported diagrams as sensitive infrastructure information. Share only through approved channels.

These instructions reflect the viewer's Graph tab reviewed on October 21, 2026. Download the script from the application to obtain its current version and check whether its testing status has changed.
