# npmHALXC

Proxmox LXC setup scripts for a high-availability [Nginx Proxy Manager](https://nginxproxymanager.com/) cluster. Styled after [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE).

Run the script **once per host** — each server gets one LXC container configured as either MASTER or BACKUP.

---

## How it works

- **keepalived** manages a floating Virtual IP (VIP) using unicast VRRP between the two nodes. Unicast is used instead of multicast for reliable operation inside LXC containers.
- **NPM** runs via Docker Compose on both nodes simultaneously. Traffic always hits whichever node currently holds the VIP.
- **rsync** replicates `/opt/npm/data/` and `/opt/npm/letsencrypt/` from primary to backup on a configurable interval (default: 30 min).
- If the primary goes down, keepalived moves the VIP to the backup within seconds. When primary recovers, it reclaims the VIP automatically.

Point your DNS records and router port forwards (80, 443, 81) at the VIP — not the individual node IPs.

---

## Requirements

- Two Proxmox hosts (or two Proxmox nodes in a cluster)
- Ubuntu 24.04 LXC template available (`pveam update`)
- The VIP must be an unused IP on the same subnet as both nodes
- Static IPs required for both containers

---

## Setup

### 1. Primary (MASTER)

Run on the first Proxmox host:

```bash
bash ct/npm-ha.sh
```

Select **[1] MASTER** when prompted. At the end, the script prints an SSH public key — copy it, you'll need it for step 2.

### 2. Backup (BACKUP)

Run on the second Proxmox host:

```bash
bash ct/npm-ha.sh
```

Select **[2] BACKUP** when prompted. Paste in the SSH key from step 1 when asked.

Use the **same VIP, VRRP ID, and VRRP password** on both nodes.

---

## Accessing NPM

After both nodes are up, access the admin UI via the VIP:

```
http://<VIP>:81
```

Default credentials: `admin@example.com` / `changeme` — change immediately after first login.

---

## Management

```bash
# Check HA status (VIP holder, keepalived state, sync log)
pct exec <ctid> -- npm-ha-status

# Force an immediate sync (primary only)
pct exec <ctid> -- npm-ha-sync

# View NPM logs
pct exec <ctid> -- docker logs npm -f

# View keepalived logs
pct exec <ctid> -- journalctl -u keepalived -f

# Test failover — VIP moves to backup within ~3 seconds
pct stop <primary-ctid>
```

---

## Sync limitations

Config replication is periodic, not real-time. Changes made to NPM while the primary is down (backup acting as master) will not sync back automatically when primary recovers. For production use cases requiring real-time config sync, a shared MariaDB/Galera cluster would be needed.

---

## Scripts

| Script | Runs on | Purpose |
|--------|---------|---------|
| `ct/npm-ha.sh` | Proxmox host | Creates the LXC container, prompts for all config |
| `install/npm-ha-install.sh` | Inside container (auto) | Installs Docker, NPM, keepalived, SSH sync key, cron |
