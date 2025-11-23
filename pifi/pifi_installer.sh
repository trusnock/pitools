sudo tee /usr/local/bin/piwifi >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

IFACE="${IFACE:-wlan0}"
NM_CONF="/etc/NetworkManager/NetworkManager.conf"
NM_DIR="/etc/NetworkManager/system-connections"

exists(){ command -v "$1" >/dev/null 2>&1; }
act(){ systemctl is-active --quiet "$1"; }

detect_controller() {
  local nm_raw="" mgr="unknown" reason=""
  if act NetworkManager && exists nmcli; then
    nm_raw="$(nmcli -t -f DEVICE,STATE,CONNECTION d 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $2":"$3}')"
    case "$nm_raw" in
      connected:*)  mgr="NetworkManager"; reason="NetworkManager active; $IFACE is $nm_raw";;
      connecting:*) mgr="NetworkManager"; reason="NetworkManager active; $IFACE is $nm_raw";;
      *) : ;;
    esac
  fi
  if [[ "$mgr" == "unknown" ]] && act iwd;            then mgr="iwd";            reason="iwd active"; fi
  if [[ "$mgr" == "unknown" ]] && act wpa_supplicant; then mgr="wpa_supplicant"; reason="wpa_supplicant active"; fi
  if [[ "$mgr" == "unknown" ]] && act connman;        then mgr="connman";        reason="connman active"; fi
  printf "%s|%s\n" "$mgr" "$reason"
}

discover_dns() {
  local dns=""
  if act NetworkManager && exists nmcli; then
    dns="$(nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | sed '/^$/d' | paste -sd, - || true)"
  fi
  if [[ -z "$dns" ]] && exists resolvectl; then
    dns="$(resolvectl dns "$IFACE" 2>/dev/null | awk '{for(i=2;i<=NF;i++)print $i}' | paste -sd, - || true)"
    [[ -z "$dns" ]] && dns="$(resolvectl status 2>/dev/null | awk '/^\s*DNS Servers:/{for(i=3;i<=NF;i++)print $i}' | paste -sd, - || true)"
  fi
  [[ -z "$dns" && -r /run/NetworkManager/resolv.conf ]] && dns="$(awk '/^[[:space:]]*nameserver/{print $2}' /run/NetworkManager/resolv.conf | paste -sd, -)"
  [[ -z "$dns" && -r /etc/resolv.conf ]] && dns="$(awk '/^[[:space:]]*nameserver/{print $2}' /etc/resolv.conf | paste -sd, -)"
  echo "${dns:-none}"
}

report_nm_saved_all() {
  nmcli -t -f NAME,UUID,TYPE,DEVICE,ACTIVE connection show 2>/dev/null | \
  awk -F: '$3 ~ /^(wifi|802-11-wireless)$/ {
    printf "- %s (uuid:%s, dev:%s, active:%s)\n",$1,$2,$4,$5
  }' || true
}

report_nm_saved_inactive() {
  nmcli -t -f NAME,UUID,TYPE,DEVICE,ACTIVE connection show 2>/dev/null | \
  awk -F: -v IFACE="$IFACE" '$3 ~ /^(wifi|802-11-wireless)$/ && ($4 != IFACE || $5 != "yes") {
    printf "- %s (uuid:%s)\n",$1,$2
  }' || true
}

