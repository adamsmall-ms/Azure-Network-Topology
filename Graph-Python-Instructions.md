# Network Topology Mapper - Graph (Python)

Discover your Azure network using Azure Resource Graph and generate a JSON file to send to the Azure ACE you are working with.

**Status: Under Test.** This variant is under active testing. It uses Azure Resource Graph for faster discovery but may not cover every edge case handled by the standard Python, PowerShell, and Bash scripts.

## Prerequisites

- Python 3.8 or later.
- Azure CLI 2.60 or later.
- The Azure CLI `resource-graph` extension. If it's missing, the script offers to install it, or you can run `az extension add --name resource-graph`.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

The script supports Windows, macOS, Linux, and Azure Cloud Shell.

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
2. Select `get-network-topology-graph.py`, then select the **Download raw file** icon at the top right of the file view.
3. Open a terminal in the folder where you saved the script.
4. If using Azure Cloud Shell, upload the script into that environment first.

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

### Output files

- Unless you set `--output`, the script saves the JSON file in the folder that contains the script, not the folder you run it from. The file name starts with `topology.` and includes the diagram title and a timestamp.
- The script also writes a `.log` file with the same base name next to the JSON file.
- The script also writes `graph-queries.kql`, a list of the Resource Graph queries it ran, in the folder that contains the script.

## Optional settings

| Parameter | Purpose |
|---|---|
| `--subscription` | Subscription ID or name |
| `--title` | Diagram title |
| `--resource-group` | Resource group name |
| `--vnet-id` | Starting VNet's full ARM resource ID |
| `--vhub-id` | Starting Virtual Hub's full ARM resource ID |
| `--output` | Output JSON file path |
| `--baseline` | Previous topology JSON; increments `topologyVersion`, carries over edits made in that file, and turns on incremental discovery |
| `--full` | Forces full discovery even when a valid baseline exists |

Start from a specific VNet:

```text
python3 get-network-topology-graph.py --vnet-id "<full-vnet-resource-id>" --output "topology.json"
```

Create a versioned snapshot from an earlier run:

```text
python3 get-network-topology-graph.py --subscription "<subscription-id-or-name>" --baseline "topology.previous.json" --output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

### Incremental discovery

When you pass `--baseline` with a valid topology file, the script automatically runs in incremental mode. It reuses subnet resource data from the previous run for VNets that haven't changed and always re-queries backbone resources such as gateways, ExpressRoute circuits, and connections. It falls back to full discovery when the baseline is more than 30 days old, comes from a different schema or script version, or is corrupt.

To force a complete re-query while keeping the baseline's edits and version history, add `--full`:

```text
python3 get-network-topology-graph.py --subscription "<subscription-id-or-name>" --baseline "topology.previous.json" --output "topology.json" --full
```

## 4. Send the files to your Azure ACE

1. Wait for discovery to complete and note where the JSON and `.log` files were saved.
2. If discovery ran in Azure Cloud Shell, download the generated files to your computer.
3. Send the generated JSON file to the Azure ACE you are working with.
4. Include the `.log` file from the same run. It records any errors or warnings your ACE should review.

## Troubleshooting and handling

- If Python or `az` is not found, install the prerequisite or correct your terminal's PATH.
- If the script reports that the `resource-graph` extension is missing, let the script install it or run `az extension add --name resource-graph`, following your organization's approved installation process.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If the script reports another missing prerequisite, follow its explicit guidance using your organization's approved installation process.
- If results appear incomplete, run a standard discovery script against the same intended scope and compare the results. Report Graph-script issues to your Azure ACE.
- If discovery reports errors, the results may be incomplete. Include the `.log` file when you send the JSON so your ACE can review them.
- Treat the JSON and log files as sensitive infrastructure information. Share them only through channels your organization approves.
