#!/usr/bin/env bash
# NPM HA Container Install — Docker + Nginx Proxy Manager + keepalived
# Runs inside the container. Expects env vars sourced from /root/install-config.sh
# before this script is executed.
set -euo pipefail

# ─── Colors & Messages ───────────────────────────────────────────────────────
YW="\033[33m"; GN="\033[1;92m"; DGN="\033[32m"; RD="\033[01;31m"; CL="\033[m"
BOLD="\033[1m"; BFR="\\r\\033[K"
TAB="  "; CM="${TAB}✔${TAB}"; CROSS="${TAB}✖${TAB}"; INFO="${TAB}💡${TAB}"

msg_info()  { printf " ${BOLD}${YW}%-50s${CL}" "$1"; }
msg_ok()    { printf "${BFR}${CM}${GN}%s${CL}\n" "$1"; }
msg_error() { printf "${BFR}${CROSS}${RD}%s${CL}\n" "$1" >&2; exit 1; }
msg_warn()  { printf "\n${INFO}${YW}%s${CL}\n" "$1"; }

# ─── Config (must be sourced from install-config.sh before running) ──────────
ROLE="${ROLE:-MASTER}"
OWN_IP="${OWN_IP:-}"
PEER_IP="${PEER_IP:-}"
VIP="${VIP:-}"
VIP_IFACE="${VIP_IFACE:-eth0}"
VRRP_ID="${VRRP_ID:-51}"
VRRP_PASS="${VRRP_PASS:-npmha2024}"
SYNC_INTERVAL="${SYNC_INTERVAL:-30}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1}"

[[ -z "$OWN_IP" ]]  && msg_error "OWN_IP is required"
[[ -z "$PEER_IP" ]] && msg_error "PEER_IP is required"
[[ -z "$VIP" ]]     && msg_error "VIP is required"

echo ""
printf "${BOLD}  Installing: NPM HA — %s${CL}\n" "$ROLE"
printf "${DGN}  %-45s  Ubuntu 24.04${CL}\n" "Docker + Nginx Proxy Manager + keepalived"
printf "${DGN}  OWN_IP: %-18s PEER_IP: %s${CL}\n" "$OWN_IP" "$PEER_IP"
echo ""

# ─── Network & DNS ───────────────────────────────────────────────────────────
msg_info "Waiting for default route"
WAIT=0
while [[ $WAIT -lt 30 ]]; do
  ip route | grep -q default && break
  sleep 2; WAIT=$((WAIT + 2))
done
GW=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
[[ -z "$GW" ]] && msg_error "No default route after 30s. Check bridge and IP config in Proxmox."
msg_ok "Default route via ${GW}"

msg_info "Checking gateway reachability"
ping -c2 -W3 "$GW" &>/dev/null \
  || msg_error "Cannot reach gateway ${GW}. Check VLAN, bridge, or IP assignment."
msg_ok "Gateway ${GW} reachable"

msg_info "Forcing apt to use IPv4 only"
printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4
msg_ok "apt forced to IPv4"

