#!/bin/bash
# Place the script in /usr/local/sbin/
LOGFILE="/var/log/pve-shutdown.log"
UPS_NAME="apc-modem@ip.address.of.nut.server"
GRACE_PERIOD=180
CHECK_INTERVAL=10
STATE_FILE="/var/lib/proxmox-running-state.txt"

# Helper to run commands and log them
run_cmd() {
    echo "[$(date)] CMD: $*" >> "$LOGFILE"
    sh -c "$*"
}

echo "[$(date)] Starting Proxmox shutdown procedure via NUT" >> "$LOGFILE"

# Detect cluster membership and node list
echo "[$(date)] Detecting cluster membership" >> "$LOGFILE"
# Prefer filesystem listing of nodes to avoid parsing pvecm table formatting
NODES=$(ls -1 /etc/pve/nodes 2>/dev/null | awk 'NF{print $1}' | sort -u)
local_node=$(hostname -s)
node_count=1
if [ -n "$NODES" ]; then
    node_count=$(echo "$NODES" | wc -w)
fi

if [ "$node_count" -gt 1 ]; then
    IS_CLUSTER=1
    echo "[$(date)] Cluster detected with nodes: $NODES" >> "$LOGFILE"
else
    IS_CLUSTER=0
    NODES="$local_node"
    echo "[$(date)] No cluster detected. Operating on local node only." >> "$LOGFILE"
fi

# Save state of currently running VMs and containers (include node where they run)
echo "[$(date)] Saving state of running VMs and containers (cluster-aware)" >> "$LOGFILE"
> "$STATE_FILE"
for node in $NODES; do
    if [ "$node" = "$local_node" ]; then
        qm list | awk 'NR>1 && $3=="running" {print "'"$node"':VM:" $1}' >> "$STATE_FILE"
        pct list | awk 'NR>1 && $3=="running" {print "'"$node"':CT:" $1}' >> "$STATE_FILE"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$node" \
            "qm list 2>/dev/null | awk 'NR>1 && \$3==\"running\" {print \"VM:\" \$1}'" \
            | sed "s/^/$node:/" >> "$STATE_FILE" 2>/dev/null || echo "[$(date)] Warning: could not query VMs on $node" >> "$LOGFILE"

        ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$node" \
            "pct list 2>/dev/null | awk 'NR>1 && \$3==\"running\" {print \"CT:\" \$1}'" \
            | sed "s/^/$node:/" >> "$STATE_FILE" 2>/dev/null || echo "[$(date)] Warning: could not query CTs on $node" >> "$LOGFILE"
    fi
done

echo "[$(date)] Initiating guest shutdown on all nodes..." >> "$LOGFILE"
for node in $NODES; do
    if [ "$node" = "$local_node" ]; then
        echo "[$(date)] Shutting down local VMs" >> "$LOGFILE"
        for vmid in $(qm list | awk 'NR>1 {print $1}'); do
            echo "[$(date)] Shutting down VM ID $vmid" >> "$LOGFILE"
            run_cmd "qm shutdown $vmid &"
        done

        echo "[$(date)] Shutting down local LXC containers" >> "$LOGFILE"
        for ctid in $(pct list | awk 'NR>1 {print $1}'); do
            echo "[$(date)] Shutting down CT ID $ctid" >> "$LOGFILE"
            run_cmd "pct shutdown $ctid &"
        done
    else
        echo "[$(date)] Shutting down guests on $node via SSH" >> "$LOGFILE"
        run_cmd "ssh -o BatchMode=yes root@\"$node\" 'for vmid in \$(qm list | awk \"NR>1 {print \\\$1}\"); do qm shutdown \\\$vmid & done; for ctid in \$(pct list | awk \"NR>1 {print \\\$1}\"); do pct shutdown \\\$ctid & done' 2>/dev/null || echo \"[$(date)] Warning: could not initiate shutdown on $node\" >> $LOGFILE"
    fi
done

