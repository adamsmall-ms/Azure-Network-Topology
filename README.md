# Azure Network Topology Scripts

These scripts discover your Azure network topology (VNets, vWAN hubs, subnets, peerings, gateways, ExpressRoute circuits, VPN sites and on-premises connections) and save it as a JSON file for your Azure ACE.

> [!NOTE]
> The Graph (Python) script is also still under test and may not cover every edge case the standard scripts handle.

## Step 1 – Choose a script and download it

Each script has its own instruction file. Pick the option that fits your environment, then download both the instruction file and the matching script. To download a file, open it in this repository and select the **Download raw file** icon at the top right of the file view.

| Script type | Instructions | Script | Runs on / requires |
|---|---|---|---|
| **PowerShell** | [PowerShell-Instructions.md](PowerShell-Instructions.md) | [Get-NetworkTopology.ps1](Get-NetworkTopology.ps1) | Windows, macOS, Linux or Azure Cloud Shell, with PowerShell 7+ (not Windows PowerShell 5.1) |
| **Bash** | [Bash-Instructions.md](Bash-Instructions.md) | [get-network-topology.sh](get-network-topology.sh) | Linux, macOS or Azure Cloud Shell, with Bash 4+ and jq 1.6+ |
| **Python** | [Python-Instructions.md](Python-Instructions.md) | [get-network-topology.py](get-network-topology.py) | Windows, macOS, Linux or Azure Cloud Shell, with Python 3.8+ |
| **Graph (Python) – faster** | [Graph-Python-Instructions.md](Graph-Python-Instructions.md) | [get-network-topology-graph.py](get-network-topology-graph.py) | Windows, macOS, Linux or Azure Cloud Shell, with Python 3.8+. Uses Azure Resource Graph for faster discovery. **Under test:** may not cover every edge case the standard scripts handle. |

Not sure which to choose? Use whichever runtime you already have installed. If you'd rather not install anything, use Azure Cloud Shell, which is normally already signed in to Azure. Upload the script, run it there, then download the generated files to your computer.

## Step 2 – Check the prerequisites

Whichever script you choose, you need:

- Azure CLI 2.60 or later, signed in (`az login`) to the correct tenant
- The Azure CLI `resource-graph` extension. If it's missing, the PowerShell, Bash and Python scripts offer to install it, or you can run `az extension add --name resource-graph`
- Reader access to every subscription you want to include
- The runtime listed for your script in the table above

## Step 3 – Run the script

Follow the instruction file for your script. It walks you through checking prerequisites, signing in and running discovery.

- If you run the script with no parameters, it prompts you for each choice.
- You can also pass the subscription, a diagram title and an output file name (for example, `topology.json`). The instruction file lists the exact parameters.
- Discovery can take several minutes in larger environments.

By default, the script saves its results as `topology.<title>.<timestamp>.json`, along with a `.log` file for the run:

- The PowerShell, Bash and Python scripts save these files in the folder you run the script from.
- The Graph script saves them in the folder that contains the script.
- If you choose **All VNets and Virtual Hubs**, the PowerShell, Bash and Python scripts can create a separate JSON file for each group of networks that aren't connected to each other.

## Step 4 – Send the files to your Azure ACE

1. If you ran the script in Azure Cloud Shell, download the generated files to your computer.
2. Send **all** generated JSON files to the Azure ACE you're working with.
3. Include the `.log` file from the same run. It records any errors or warnings your ACE should review.

> [!IMPORTANT]
> The JSON and log files describe your network infrastructure. Treat them as sensitive and share them only through channels your organization approves. If you need a different secure transfer method, ask your Azure ACE.

If you have questions or run into problems, contact your Azure ACE.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
