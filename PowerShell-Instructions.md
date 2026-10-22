# Network Topology Mapper - PowerShell

Discover your Azure network with the standard PowerShell script, then load the generated JSON into the [Azure Network Topology Viewer](https://app-esme-net-diagrams-wus3.azurewebsites.net/).

## Prerequisites

- PowerShell 7.0 or later (`pwsh`), not Windows PowerShell 5.1.
- Azure CLI 2.60 or later.
- Reader access to every subscription you intend to discover.
- An authenticated Azure CLI session in the appropriate tenant.

The script supports Windows, macOS, and Linux with PowerShell 7.

## 1. Download the script

1. Open https://github.com/adamsmall-ms/Azure-Network-Topology
2. Save `Get-NetworkTopology.ps1` and open PowerShell 7 in that folder.

## 2. Check prerequisites and sign in

```powershell
$PSVersionTable.PSVersion
az version
az login
az account list --output table
```

To sign in to a specific tenant:

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

On macOS or Linux, invoke the script as `./Get-NetworkTopology.ps1` from PowerShell 7.

On Windows, the script may offer to configure Azure CLI telemetry settings to prevent interactive prompts from blocking execution. Standard discovery uses sequential Azure CLI calls and may take several minutes in large environments.

## Optional settings

| Parameter | Purpose |
|---|---|
| `-Subscription` | Subscription ID or name |
| `-Title` | Diagram title |
| `-ResourceGroup` | Resource group name |
| `-VNetId` | Starting VNet's full ARM resource ID |
| `-VHubId` | Starting Virtual Hub's full ARM resource ID |
| `-Output` | Output JSON file path |
| `-Baseline` | Previous topology JSON used to increment `topologyVersion` |

Start from a specific VNet:

```powershell
.\Get-NetworkTopology.ps1 -VNetId "<full-vnet-resource-id>" -Output "topology.json"
```

Create a versioned snapshot from an earlier run:

```powershell
.\Get-NetworkTopology.ps1 -Subscription "<subscription-id-or-name>" -Baseline "topology.previous.json" -Output "topology.json"
```

Without a baseline, `topologyVersion` defaults to 1. Keep the previous JSON under a different filename when retaining historical snapshots.

## 4. Open the topology

1. Wait for discovery to complete and note the generated JSON's location.
2. Send the JSON file to the Azure ACE you are working with.


## Troubleshooting and handling

- If the PowerShell version is below 7, open `pwsh` rather than Windows PowerShell.
- If script execution is blocked, follow your organization's approved script-signing and execution-policy process; do not disable security controls globally.
- If `az` is not found, install Azure CLI or correct your terminal's PATH.
- If the target subscription is missing, confirm the signed-in tenant and your Reader permissions.
- If discovery reports errors, review them before treating the diagram as a complete inventory.
