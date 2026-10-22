# Network Topology Mapper - Bash

Discover your Azure network with the standard Bash script, then load the generated JSON into the [Azure Network Topology Viewer](https://app-esme-net-diagrams-wus3.azurewebsites.net/).

## Prerequisites

- Bash 4.0 or later.
- `jq` 1.6 or later.
- Azure CLI 2.60 or later.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

Use Linux, macOS, or Azure Cloud Shell's Bash environment. The Bash bundled with macOS may be version 3.x; install and use Bash 4+ before running the script.

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
2. Save `get-network-topology.sh` and open a Bash terminal in that folder.
3. If using Cloud Shell, upload the script into that environment first.

## 2. Check prerequisites and sign in

```bash
bash --version
jq --version
az version
az login
az account list --output table
```

Cloud Shell normally provides an authenticated Azure session; check that it is using the intended account and tenant. To sign in to a specific tenant when needed:

```bash
az login --tenant "<tenant-id>"
```

Replace all angle-bracket placeholders in these instructions with your own values.

## 3. Run discovery

For interactive discovery:

```bash
bash get-network-topology.sh
```

To provide a subscription, diagram title, and output file:

```bash
bash get-network-topology.sh --subscription "<subscription-id-or-name>" --title "Production Network" --output "topology.json"
```

Invoking the script through `bash` avoids needing to mark it executable. Ensure that the `bash` command resolves to version 4 or later.

Standard discovery uses sequential Azure CLI calls and may take several minutes in large environments.

## Optional settings

| Parameter | Purpose |
|---|---|
| `--subscription` | Subscription ID or name |
| `--title` | Diagram title |
| `--resource-group` | Resource group name |
| `--vnet-id` | Starting VNet's full ARM resource ID |
| `--output` | Output JSON file path |
| `--baseline` | Previous topology JSON used to increment `topologyVersion` |

Start from a specific VNet:

```bash
bash get-network-topology.sh --vnet-id "<full-vnet-resource-id>" --output "topology.json"
```

Create a versioned snapshot from an earlier run:

```bash
bash get-network-topology.sh --subscription "<subscription-id-or-name>" --baseline "topology.previous.json" --output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

The viewer's Bash tab does not document a `--vhub-id` parameter; do not assume the Bash script supports the same options as the Python variants.

## 4. Open the topology

1. Wait for discovery to complete and note the generated JSON's location.
2. If discovery ran in Cloud Shell, download the generated JSON to your computer.
3. Send the JSON file to the Azure ACE you are working with.

## Troubleshooting and handling

- If `bash`, `jq`, or `az` is missing or too old, install or update that prerequisite using your organization's approved process.
- On macOS, verify that your terminal uses the newly installed Bash rather than the older system version.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If discovery reports errors, review them before treating the diagram as a complete inventory.