msg_info "Fixing DNS (removing systemd-resolved stub)"
# Ubuntu 24.04 symlinks /etc/resolv.conf → systemd-resolved stub (127.0.0.53).
# Remove the symlink and write a real file so DNS works without a running resolver.
[[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
{
  for ns in ${DNS_SERVERS:-1.1.1.1}; do printf 'nameserver %s\n' "$ns"; done
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'  # fallback entries
} | awk '!seen[$0]++' > /etc/resolv.conf  # deduplicate
getent hosts archive.ubuntu.com &>/dev/null \
  || msg_error "DNS still not resolving. Verify the host can reach the internet and gateway ${GW} is routing correctly."
msg_ok "DNS OK (using: $(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf))"

# ─── System Update ───────────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
msg_ok "System updated"

# ─── Base Dependencies ───────────────────────────────────────────────────────
msg_info "Installing dependencies"
apt-get install -y -qq \
  curl ca-certificates gnupg lsb-release \
  rsync openssh-client openssh-server \
  keepalived cron
msg_ok "Dependencies installed"

# ─── Docker ──────────────────────────────────────────────────────────────────
msg_info "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc 2>/dev/null
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
msg_ok "Docker installed"

# ─── NPM Setup ───────────────────────────────────────────────────────────────
msg_info "Setting up Nginx Proxy Manager"
mkdir -p /opt/npm/data /opt/npm/letsencrypt
cat > /opt/npm/docker-compose.yml << 'COMPOSEEOF'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - /opt/npm/data:/data
      - /opt/npm/letsencrypt:/etc/letsencrypt
COMPOSEEOF
msg_ok "NPM compose file written (/opt/npm/docker-compose.yml)"

msg_info "Pulling and starting NPM"
docker compose -f /opt/npm/docker-compose.yml pull -q 2>/dev/null
docker compose -f /opt/npm/docker-compose.yml up -d
msg_ok "NPM container started"

# ─── SSH Configuration ────────────────────────────────────────────────────────
msg_info "Configuring SSH for rsync"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# Allow root login via pubkey only (required for rsync from primary)
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config
systemctl enable --now ssh
msg_ok "SSH configured (pubkey-only root login)"

# ─── keepalived ──────────────────────────────────────────────────────────────
msg_info "Configuring keepalived (VRRP unicast)"
[[ "$ROLE" == "MASTER" ]] && VRRP_PRIORITY=255 || VRRP_PRIORITY=100

cat > /etc/keepalived/keepalived.conf << KAEOF
global_defs {
    router_id NPM_${ROLE}
}

vrrp_instance NPM_HA {
    state ${ROLE}
    interface ${VIP_IFACE}
    virtual_router_id ${VRRP_ID}
    priority ${VRRP_PRIORITY}
    advert_int 1
    unicast_src_ip ${OWN_IP}
    unicast_peer {
        ${PEER_IP}
    }
    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASS}
    }
    virtual_ipaddress {
        ${VIP}
    }
}
KAEOF

systemctl enable --now keepalived
msg_ok "keepalived configured (${ROLE}, priority ${VRRP_PRIORITY}, VIP: ${VIP})"

# ─── MASTER: SSH sync key + rsync script + cron ──────────────────────────────
if [[ "$ROLE" == "MASTER" ]]; then
  msg_info "Generating SSH sync key (ed25519)"
  ssh-keygen -t ed25519 -f /root/.ssh/npm_ha_sync -N "" -C "npm-ha-sync@$(hostname)" -q
  msg_ok "SSH sync key generated (/root/.ssh/npm_ha_sync)"

  msg_info "Writing rsync script"
  cat > /usr/local/bin/npm-ha-sync << SYNCEOF
#!/usr/bin/env bash
# NPM HA config sync — primary to backup (auto-generated, do not edit IPs here)
BACKUP_IP="${PEER_IP}"
SSH_KEY="/root/.ssh/npm_ha_sync"
SSH_OPTS="-i \${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
LOG_PREFIX="\$(date '+%Y-%m-%d %H:%M:%S') [npm-ha-sync]"

rsync_dir() {
  rsync -az --delete -e "ssh \${SSH_OPTS}" "\$1" "root@\${BACKUP_IP}:\$2" 2>&1
}

echo "\${LOG_PREFIX} Starting sync to \${BACKUP_IP}"
ERR=0
rsync_dir /opt/npm/data/        /opt/npm/data/        || ERR=1
rsync_dir /opt/npm/letsencrypt/ /opt/npm/letsencrypt/ || ERR=1
if [[ \$ERR -eq 0 ]]; then
  echo "\${LOG_PREFIX} OK"
else
  echo "\${LOG_PREFIX} FAILED" >&2
  exit 1
fi
SYNCEOF
  chmod +x /usr/local/bin/npm-ha-sync
  touch /var/log/npm-ha-sync.log
  msg_ok "Sync script written (/usr/local/bin/npm-ha-sync)"

  msg_info "Scheduling sync cron (every ${SYNC_INTERVAL} min)"
  ( crontab -l 2>/dev/null | grep -v 'npm-ha-sync'; \
    echo "*/${SYNC_INTERVAL} * * * * /usr/local/bin/npm-ha-sync >> /var/log/npm-ha-sync.log 2>&1" \
  ) | crontab -
  systemctl enable --now cron
  msg_ok "Cron scheduled (every ${SYNC_INTERVAL} min)"
