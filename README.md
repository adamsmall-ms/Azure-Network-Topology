# Azure-Network-Topology
Azure Network Topology Scripts

Step 1 – Choose a script and download it with its instructions

There are four versions of the script, each with its own instruction file. Pick the one that fits your environment, then download both the instruction file and the matching script file. To download a file, open it in the repository and select the Download raw file icon at the top right of the file view.

## Choose a script

Each script has its own instruction file. Download the instruction file and the script for the option that fits your environment.

| Script type | Instructions | Script | Runs on / requires |
|---|---|---|---|
| **PowerShell** | [PowerShell-Instructions.md](PowerShell-Instructions.md) | [Get-NetworkTopology.ps1](Get-NetworkTopology.ps1) | Windows, macOS or Linux with PowerShell 7+ (not Windows PowerShell 5.1) |
| **Bash** | [Bash-Instructions.md](Bash-Instructions.md) | [get-network-topology.sh](get-network-topology.sh) | Linux, macOS or Azure Cloud Shell, with Bash 4+ and jq 1.6+ |
| **Python** | [Python-Instructions.md](Python-Instructions.md) | [get-network-topology.py](get-network-topology.py) | Windows, macOS or Linux with Python 3.8+ |
| **Graph (Python) – faster** | [Graph-Python-Instructions.md](Graph-Python-Instructions.md) | [get-network-topology-graph.py](get-network-topology-graph.py) | Windows, macOS, Linux or Azure Cloud Shell with Python 3.8+. Uses Azure Resource Graph for faster discovery. **Under test:** may not cover every edge case the standard scripts handle. |

All scripts require Azure CLI 2.60 or later, a signed-in session (`az login`) in the correct tenant, and Reader access to every subscription you want to discover.

Step 2 – Check the prerequisites

Whichever script you choose, you'll need:

Azure CLI 2.60 or later, signed in (az login) to the correct tenant
Reader access to every subscription you want included
The runtime listed for your script in the table above
Step 3 – Follow the instructions to run the script

The instruction file walks you through checking prerequisites, signing in and running discovery. If you run the script with no parameters, it walks you through each choice. You can also pass the subscription, a diagram title and an output file name (for example, 

topology.json
). Discovery can take several minutes in larger environments.

Step 4 – Send the JSON file back to me

When the script finishes, send the generated JSON file to the Azure ACE you are working with. The file describes your network infrastructure, so please treat it as sensitive. If your organization requires a different secure transfer method, let me know and we'll arrange one. If the script reports any errors, please send those as well so I can review them.

If you have any questions or run into problems, just let me know.
