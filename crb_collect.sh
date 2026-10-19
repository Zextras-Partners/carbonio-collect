#!/bin/bash

# Initialize flag variable
flag_e=""

# Parse command line options
while getopts ":e" opt; do
    case ${opt} in
        e)
            flag_e="true"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Check if os-release file exists
if [ ! -f /etc/os-release ]; then
	echo "Error: /etc/os-release not found. Cannot determine OS."
	exit 1
fi

# Are we zextras?
if [ `whoami` != "zextras" ]; then
        echo "ERROR! ${0} must be run by the zextras user"
        exit 1
fi

# Define the output file and initialize it (clears existing content)
OUTPUT_PATH="/tmp/carbonio_"$(date +"%d%m%Y-%H%M%S")
mkdir -p $OUTPUT_PATH

# Check Ubuntu
if grep -iq 'ubuntu' /etc/os-release; then
	if dpkg-query -W -f='${Status}' carbonio-advanced 2>/dev/null | grep -q "ok installed"; then
		OUTPUT_FILE="$OUTPUT_PATH/carbonio_license.txt"
		> "$OUTPUT_FILE"
		/opt/zextras/bin/carbonio core getlicenseinfo >> "$OUTPUT_FILE" 2>&1
	else
		echo "This script must be executed on a Carbonio Mailbox server."
		exit 1
	fi
# Check RHEL 
elif grep -iq 'rhel' /etc/os-release; then
	if rpm -q carbonio-advanced >/dev/null 2>&1; then
		OUTPUT_FILE="$OUTPUT_PATH/carbonio_license.txt"
		> "$OUTPUT_FILE"
		/opt/zextras/bin/carbonio core getlicenseinfo >> "$OUTPUT_FILE" 2>&1
	else
		echo "This script must be executed on a Carbonio Mailbox server."
		exit 1
	fi
else
	echo "Error: Unsupported OS ($os_id). This script only supports Ubuntu and RHEL families."
	exit 2
fi


echo "Starting Carbonio infrastructure data collection to $OUTPUT_FILE"


server_list=$(/opt/zextras/bin/carbonio prov -l gas)
while IFS= read -r srv; do
    if [ -n "$srv" ]; then
        # Collect localconfig.xml from all servers
        mkdir -p "$OUTPUT_PATH/servers/" 
        mkdir -p "$OUTPUT_PATH/localconfigs/" 
		rsync -aWr -e "ssh -o StrictHostKeyChecking=no -i /opt/zextras/.ssh/zimbra_identity" "zextras@$srv:/opt/zextras/conf/localconfig.xml" "$OUTPUT_PATH/localconfigs/"$srv"_localconfig.txt"
		# Remove passwords from the localconfig.xml file
		perl -0777 -pi -e 's/(<key name="[^"]*_password">\s*<value>)[^<]*(<\/value>)/\1\2/g' "$OUTPUT_PATH/localconfigs/"$srv"_localconfig.txt"
		echo "Fetching configuration for $srv..."
		OUTPUT_FILE="$OUTPUT_PATH/servers/"$srv"_resources.txt"
		# Fetch data from Node Exporter with a 5-second timeout to prevent indefinite hanging
		metrics_data=$(curl -s --max-time 5 "http://$srv:9100/metrics")
		curl_status=$?
		if (( curl_status != 0 )); then
			# curl failed (e.g., connection refused, timeout, host unreachable)
			echo "Node exporter not available on $srv" >> "$OUTPUT_FILE"
		else
			#save the metrics data to a file for further analysis
			echo "CPUs "$(curl -s http://$srv:9100/metrics | grep '^node_cpu_seconds_total' | grep -wc 'mode="idle"') >> "$OUTPUT_FILE" 2>&1
			curl -s http://$srv:9100/metrics | awk '/^node_memory_MemTotal_bytes / {printf "RAM Total: %.2f GB\n", $2 / 1024 / 1024 / 1024}'  >> "$OUTPUT_FILE" 2>&1
			echo -e "\n--------------- Packages installed ---------------" >> "$OUTPUT_FILE"
			echo "$metrics_data" | grep installed_packages | awk '{
				match($0, /package_name="([^"]+)"/, pkg); 
				match($0, /version="([^"]+)"/, ver); 
				printf "%-35s\t%s\n", pkg[1], ver[1]
			}' >> "$OUTPUT_FILE" 2>&1
		fi
		OUTPUT_FILE="$OUTPUT_PATH/servers/"$srv"_conf.txt"
		is_mailstore=false
		echo -e "\n--------------- Server Config --------------------" >> "$OUTPUT_FILE"
		/opt/zextras/bin/carbonio prov -l getServer $srv >> "$OUTPUT_FILE" 2>&1
		#Check if carbonio advanced is present on the server looking at consul for carbonio-advanced service
		consul_srvname="${srv//./-}"
		consul_node=$(consul catalog nodes | awk 'NR > 1 {print $1}' | grep "$consul_srvname")
		if [ -n "$consul_node" ] ; then
			node_services=$(consul catalog services -node="$consul_node" 2>&1)
			if grep -Fxq 'carbonio-advanced' <<< "$node_services"; then
				echo -e "\n--------------- Server Config Zextras ------------" >> "$OUTPUT_FILE"
				/opt/zextras/bin/carbonio config dump server $srv >> "$OUTPUT_FILE" 2>&1
				echo -e "\n--------------- Server volumes ------------" >> "$OUTPUT_FILE"
				/opt/zextras/bin/carbonio --host $srv powerstore getAllVolumes >> "$OUTPUT_FILE" 2>&1
			fi
		fi
	fi	
