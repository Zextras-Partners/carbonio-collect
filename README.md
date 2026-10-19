# Carbonio Infrastructure Collection Script


This ia a bash utility to collect Carbonio environment diagnostics from a mailbox server, the content of the folder created by the script  
could be shared in tickets opened from the Zextras partner portal.


## Purpose


This script gathers configuration, service, and health information for a Carbonio deployment and stores the results in a timestamped directory under `/tmp`.


## What it collects


- Carbonio license information
- Servers inventory
- Per-node configuration details
- Node Exporter metrics (CPU, memory, installed packages)
- Carbonio global/server configuration
- Consul members, services, and health status
- Domains and COS settings if executet using -e option


## Requirements


- Run as the zextras user on a Carbonio mailbox server
- /opt/zextras/bin/carbonio available
- curl installed
- jq recommended for Consul JSON output


## Usage


sudo -u zextras   
crb_collect.sh It collects infrastructure information 
crb_collect.sh -e It collects infrastructure information and also domains and COS


## Output


The script creates a folder such as:


```bash
/tmp/carbonio_12102024-153045

```


and writes files including:

- carbonio_license.txt
- carbonio_data.txt
- carbonio_mesh.txt

And subfolders with server data.


## Security


The dump avoid to save common parameters that could contains clear text passwords.
The output may contain sensitive infrastructure details. Store the generated files in secure, access-controlled locations.


