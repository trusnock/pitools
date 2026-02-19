sudo tee /usr/local/bin/piwifi >/dev/null <<'EOF'
#!/bin/bash
# =============================================================================
# piwifi - Wi-Fi Network Manager Control Script
# =============================================================================
# PURPOSE:
#   This script provides a unified interface to manage Wi-Fi connections
#   across multiple Linux network managers (NetworkManager, iwd, wpa_supplicant,
#   connman). It allows users to add networks, switch managers, and diagnose
#   connectivity issues.
#
# SUPPORTED MANAGERS:
#   - NetworkManager: Primary manager for most modern Linux distributions
#   - iwd: Intel Wireless Daemon (newer, faster alternative)
#   - wpa_supplicant: Legacy wireless daemon
#   - connman: ConnMan connection manager
#
# USAGE:
#   piwifi <command> [args]
#   IFACE=wlan1 piwifi report    (specify network interface)
#
# ENVIRONMENT:
#   IFACE: Network interface name (default: wlan0)
#
# DATE CREATED:
#   2026-02-19 02:46:21 UTC
#
# =============================================================================

set -euo pipefail

# Configuration variables
IFACE="${IFACE:-wlan0}"                                    # Network interface to manage
NM_CONF="/etc/NetworkManager/NetworkManager.conf"          # NetworkManager config file
NM_DIR="/etc/NetworkManager/system-connections"            # Directory storing NM profiles

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# exists()
# PURPOSE: Check if a command is available in the system PATH
# PARAMETERS:
#   $1: Command name to search for
# RETURNS:
#   0 (success) if command exists, 1 (failure) if not found
# EXAMPLE:
#   if exists nmcli; then echo "NetworkManager CLI found"; fi
exists() {
  command -v "$1" >/dev/null 2>&1
}

# act()
# PURPOSE: Check if a systemd service is currently active (running)
# PARAMETERS:
#   $1: Service name (e.g., 'NetworkManager', 'iwd')
# RETURNS:
#   0 (success) if service is active, 1 (failure) if not
# EXAMPLE:
#   if act NetworkManager; then echo "NetworkManager is running"; fi
act() {
  systemctl is-active --quiet "$1"
}

# =============================================================================
# CONTROLLER DETECTION FUNCTION
# =============================================================================

# detect_controller()
# PURPOSE: Identify which network manager is currently controlling the interface
# STRATEGY:
#   The function checks managers in this order:
#   1. NetworkManager (most common, has detailed state info via nmcli)
#   2. iwd (modern replacement, faster)
#   3. wpa_supplicant (legacy daemon, widely compatible)
#   4. connman (alternative manager, less common)
#
# OUTPUT FORMAT:
#   Prints pipe-separated values: MANAGER_NAME|REASON
#   Example: "NetworkManager|NetworkManager active; wlan0 is connected:MyWiFi"
#
# RETURNS:
#   0 on success (always succeeds, may report 'unknown' manager)
detect_controller() {
  local nm_raw="" mgr="unknown" reason=""
  
  # Check if NetworkManager is active and nmcli command is available
  if act NetworkManager && exists nmcli; then
    # Query NetworkManager for device state using nmcli
    # -t: terse output (parseable format)
    # -f: specify fields to return (DEVICE, STATE, CONNECTION)
    # d: shorthand for "device"
    # awk: extract the state (field 2) and connection name (field 3) for our interface
    nm_raw=""$(nmcli -t -f DEVICE,STATE,CONNECTION d 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $2":"$3}')""
    
    # Match against known NetworkManager states
    case "$nm_raw" in
      connected:*)  mgr="NetworkManager"; reason="NetworkManager active; $IFACE is $nm_raw";;
      connecting:*) mgr="NetworkManager"; reason="NetworkManager active; $IFACE is $nm_raw";;
      *) : ;;  # No match, continue checking other managers
    esac
  fi
  
  # Check remaining managers only if NetworkManager wasn't found managing this interface
  if [[ "$mgr" == "unknown" ]] && act iwd;            then mgr="iwd";            reason="iwd active"; fi
  if [[ "$mgr" == "unknown" ]] && act wpa_supplicant; then mgr="wpa_supplicant"; reason="wpa_supplicant active"; fi
  if [[ "$mgr" == "unknown" ]] && act connman;        then mgr="connman";        reason="connman active"; fi
  
  # Output result in pipe-separated format for easy parsing
  printf "%s|%s\n" "$mgr" "$reason"
}

# =============================================================================
# DNS DISCOVERY FUNCTION
# =============================================================================