echo "[$(date)] Waiting for all guests to shut down across cluster..." >> "$LOGFILE"
timeout=300
while [ $timeout -gt 0 ]; do
    any_running=0
    for node in $NODES; do
        if [ "$node" = "$local_node" ]; then
            running_vms=$(qm list 2>/dev/null | awk 'NR>1 && $3 == "running" {print $1}')
            running_cts=$(pct list 2>/dev/null | awk 'NR>1 && $3 == "running" {print $1}')
        else
            running_vms=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$node" "qm list 2>/dev/null | awk 'NR>1 && \$3 == \"running\" {print \$1}'" 2>/dev/null)
            running_cts=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$node" "pct list 2>/dev/null | awk 'NR>1 && \$3 == \"running\" {print \$1}'" 2>/dev/null)
        fi

        if [ -n "$running_vms" ] || [ -n "$running_cts" ]; then
            any_running=1
            echo "[$(date)] Node $node still has running guests." >> "$LOGFILE"
        fi
    done

    if [ $any_running -eq 0 ]; then
        echo "[$(date)] All guests shut down successfully across cluster." >> "$LOGFILE"
        break
    fi

    echo "[$(date)] Still shutting down... ($timeout seconds left)" >> "$LOGFILE"
    sleep 10
    timeout=$((timeout - 10))
done

echo "[$(date)] Entering $GRACE_PERIOD second grace period before shutdown." >> "$LOGFILE"
remaining=$GRACE_PERIOD
while [ $remaining -gt 0 ]; do
    status=$(upsc "$UPS_NAME" ups.status 2>/dev/null)

    if echo "$status" | grep -q "OL"; then
        echo "[$(date)] Power returned. Canceling shutdown." >> "$LOGFILE"

        # Only restart VMs/containers that were running before
        if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
            echo "[$(date)] Restoring previously running guests from state file" >> "$LOGFILE"
            while IFS=: read -r node type id; do
                    case "$type" in
                        VM)
                            echo "[$(date)] Restarting VM ID $id on node $node" >> "$LOGFILE"
                            if [ "$node" = "$local_node" ]; then
                                run_cmd "qm start $id" || echo "[$(date)] Warning: failed to start VM $id locally" >> "$LOGFILE"
                            else
                                run_cmd "ssh -o BatchMode=yes root@\"$node\" \"qm start $id\"" || echo "[$(date)] Warning: failed to start VM $id on $node" >> "$LOGFILE"
                            fi
                            ;;
                        CT)
                            echo "[$(date)] Restarting CT ID $id on node $node" >> "$LOGFILE"
                            if [ "$node" = "$local_node" ]; then
                                run_cmd "pct start $id" || echo "[$(date)] Warning: failed to start CT $id locally" >> "$LOGFILE"
                            else
                                run_cmd "ssh -o BatchMode=yes root@\"$node\" \"pct start $id\"" || echo "[$(date)] Warning: failed to start CT $id on $node" >> "$LOGFILE"
                            fi
                            ;;
                    esac
            done < "$STATE_FILE"
        else
            echo "[$(date)] No state file found. No guests to restore." >> "$LOGFILE"
        fi

        echo "[$(date)] Shutdown canceled. System remains up." >> "$LOGFILE"
        exit 0
    fi

    echo "[$(date)] Power still out. ($remaining seconds left)" >> "$LOGFILE"
    sleep $CHECK_INTERVAL
    remaining=$((remaining - CHECK_INTERVAL))
done

echo "[$(date)] Grace period over. Power not restored. Proceeding with shutdown." >> "$LOGFILE"

# Stop HA services on all nodes (best-effort)
echo "[$(date)] Stopping HA services on all nodes" >> "$LOGFILE"
for node in $NODES; do
    if [ "$node" = "$local_node" ]; then
        run_cmd "systemctl stop pve-ha-lrm pve-ha-crm" || echo "[$(date)] Warning: failed to stop HA locally" >> "$LOGFILE"
    else
        run_cmd "ssh -o BatchMode=yes root@\"$node\" \"systemctl stop pve-ha-lrm pve-ha-crm\"" || echo "[$(date)] Warning: failed to stop HA on $node" >> "$LOGFILE"
    fi
done

# Shutdown remote nodes first, then local node
for node in $NODES; do
    if [ "$node" != "$local_node" ]; then
        echo "[$(date)] Sending shutdown to $node" >> "$LOGFILE"
        run_cmd "ssh -o BatchMode=yes root@\"$node\" \"shutdown -h now\"" || echo "[$(date)] Warning: failed to shutdown $node remotely" >> "$LOGFILE"
    fi
done

echo "[$(date)] Shutting down local node now" >> "$LOGFILE"
run_cmd "shutdown -h now"