done <<< "$server_list"

# Get Carbonio configs
OUTPUT_FILE="$OUTPUT_PATH/carbonio_configs.txt"
echo -e "\n--------------- All servers --------------------" >> "$OUTPUT_FILE"
while IFS= read -r srv; do
	echo $srv >> "$OUTPUT_FILE"
done <<< "$server_list"
echo -e "\n--------------- Global Config --------------------" >> "$OUTPUT_FILE"
/opt/zextras/bin/carbonio prov -l getAllConfig >> "$OUTPUT_FILE" 2>&1
echo -e "\n--------------- Global Config Zextras ------------" >> "$OUTPUT_FILE"
/opt/zextras/bin/carbonio config dump global >> "$OUTPUT_FILE" 2>&1

# Get mesh data from Consul
OUTPUT_FILE="$OUTPUT_PATH/carbonio_mesh.txt"
echo -e "\n--------------- Consul members --------------------" >> "$OUTPUT_FILE"
if command -v consul >/dev/null 2>&1; then
    consul members >> "$OUTPUT_FILE" 2>&1
else
    echo "Warning: 'consul' command not found." >> "$OUTPUT_FILE"
fi

# Consul Nodes and Services
echo -e "\n---------------  Services Grouped by Node --------------------" >> "$OUTPUT_FILE"
if command -v consul >/dev/null 2>&1; then
    for node in $(consul catalog nodes | awk 'NR>1 {print $1}'); do
        echo "=== Node: $node ===" >> "$OUTPUT_FILE"
        consul catalog services -node="$node" >> "$OUTPUT_FILE" 2>&1
        echo "" >> "$OUTPUT_FILE"
    done
fi

echo -e "\n---------------  Nodes Grouped by Service --------------------" >> "$OUTPUT_FILE"
if command -v consul >/dev/null 2>&1; then
	curl -s http://127.0.0.1:8500/v1/catalog/services | jq -r 'keys[]' | grep -v sidecar | while read service; do 
		echo -e "\n$service:"  >> "$OUTPUT_FILE" 2>&1; 
		curl -s http://127.0.0.1:8500/v1/catalog/service/$service | jq -r '.[].Node' | sort | sed 's/^/  - /' >> "$OUTPUT_FILE" 2>&1; 
	done 
fi

# Consul Health Status
echo -e "\n--------------- Consul status --------------------" >> "$OUTPUT_FILE"
if command -v jq >/dev/null 2>&1; then
    curl -s http://127.0.0.1:8500/v1/health/state/any | jq -r '.[] | select(.ServiceName != "") | "\(.Node) -> Service: \(.ServiceName) [Status: \(.Status)]"' >> "$OUTPUT_FILE"
else
    # Fallback to raw JSON if jq is not installed
    echo "Warning: 'jq' not found, dumping raw JSON." >> "$OUTPUT_FILE"
    curl -s http://127.0.0.1:8500/v1/health/state/any >> "$OUTPUT_FILE"
fi

if [ "$flag_e" = "true" ]; then
	mkdir -p "$OUTPUT_PATH/domains/"
	# Get domains 

	domain_list=$(/opt/zextras/bin/carbonio prov -l gad)
	while IFS= read -r domain; do
			OUTPUT_FILE="$OUTPUT_PATH/domains/$domain.txt"
			echo -e "\n--------------- Domain settings for $domain --------------------" >> "$OUTPUT_FILE"
			/opt/zextras/bin/carbonio prov -l getDomain $domain >> "$OUTPUT_FILE" 2>&1
			echo -e "\n--------------- Carbonio domain setting $domain --------------------" >> "$OUTPUT_FILE"
			/opt/zextras/bin/carbonio config dump domain $domain >> "$OUTPUT_FILE" 2>&1
	done <<< "$domain_list"

	# Get COSes 
	mkdir -p "$OUTPUT_PATH/coses/"
	domain_list=$(/opt/zextras/bin/carbonio prov -l gac)
	while IFS= read -r cos; do
		    OUTPUT_FILE="$OUTPUT_PATH/coses/$cos.txt"
			echo -e "\n--------------- Cos $cos --------------------" >> "$OUTPUT_FILE"
			/opt/zextras/bin/carbonio prov -l getCos $cos >> "$OUTPUT_FILE" 2>&1
			echo -e "\n--------------- Carbonio COS setting $cos --------------------" >> "$OUTPUT_FILE"
			/opt/zextras/bin/carbonio config dump cos $cos >> "$OUTPUT_FILE" 2>&1
	done <<< "$domain_list"	
fi	

echo "Data collection complete. Output saved to $OUTPUT_PATH"