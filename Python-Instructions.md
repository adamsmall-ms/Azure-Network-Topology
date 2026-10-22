# Network Topology Mapper - Python

Discover your Azure network with the standard Python script and generate a JSON file to send to the Azure ACE you are working with.

## Prerequisites

- Python 3.8 or later.
- Azure CLI 2.60 or later.
- The Azure CLI `resource-graph` extension. If it's missing, the script offers to install it, or you can run `az extension add --name resource-graph`.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

No `jq` installation is required. The script supports Windows, macOS, Linux, and Azure Cloud Shell.

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
2. Select `get-network-topology.py`, then select the **Download raw file** icon at the top right of the file view.
3. Open a terminal in the folder where you saved the script.
4. If using Azure Cloud Shell, upload the script into that environment first.

## 2. Check prerequisites and sign in

```text
python3 --version
az version
az login
az account list --output table
```

On Windows, substitute `python` for `python3` if that is your installed interpreter command. Cloud Shell normally provides an authenticated Azure session; check that it is using the intended account and tenant. To sign in to a specific tenant, use:

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

### Output files

- Unless you set `--output`, the script saves the JSON file in the folder you run it from. The file name starts with `topology.` and includes the diagram title and a timestamp.
- The script also writes a `.log` file for the run; look for the `Log file:` line in the script's output to find it.
- If you choose **All VNets and Virtual Hubs** when prompted, the script can create a separate JSON file for each group of networks that aren't connected to each other.

## Optional settings

| Parameter | Purpose |
|---|---|
| `--subscription` | Subscription ID or name |
| `--title` | Diagram title |
| `--resource-group` | Resource group name |
| `--vnet-id` | Starting VNet's full ARM resource ID |
| `--vhub-id` | Starting Virtual Hub's full ARM resource ID |
| `--output` | Output JSON file path |
| `--baseline` | Previous topology JSON; increments `topologyVersion` and carries over edits made in that file (layout positions, on-premises sites, tags) |

Start from a specific VNet:

```text
python3 get-network-topology.py --vnet-id "<full-vnet-resource-id>" --output "topology.json"
```

Create a versioned snapshot from an earlier run:

```text
python3 get-network-topology.py --subscription "<subscription-id-or-name>" --baseline "topology.previous.json" --output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

## 4. Send the files to your Azure ACE

1. Wait for discovery to complete and note where the JSON and `.log` files were saved.
2. If discovery ran in Azure Cloud Shell, download the generated files to your computer.
3. Send all generated JSON files to the Azure ACE you are working with.
4. Include the `.log` file from the same run. It records any errors or warnings your ACE should review.

## Troubleshooting

- If Python or `az` is not found, install the prerequisite or correct your terminal's PATH.
- If the script reports that the `resource-graph` extension is missing, let the script install it or run `az extension add --name resource-graph`, following your organization's approved installation process.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If discovery reports errors, the results may be incomplete. Include the `.log` file when you send the JSON so your ACE can review them.
