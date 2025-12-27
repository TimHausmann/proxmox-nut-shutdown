# Proxmox UPS Graceful Shutdown Integration with NUT

This setup integrates Proxmox with the Network UPS Tools (NUT) system to perform a **graceful shutdown** of all VMs and containers in case of a power outage, and optionally cancel shutdown if power is restored.

## 📁 Files Included

- `upsmon.conf` - NUT monitoring client configuration.
- `upssched.conf` - Scheduler rules for conditional shutdowns.
- `upssched-cmd.sh` - Script triggered by upssched events.
- `pve-shutdown.sh` - Graceful shutdown logic for VMs, CTs, and power state checks.

---

## 🧰 Setup Instructions

### 1. Copy the Config and Scripts

```bash
cp upsmon.conf /etc/nut/upsmon.conf
cp upssched.conf /etc/nut/upssched.conf
cp upssched-cmd.sh /etc/nut/upssched-cmd.sh
cp pve-shutdown.sh /usr/local/sbin/pve-shutdown.sh
chmod +x /etc/nut/upssched-cmd.sh /usr/local/sbin/pve-shutdown.sh
```

### 2. Make Sure upsmon Runs as Root

Ensure `upsmon.conf` contains:

```ini
RUN_AS_USER root
```

### 3. Update UPS Server Address

Replace `ip.address.of.nut.server` in all files with the actual IP or hostname of your NUT server.

---

## ⚙️ Configuration Overview

### `upsmon.conf` Highlights

- Monitors remote UPS via `MONITOR` line.
- Triggers `/usr/sbin/upssched` for advanced scheduling.
- Executes shutdown via `pve-shutdown.sh` when needed.
- Notifies system users via `WALL`, logs events, and runs scripts.

### `upssched.conf` Behavior

Schedules actions on power events:

- Starts a 60-second timer after `ONBATT` to check battery level.
- Executes shutdown if battery is at or below 30%.
- Executes immediate shutdown on `LOWBATT` or `FSD`.

### `upssched-cmd.sh` Logic

- Logs all events.
- Executes `pve-shutdown.sh` if `battery.charge <= 30`.
- Cancels shutdown if power returns.

### `pve-shutdown.sh`

1. **Saves state** of currently running VMs and containers to `/var/lib/proxmox-running-state.txt`.
2. Shuts down all VMs and containers.
3. Waits up to 5 minutes for graceful shutdown.
4. Waits a configurable **grace period** (default: 180 seconds).
5. If power returns during grace period:
   - **Only restarts VMs/containers that were running before** (reads state file).
   - Cancels shutdown, system remains up.
6. If power not restored: Executes `shutdown -h now`.

---

## 🔍 State Preservation Feature

The `pve-shutdown.sh` script includes intelligent state preservation to prevent unnecessary VM/container restarts:

### How It Works

**Power Loss Detected**:
1. Script saves list of running VMs/containers to state file
2. Format: `VM:100`, `CT:200`, etc.
3. All VMs/containers shut down gracefully
4. Grace period begins (180 seconds)

**Power Restored During Grace Period**:
1. Script detects UPS back online (`ups.status = OL`)
2. Reads state file
3. **Only restarts VMs/containers that were running before**
4. VMs that were intentionally stopped remain stopped

**Power Not Restored**:
1. Grace period expires
2. Node shuts down cleanly

### State File Location

`/var/lib/proxmox-running-state.txt`

This file is automatically created/updated each time the shutdown script runs.

### Benefits

- **Prevents unwanted restarts**: Only previously running VMs/containers start
- **Respects intentional states**: Stopped VMs remain stopped
- **Reduces resource waste**: No unnecessary VM startups
- **Maintains system state**: System returns to expected configuration

---

## 🔄 Testing the Setup

1. **Stop a few VMs/containers** before testing (to verify they don't restart).
2. Simulate a power failure by disconnecting the UPS from wall power.
3. Observe `/var/log/upssched.log` and `/var/log/pve-shutdown.log`.
4. **Reconnect power during grace period** (within 180 seconds).
5. Verify only previously running VMs/containers restart.
6. Check state file: `cat /var/lib/proxmox-running-state.txt`

---

## ✅ Final Notes

- Ensure `upsc` is installed for UPS status checks.
- Adjust timing and thresholds as needed in the script.
- Test in a safe environment before production rollout.