# discover_dns()
# PURPOSE: Locate DNS servers configured for the network interface
# STRATEGY (Fallback Chain):
#   Attempts multiple methods in order until DNS servers are found:
#   1. NetworkManager's nmcli (most reliable when NM is active)
#   2. systemd's resolvectl (modern resolver, provides interface-specific DNS)
#   3. NetworkManager's resolv.conf (if NM manages resolution)
#   4. System's resolv.conf (global fallback)
#
# OUTPUT:
#   Comma-separated list of DNS server IPs, or "none" if not found
# EXAMPLE:
#   8.8.8.8,8.8.4.4
discover_dns() {
  local dns=""
  
  # Method 1: Try NetworkManager's nmcli (most direct if NM is active)
  if act NetworkManager && exists nmcli; then
    # Query DNS servers configured for this interface
    # -g: parseable output (gettext format)
    # IP4.DNS: field for IPv4 DNS servers
    # device show: get device-specific configuration
    dns="$(nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | sed '/^$/d' | paste -sd, - || true)"
  fi
  
  # Method 2: Try systemd's resolvectl (modern resolver tool)
  if [[ -z "$dns" ]] && exists resolvectl; then
    # Get DNS servers for this specific interface
    dns="$(resolvectl dns "$IFACE" 2>/dev/null | awk '{for(i=2;i<=NF;i++)print $i}' | paste -sd, - || true)"
    
    # Fallback: Get global DNS servers if interface-specific not found
    [[ -z "$dns" ]] && dns="$(resolvectl status 2>/dev/null | awk '/^\s*DNS Servers:/{for(i=3;i<=NF;i++)print $i}' | paste -sd, - || true)"
  fi
  
  # Method 3: Try NetworkManager's resolv.conf backup file
  [[ -z "$dns" && -r /run/NetworkManager/resolv.conf ]] && dns="$(awk '/^[[:space:]]*nameserver/{print $2}' /run/NetworkManager/resolv.conf | paste -sd, -)"
  
  # Method 4: Fall back to system's resolv.conf (global configuration)
  [[ -z "$dns" && -r /etc/resolv.conf ]] && dns="$(awk '/^[[:space:]]*nameserver/{print $2}' /etc/resolv.conf | paste -sd, -)"
  
  # Output result with fallback to "none"
  echo "${dns:-none}"
}

# =============================================================================
# REPORT HELPER FUNCTIONS (NetworkManager specific)
# =============================================================================

# report_nm_saved_all()
# PURPOSE: List all saved Wi-Fi connections managed by NetworkManager
# OUTPUT FORMAT:
#   - Connection Name (uuid:..., dev:..., active:yes|no)
# FILTERS:
#   Only shows connections of type wifi or 802-11-wireless
report_nm_saved_all() {
  nmcli -t -f NAME,UUID,TYPE,DEVICE,ACTIVE connection show 2>/dev/null | \
  awk -F: '$3 ~ /^(wifi|802-11-wireless)$/ {
    printf "- %s (uuid:%s, dev:%s, active:%s)\n",$1,$2,$4,$5
  }' || true
}

# report_nm_saved_inactive()
# PURPOSE: List Wi-Fi connections saved in NetworkManager but NOT currently active
# USAGE:
#   Shows profiles that could be used but aren't running on this interface
# FILTERS:
#   Wi-Fi type + (not on current interface OR not active)
report_nm_saved_inactive() {
  nmcli -t -f NAME,UUID,TYPE,DEVICE,ACTIVE connection show 2>/dev/null | \
  awk -F: -v IFACE="$IFACE" '$3 ~ /^(wifi|802-11-wireless)$/ && ($4 != IFACE || $5 != "yes") {
    printf "- %s (uuid:%s)\n",$1,$2
  }' || true
}

# report_keyfiles_unloaded()
# PURPOSE: Identify NetworkManager keyfiles (.nmconnection) that exist but aren't loaded
# DIAGNOSTIC VALUE:
#   Finds orphaned profiles that NetworkManager didn't pick up (corruption, permission issues)
# LOGIC:
#   1. Get list of all loaded connection UUIDs from nmcli
#   2. Scan all .nmconnection files in NM_DIR
#   3. For each file, extract its UUID
#   4. If UUID not in loaded list, report the file as unloaded
report_keyfiles_unloaded() {
  local loaded
  # Get all currently loaded connection UUIDs from NetworkManager
  loaded="$(nmcli -t -f UUID connection show 2>/dev/null | tr -d '\r')"
  local any=0
  
  # Check each .nmconnection file in the NM system-connections directory
  for f in "$NM_DIR"/*.nmconnection; do
    [[ -f "$f" ]] || continue  # Skip if not a regular file
    
    local uuid
    # Extract UUID from keyfile (format: uuid=<uuid-string>)
    uuid="$(awk -F= '/^uuid/{print $2}' "$f" 2>/dev/null | tr -d '\r')"
    [[ -z "$uuid" ]] && continue  # Skip if UUID not found
    
    # Check if this UUID is in the loaded list
    if ! grep -q "$uuid" <<<"$loaded"; then
      echo "- $(basename "$f")"
      any=1
    fi
  done
  
  # Report "none" if all keyfiles are loaded
  [[ $any -eq 0 ]] && echo "none"
}

# =============================================================================
# MAIN REPORT FUNCTION
# =============================================================================

# report()
# PURPOSE: Generate comprehensive diagnostic report of Wi-Fi configuration and status
# OUTPUT:
#   - Detected network manager and why
#   - Current interface state (SSID, IP, gateway, DNS)
#   - List of all saved connections
#   - Connectivity tests (ping to IP and DNS)
report() {
  # Detect which manager is controlling this interface
  local ctrl reason
  IFS='|' read -r ctrl reason < <(detect_controller)
  
  # Gather current interface information
  local link ip4 gw dns ssid nm_line  
  
  # Get detailed wireless link information (SSID, signal strength, etc.)
  link="$(iw "$IFACE" link 2>/dev/null || true)"
  [[ -z "$link" ]] && link="(iw not available or $IFACE down)"
  
  # Get IPv4 addresses assigned to this interface
  ip4="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | paste -sd, - || true)"
  
  # Get default gateway (typically found on the default route)
  gw="$(ip route show default 2>/dev/null | awk '/default/ && /'