report_keyfiles_unloaded() {
  local loaded
  loaded="$(nmcli -t -f UUID connection show 2>/dev/null | tr -d '\r')"
  local any=0
  for f in "$NM_DIR"/*.nmconnection; do
    [[ -f "$f" ]] || continue
    local uuid
    uuid="$(awk -F= '/^uuid/{print $2}' "$f" 2>/dev/null | tr -d '\r')"
    [[ -z "$uuid" ]] && continue
    if ! grep -q "$uuid" <<<"$loaded"; then
      echo "- $(basename "$f")"
      any=1
    fi
  done
  [[ $any -eq 0 ]] && echo "none"
}

report() {
  local ctrl reason; IFS='|' read -r ctrl reason < <(detect_controller)
  local link ip4 gw dns ssid nm_line
  link="$(iw "$IFACE" link 2>/dev/null || true)"
  [[ -z "$link" ]] && link="(iw not available or $IFACE down)"
  ip4="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | paste -sd, - || true)"
  gw="$(ip route show default 2>/dev/null | awk '/default/ && /'"$IFACE"'/ {print $3}' | head -n1)"
  ssid="$(printf "%s" "$link" | awk -F': ' '/SSID:/{print $2; exit}')"
  dns="$(discover_dns)"
  if act NetworkManager && exists nmcli; then
    nm_line="$(nmcli -t -f DEVICE,STATE,CONNECTION d 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $0}')"
  fi

  echo "Wi-Fi control report for $IFACE"
  echo "Controller: $ctrl"
  [[ -n "$reason" ]] && echo "Reason: $reason"
  [[ -n "$nm_line" ]] && echo "NM device line: $nm_line"
  echo "SSID: ${ssid:-unknown}"
  echo "IPv4: ${ip4:-none}"
  echo "Gateway: ${gw:-none}"
  echo "DNS: $dns"
  echo "iw link:"
  echo "$link"

  echo "All saved Wi-Fi connections:"
  case "$ctrl" in
    NetworkManager) report_nm_saved_all || echo "none" ;;
    wpa_supplicant)
      [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]] &&
      awk 'BEGIN{RS="network=";FS="\n"}
        { ss="";pr="";dis="";
          if (match($0,/ssid="([^"]+)"/,m)) ss=m[1];
          if (match($0,/priority=([0-9]+)/,m)) pr=m[1]; else pr="0";
          if (match($0,/disabled=([0-9]+)/,m)) dis=m[1]; else dis="";
          if (ss!=""){ ac=(dis==""||dis=="0")?"yes":"no";
            printf("- %s (autoconnect:%s, priority:%s)\n",ss,ac,pr);
          }
        }' /etc/wpa_supplicant/wpa_supplicant.conf || echo "none"
      ;;
    iwd)
      if exists iwctl; then iwctl known-networks list 2>/dev/null | awk 'NR>1{print "- "$1}' || echo "none"
      else [[ -d /var/lib/iwd ]] && ls -1 /var/lib/iwd/*.psk 2>/dev/null | sed 's#.*/#- #' | sed 's/\.psk$//' || echo "none"; fi
      ;;
    *) echo "none";;
  esac

  if [[ "$ctrl" = "NetworkManager" ]]; then
    echo "Configured (not active on $IFACE):"
    report_nm_saved_inactive || echo "none"

    echo "Keyfiles present but NOT loaded by NM:"
    report_keyfiles_unloaded
  fi

  ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && ip_ok=ok || ip_ok=fail
  ping -c1 -W1 google.com >/dev/null 2>&1 && dns_ok=ok || dns_ok=fail
  echo "Connectivity: ping IP=$ip_ok, DNS+IP=$dns_ok"
}

usage() {
  cat <<USAGE
Usage: piwifi <command> [args]

Commands:
  report                 Show controller, link/IP/DNS, and saved networks
  add <SSID> <PSK>       Add a Wi-Fi network
  fix-nm                 Enable NM keyfile + managed=true, restart NM
  adopt                  Stop external owners and hand iface to NM
  prune <NAME|UUID>      Delete an NM Wi-Fi profile
  rename-current         Rename "preconfigured" to current SSID
  help, --help           Show this help

Env:
  IFACE=wlan0 (default)
USAGE
}

rename_current() {
  local cur ssid
  ssid="$(iw "$IFACE" link 2>/dev/null | awk -F': ' '/SSID:/{print $2; exit}')"
  cur="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v i="$IFACE" '$2==i{print $1; exit}')"
  [[ -n "$cur" && "$cur" == "preconfigured" && -n "$ssid" ]] && nmcli connection modify "$cur" connection.id "$ssid"
  report
}

cmd="${1:-help}"
case "$cmd" in
  report) report ;;
  add) shift; [[ $# -ge 2 ]] || { echo "need SSID and PSK"; exit 1; }; nmcli dev wifi connect "$1" password "$2" ifname "$IFACE" || nmcli con add type wifi ifname "$IFACE" con-name "$1" ssid "$1" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$2"; report ;;
  fix-nm) sudo sed -i '/^\[ifupdown\]/,/^\[/!b;/^\[/!d;a managed=true' "$NM_CONF"; sudo systemctl restart NetworkManager; report ;;
  adopt) sudo systemctl disable --now wpa_supplicant@${IFACE} >/dev/null 2>&1 || true; sudo systemctl disable --now iwd >/dev/null 2>&1 || true; nmcli device set "$IFACE" managed yes; sudo systemctl restart NetworkManager; report ;;
  prune) shift; [[ $# -ge 1 ]] || { echo "need NAME or UUID"; exit 1; }; nmcli con delete "$1"; report ;;
  rename-current) rename_current ;;
  help|--help|-h|"") usage ;;
  *) usage; exit 1 ;;
esac
EOF
sudo chmod +x /usr/local/bin/piwifi