fi

# ─── BACKUP: install primary's sync pubkey ───────────────────────────────────
if [[ "$ROLE" == "BACKUP" ]]; then
  if [[ -f /root/npm-ha-sync.pub ]]; then
    msg_info "Installing primary SSH sync key"
    cat /root/npm-ha-sync.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    rm -f /root/npm-ha-sync.pub
    msg_ok "Primary sync key installed in authorized_keys"
  else
    msg_warn "npm-ha-sync.pub not found — rsync from primary will fail until key is installed."
    msg_warn "  Fix: copy primary's /root/.ssh/npm_ha_sync.pub to this node's /root/.ssh/authorized_keys"
  fi
fi

# ─── Status Script (both nodes) ───────────────────────────────────────────────
msg_info "Writing status script"
cat > /usr/local/bin/npm-ha-status << 'STATUSEOF'
#!/usr/bin/env bash
KACONF="/etc/keepalived/keepalived.conf"
VIP=$(awk '/virtual_ipaddress/{found=1;next} found && /[0-9]/{print $1;exit}' "$KACONF" 2>/dev/null)
VIP_BARE="${VIP%%/*}"
ROLE=$(awk '/^\s*state/{print $2;exit}' "$KACONF" 2>/dev/null)

printf "\n=== NPM HA Status ===\n\n"
printf "Configured role: %s\n" "$ROLE"
if [[ -n "$VIP_BARE" ]] && ip addr show 2>/dev/null | grep -q "$VIP_BARE"; then
  printf "VIP %s: \033[1;92mACTIVE\033[m (this node is currently MASTER)\n" "$VIP_BARE"
else
  printf "VIP %s: not held (this node is currently BACKUP)\n" "$VIP_BARE"
fi

printf "\n--- keepalived ---\n"
systemctl is-active keepalived 2>/dev/null || true

printf "\n--- NPM ---\n"
docker compose -f /opt/npm/docker-compose.yml ps 2>/dev/null

if [[ -f /var/log/npm-ha-sync.log ]]; then
  printf "\n--- Sync log (last 10 lines) ---\n"
  tail -10 /var/log/npm-ha-sync.log
elif [[ -f /usr/local/bin/npm-ha-sync ]]; then
  printf "\n(sync log empty — no sync has run yet)\n"
fi
printf "\n"
STATUSEOF
chmod +x /usr/local/bin/npm-ha-status
msg_ok "Status script written (/usr/local/bin/npm-ha-status)"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
msg_info "Cleaning up"
apt-get autoremove -y -qq
apt-get clean -qq
rm -f /root/install.sh /root/install-config.sh
msg_ok "Cleanup done"

# ─── Verify NPM is responding ────────────────────────────────────────────────
msg_info "Waiting for NPM health check"
WAIT=0
NPM_OK=false
while [[ $WAIT -lt 90 ]]; do
  if curl -sf http://localhost:81/api/health -o /dev/null 2>/dev/null; then
    NPM_OK=true
    break
  fi
  printf "."
  sleep 5
  WAIT=$((WAIT + 5))
done

if [[ "$NPM_OK" == true ]]; then
  msg_ok "NPM responding on :81"
else
  printf "\n"
  msg_warn "NPM not yet healthy — may still be initializing. Check: docker logs npm -f"
fi

# ─── Final Summary ────────────────────────────────────────────────────────────
CT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
KA_STATE=$(systemctl is-active keepalived 2>/dev/null || echo "unknown")
echo ""
printf "${BOLD}  Install complete — %s${CL}\n" "$ROLE"
printf "${TAB}• Node IP:    ${GN}%s${CL}\n" "$CT_IP"
printf "${TAB}• NPM Admin:  ${GN}http://%s:81${CL}\n" "$CT_IP"
printf "${TAB}• keepalived: %s\n" "$KA_STATE"
printf "${TAB}• Status:     npm-ha-status\n"
if [[ "$ROLE" == "MASTER" ]]; then
  printf "${TAB}• Sync:       npm-ha-sync  (cron every %s min)\n" "$SYNC_INTERVAL"
fi
echo ""
