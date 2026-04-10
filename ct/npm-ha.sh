#!/usr/bin/env bash
# Nginx Proxy Manager HA LXC Creator
# Run on each Proxmox host separately — choose MASTER or BACKUP role.
# Set up MASTER first, then use the displayed SSH key when setting up BACKUP.
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ─── Colors & Icons ──────────────────────────────────────────────────────────
YW="\033[33m"; YWB="\033[93m"; BL="\033[36m"; RD="\033[01;31m"
BGN="\033[4;92m"; GN="\033[1;92m"; DGN="\033[32m"; CL="\033[m"
BOLD="\033[1m"; BFR="\\r\\033[K"
TAB="  "; TAB3="      "
CM="${TAB}✔${TAB}"; CROSS="${TAB}✖${TAB}"
INFO="${TAB}💡${TAB}"; CREATING="${TAB}🚀${TAB}"
GATEWAY="${TAB}🌐${TAB}"; SHIELD="${TAB}🛡 ${TAB}"

# ─── Message Functions ────────────────────────────────────────────────────────
msg_info()  { printf " ${BOLD}${YW}%-45s${CL}" "$1"; }
msg_ok()    { printf "${BFR}${CM}${GN}%s${CL}\n" "$1"; }
msg_error() { printf "${BFR}${CROSS}${RD}%s${CL}\n" "$1" >&2; exit 1; }
msg_warn()  { printf "\n${INFO}${YWB}%s${CL}\n" "$1"; }
msg_title() { printf "\n${BOLD}${BL}%s${CL}\n" "$1"; }
divider()   { printf "${DGN}%s${CL}\n" "$(printf '─%.0s' {1..60})"; }

header_info() {
  clear
  printf "${BL}"
  cat <<'BANNER'
  ███╗   ██╗██████╗ ███╗   ███╗    ██╗  ██╗ █████╗
  ████╗  ██║██╔══██╗████╗ ████║    ██║  ██║██╔══██╗
  ██╔██╗ ██║██████╔╝██╔████╔██║    ███████║███████║
  ██║╚██╗██║██╔═══╝ ██║╚██╔╝██║    ██╔══██║██╔══██║
  ██║ ╚████║██║     ██║ ╚═╝ ██║    ██║  ██║██║  ██║
  ╚═╝  ╚═══╝╚═╝     ╚═╝     ╚═╝    ╚═╝  ╚═╝╚═╝  ╚═╝
BANNER
  printf "${CL}"
  printf "${BOLD}  Nginx Proxy Manager · High Availability · keepalived VRRP${CL}\n\n"
}

# ─── Prereqs ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -ne 0 ]] && { echo "Must be run as root."; exit 1; }
command -v pct   &>/dev/null || { echo "pct not found — run this on a Proxmox host."; exit 1; }
command -v pvesm &>/dev/null || { echo "pvesm not found — run this on a Proxmox host."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/../install/npm-ha-install.sh"
[[ -f "$INSTALL_SCRIPT" ]] || msg_error "Install script not found: $INSTALL_SCRIPT"

header_info

# ─── Role Selection ───────────────────────────────────────────────────────────
msg_title "Role"
echo ""
printf "${TAB}[1] MASTER — holds the VIP on startup, runs config sync to backup\n"
printf "${TAB}[2] BACKUP — takes the VIP automatically if master goes down\n"
echo ""
printf "${TAB}${BOLD}Set up MASTER first.${CL} You will need the SSH key it generates\n"
printf "${TAB}when running this script on the backup server.\n\n"
read -rp "${TAB3}Role [1]: " ROLE_CHOICE
ROLE_CHOICE="${ROLE_CHOICE:-1}"
case "$ROLE_CHOICE" in
  1) ROLE="MASTER" ;;
  2) ROLE="BACKUP" ;;
  *) msg_error "Invalid choice." ;;
esac
printf "${TAB}Role: ${BOLD}${GN}%s${CL}\n" "$ROLE"

