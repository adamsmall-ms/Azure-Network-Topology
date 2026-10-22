# Network Topology Mapper - PowerShell

Discover your Azure network with the standard PowerShell script and generate a JSON file to send to the Azure ACE you are working with.

## Prerequisites

- PowerShell 7.0 or later (`pwsh`), not Windows PowerShell 5.1.
- Azure CLI 2.60 or later.
- The Azure CLI `resource-graph` extension. If it's missing, the script offers to install it, or you can run `az extension add --name resource-graph`.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

The script supports Windows, macOS, Linux, and Azure Cloud Shell (PowerShell).

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
2. Select `Get-NetworkTopology.ps1`, then select the **Download raw file** icon at the top right of the file view.
3. Open PowerShell 7 in the folder where you saved the script.
4. If using Azure Cloud Shell, upload the script into that environment first.

## 2. Check prerequisites and sign in

```powershell
$PSVersionTable.PSVersion
az version
az login
az account list --output table
```

Cloud Shell normally provides an authenticated Azure session; check that it is using the intended account and tenant. To sign in to a specific tenant:

```powershell
az login --tenant "<tenant-id>"
```

Replace all angle-bracket placeholders in these instructions with your own values.

## 3. Run discovery

For interactive discovery on Windows:

```powershell
.\Get-NetworkTopology.ps1
```

To provide a subscription, diagram title, and output file:

```powershell
.\Get-NetworkTopology.ps1 -Subscription "<subscription-id-or-name>" -Title "Production Network" -Output "topology.json"
```

On macOS, Linux, or Azure Cloud Shell, invoke the script as `./Get-NetworkTopology.ps1` from PowerShell 7.

On Windows, the script may offer to configure Azure CLI telemetry settings to prevent interactive prompts from blocking execution. Standard discovery uses sequential Azure CLI calls and may take several minutes in large environments.

### Output files

- Unless you set `-Output`, the script saves the JSON file in the folder you run it from. The file name starts with `topology.` and includes the diagram title and a timestamp.
- The script also writes a `.log` file for the run; look for the `Log file:` line in the script's output to find it.
- If you choose **All VNets and Virtual Hubs** when prompted, the script can create a separate JSON file for each group of networks that aren't connected to each other.

## Optional settings

| Parameter | Purpose |
|---|---|
| `-Subscription` | Subscription ID or name |
| `-Title` | Diagram title |
| `-ResourceGroup` | Resource group name |
| `-VNetId` | Starting VNet's full ARM resource ID |
| `-VHubId` | Starting Virtual Hub's full ARM resource ID |
| `-Output` | Output JSON file path |
| `-Baseline` | Previous topology JSON; increments `topologyVersion` and carries over edits made in that file (layout positions, on-premises sites, tags) |

Start from a specific VNet:

```powershell
.\Get-NetworkTopology.ps1 -VNetId "<full-vnet-resource-id>" -Output "topology.json"
```

Create a versioned snapshot from an earlier run:

```powershell
.\Get-NetworkTopology.ps1 -Subscription "<subscription-id-or-name>" -Baseline "topology.previous.json" -Output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

## 4. Send the files to your Azure ACE

1. Wait for discovery to complete and note where the JSON and `.log` files were saved.
2. If discovery ran in Azure Cloud Shell, download the generated files to your computer.
3. Send all generated JSON files to the Azure ACE you are working with.
4. Include the `.log` file from the same run. It records any errors or warnings your ACE should review.

## Troubleshooting

- If the PowerShell version is below 7, open `pwsh` rather than Windows PowerShell.
- If script execution is blocked, follow your organization's approved script-signing and execution-policy process; do not disable security controls globally.
- If `az` is not found, install Azure CLI or correct your terminal's PATH.
- If the script reports that the `resource-graph` extension is missing, let the script install it or run `az extension add --name resource-graph`, following your organization's approved installation process.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If discovery reports errors, the results may be incomplete. Include the `.log` file when you send the JSON so your ACE can review them.