# ─── Storage Selection ───────────────────────────────────────────────────────
msg_title "Storage"
echo ""
mapfile -t STORAGES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $2=="active" {print $1}')
if [[ ${#STORAGES[@]} -eq 0 ]]; then
  mapfile -t STORAGES < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}')
fi
if [[ ${#STORAGES[@]} -eq 1 ]]; then
  STORAGE="${STORAGES[0]}"
  printf "${TAB}Using storage: ${BOLD}${GN}${STORAGE}${CL}\n"
else
  for i in "${!STORAGES[@]}"; do
    printf "${TAB}[%d] %s\n" $((i+1)) "${STORAGES[$i]}"
  done
  read -rp "${TAB3}Select storage [1]: " ST_IDX
  ST_IDX="${ST_IDX:-1}"
  STORAGE="${STORAGES[$((ST_IDX-1))]}"
fi

TMPL_STORAGE=$(pvesm status --content vztmpl 2>/dev/null \
  | awk 'NR>1 && $2=="active" {print $1}' | head -1)
[[ -z "$TMPL_STORAGE" ]] && TMPL_STORAGE="local"

# ─── HA Configuration ────────────────────────────────────────────────────────
msg_title "High Availability Configuration"
echo ""
printf "${TAB}${BOLD}Note:${CL} Static IPs are required. The VIP must be on the same subnet\n"
printf "${TAB}as both nodes but not assigned to either. Uses ${BOLD}unicast VRRP${CL}.\n\n"
printf "${TAB}Use the same values on both servers.\n\n"

read -rp "${TAB3}Virtual IP with prefix   [e.g. 192.168.1.100/24]: " var_vip
[[ -z "$var_vip" ]]       && msg_error "VIP is required."
[[ "$var_vip" =~ "/" ]]   || msg_error "VIP must include prefix length (e.g. 192.168.1.100/24)"

read -rp "${TAB3}VRRP network interface   [eth0]: " var_vip_iface
var_vip_iface="${var_vip_iface:-eth0}"

read -rp "${TAB3}VRRP virtual router ID   [51]: " var_vrrp_id
var_vrrp_id="${var_vrrp_id:-51}"

read -rp "${TAB3}VRRP auth password: " var_vrrp_pass
[[ -z "$var_vrrp_pass" ]] && msg_error "VRRP password is required (must match on both nodes)."

if [[ "$ROLE" == "MASTER" ]]; then
  read -rp "${TAB3}Config sync interval     [30 min]: " var_sync_interval
  var_sync_interval="${var_sync_interval:-30}"
fi

# ─── Container Settings ───────────────────────────────────────────────────────
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
GW_DEFAULT=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')

if [[ "$ROLE" == "MASTER" ]]; then
  DEFAULT_HOSTNAME="npm-primary"
else
  DEFAULT_HOSTNAME="npm-backup"
fi

msg_title "Container Settings"
echo ""
read -rp "${TAB3}Container ID     [${NEXT_ID}]: "        var_ctid;     var_ctid="${var_ctid:-$NEXT_ID}"
read -rp "${TAB3}Hostname         [${DEFAULT_HOSTNAME}]: " var_hostname; var_hostname="${var_hostname:-$DEFAULT_HOSTNAME}"
read -rp "${TAB3}CPU cores        [2]: "                   var_cores;    var_cores="${var_cores:-2}"
read -rp "${TAB3}RAM (MB)         [512]: "                 var_ram;      var_ram="${var_ram:-512}"
read -rp "${TAB3}Disk (GB)        [8]: "                   var_disk;     var_disk="${var_disk:-8}"
read -rp "${TAB3}Network bridge   [vmbr0]: "               var_bridge;   var_bridge="${var_bridge:-vmbr0}"
read -rp "${TAB3}This node IP (x.x.x.x/24): "             var_own_ip
[[ -z "$var_own_ip" ]]      && msg_error "Node IP is required."
[[ "$var_own_ip" =~ "/" ]]  || msg_error "IP must include prefix (e.g. 192.168.1.21/24)"
read -rp "${TAB3}Peer node IP (bare, no prefix): "        var_peer_ip
[[ -z "$var_peer_ip" ]]     && msg_error "Peer IP is required."
read -rp "${TAB3}Gateway          [${GW_DEFAULT}]: "      var_gw;       var_gw="${var_gw:-$GW_DEFAULT}"
read -rp "${TAB3}DNS nameserver   [1.1.1.1]: "            var_dns;      var_dns="${var_dns:-1.1.1.1}"

# BACKUP: collect the primary's SSH pubkey
if [[ "$ROLE" == "BACKUP" ]]; then
  echo ""
  printf "${TAB}${BOLD}Primary SSH sync key:${CL}\n"
  printf "${TAB}Paste the key shown at the end of the MASTER setup (single line).\n"
  printf "${TAB}It starts with ${BOLD}ssh-ed25519${CL}.\n\n"
  read -rp "${TAB3}Primary pubkey: " var_primary_pubkey
  [[ -z "$var_primary_pubkey" ]]                  && msg_error "Primary SSH key is required."
  [[ "$var_primary_pubkey" =~ ^ssh-ed25519[[:space:]] ]] || msg_warn "Key doesn't look like an ed25519 key — double-check it."
fi

OWN_IP_BARE="${var_own_ip%%/*}"

# ─── Confirm ─────────────────────────────────────────────────────────────────
echo ""
divider
printf "${BOLD}  NPM HA — Configuration Summary${CL}\n"
divider
printf "${TAB}Role:           ${BOLD}${GN}%s${CL}\n" "$ROLE"
printf "${TAB}Virtual IP:     ${BOLD}%s${CL}  (VRRP ID: %s)\n" "$var_vip" "$var_vrrp_id"
printf "${TAB}Interface:      ${BOLD}%s${CL}\n" "$var_vip_iface"
if [[ "$ROLE" == "MASTER" ]]; then
  printf "${TAB}Sync interval:  every ${BOLD}%s min${CL} → peer\n" "$var_sync_interval"
fi
echo ""
printf "${TAB}CTID:     ${BOLD}%s${CL}  Hostname: ${BOLD}%s${CL}\n" "$var_ctid" "$var_hostname"
printf "${TAB}Storage:  ${BOLD}%s${CL}  OS: Ubuntu 24.04 (privileged)\n" "$STORAGE"
printf "${TAB}Cores:    ${BOLD}%s${CL}  RAM: ${BOLD}%s MB${CL}  Disk: ${BOLD}%s GB${CL}\n" "$var_cores" "$var_ram" "$var_disk"
printf "${TAB}Own IP:   ${BOLD}%s${CL}  Peer IP: ${BOLD}%s${CL}\n" "$var_own_ip" "$var_peer_ip"
printf "${TAB}Gateway:  ${BOLD}%s${CL}  DNS: ${BOLD}%s${CL}\n" "$var_gw" "$var_dns"
divider
echo ""
read -rp "  Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ─── Template ─────────────────────────────────────────────────────────────────
msg_info "Fetching available templates"
pveam update &>/dev/null || true
TEMPLATE=$(pveam available --section system 2>/dev/null \
  | awk '/ubuntu-24.04-standard/ {print $2}' | sort -V | tail -1)
[[ -z "$TEMPLATE" ]] && msg_error "ubuntu-24.04-standard template not found. Run: pveam update"
msg_ok "Template: $TEMPLATE"

msg_info "Downloading template (if needed)"
if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "${TEMPLATE}"; then
  pveam download "$TMPL_STORAGE" "$TEMPLATE" || msg_error "Template download failed"
fi
msg_ok "Template ready"

# ─── Create Container ─────────────────────────────────────────────────────────
msg_info "Creating container ${var_ctid}"
pct create "$var_ctid" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$var_hostname" \
  --cores "$var_cores" \
  --memory "$var_ram" \
  --swap 0 \
  --rootfs "${STORAGE}:${var_disk}" \
  --net0 "name=eth0,bridge=${var_bridge},ip=${var_own_ip},gw=${var_gw}" \
  --nameserver "$var_dns" \
  --unprivileged 0 \
  --features nesting=1 \
  --ostype ubuntu \
  --onboot 1 &>/dev/null
msg_ok "Container created (CTID ${var_ctid})"

msg_info "Starting container"
pct start "$var_ctid"
sleep 5
for i in {1..30}; do
  pct exec "$var_ctid" -- hostname &>/dev/null && break
  sleep 2
done
msg_ok "Container started"

# ─── Push Config & Install ────────────────────────────────────────────────────
msg_info "Pushing install configuration"

SYNC_INTERVAL_VAL="${var_sync_interval:-30}"

cat > /tmp/npm-ha-config.sh <<ENVEOF
export ROLE="${ROLE}"
export OWN_IP="${OWN_IP_BARE}"
export PEER_IP="${var_peer_ip}"
export VIP="${var_vip}"
export VIP_IFACE="${var_vip_iface}"
export VRRP_ID="${var_vrrp_id}"
export VRRP_PASS="${var_vrrp_pass}"
export SYNC_INTERVAL="${SYNC_INTERVAL_VAL}"
ENVEOF

pct push "$var_ctid" /tmp/npm-ha-config.sh /root/install-config.sh
pct push "$var_ctid" "$INSTALL_SCRIPT" /root/install.sh
rm /tmp/npm-ha-config.sh

if [[ "$ROLE" == "BACKUP" ]]; then
  printf '%s\n' "$var_primary_pubkey" > /tmp/npm-ha-sync.pub
  pct push "$var_ctid" /tmp/npm-ha-sync.pub /root/npm-ha-sync.pub
  rm /tmp/npm-ha-sync.pub
fi

msg_ok "Configuration pushed"

printf "\n"
pct exec "$var_ctid" -- bash -c "source /root/install-config.sh && bash /root/install.sh"

# ─── Summary ─────────────────────────────────────────────────────────────────
VIP_BARE="${var_vip%%/*}"
CT_IP=$(pct exec "$var_ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "$OWN_IP_BARE")

echo ""
divider
printf "${CREATING}${GN}${BOLD}  NPM HA ${ROLE} — Build Complete!${CL}\n"
divider

printf "\n${BOLD}  Access:${CL}\n"
printf "${GATEWAY}NPM Admin: ${BGN}http://%s:81${CL}  (direct)\n" "$CT_IP"
printf "${GATEWAY}Via VIP:   ${BGN}http://%s:81${CL}  (after both nodes are up)\n" "$VIP_BARE"
if [[ "$ROLE" == "MASTER" ]]; then
  printf "${TAB}Default login: ${BOLD}admin@example.com${CL} / ${BOLD}changeme${CL}\n"
  printf "${TAB}${YWB}Change the admin password immediately after first login.${CL}\n"
fi

printf "\n${BOLD}  Management:${CL}\n"
printf "${TAB}Status:          pct exec %s -- npm-ha-status\n" "$var_ctid"
printf "${TAB}NPM logs:        pct exec %s -- docker logs npm -f\n" "$var_ctid"
printf "${TAB}keepalived logs: pct exec %s -- journalctl -u keepalived -f\n" "$var_ctid"
if [[ "$ROLE" == "MASTER" ]]; then
  printf "${TAB}Force sync:      pct exec %s -- npm-ha-sync\n" "$var_ctid"
  printf "${TAB}Test failover:   pct stop %s  (VIP moves to backup)\n" "$var_ctid"
fi

if [[ "$ROLE" == "MASTER" ]]; then
  SYNC_KEY=$(pct exec "$var_ctid" -- cat /root/.ssh/npm_ha_sync.pub 2>/dev/null || echo "(unavailable)")
  echo ""
  divider
  printf "${SHIELD}${BOLD}  Next step: set up the BACKUP node${CL}\n"
  divider
  printf "\n${TAB}Run ${BOLD}bash ct/npm-ha.sh${CL} on the backup server and choose role ${BOLD}BACKUP${CL}.\n"
  printf "${TAB}When prompted for the primary SSH key, paste this:\n\n"
  printf "${GN}%s${CL}\n\n" "$SYNC_KEY"
  printf "${TAB}Use the same VIP, VRRP ID, and password as configured here.\n"
  divider
fi

echo ""
