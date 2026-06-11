#!/usr/bin/env bash

BASE_DIR=$(realpath "$(dirname "$0")")
CMD_NAME="aws-vpn-client"

CMD_BIN="$BASE_DIR/build/$CMD_NAME"
OPENVPN_BIN="$BASE_DIR/build/openvpn-glibc"
OPENVPN_CONF="$BASE_DIR/build/ovpn.conf"

# DNS handling differs by OS:
#  - macOS: use OpenVPN's official scutil-based dns-updown script (driven by the
#    server-pushed DNS), instead of the legacy /etc/resolv.conf up/down scripts.
#  - Linux: use the resolv.conf (or resolvconf) up/down scripts.
DNS_UPDOWN=""
VPN_CLIENT_UP=""
VPN_CLIENT_DOWN=""
if [[ "$(uname)" == "Darwin" ]]; then
  DNS_UPDOWN="$BASE_DIR/connect/macos-dns-updown.sh"
else
  VPN_CLIENT_UP="$BASE_DIR/connect/vpn-client.up"
  VPN_CLIENT_DOWN="$BASE_DIR/connect/vpn-client.down"
fi

function parse_option_arg() {
  if [[ -n "${2-}" ]] && [[ ${2:0:1} != "-" ]]; then
    echo "$2"
  else
    echo "Argument for $1 is missing"
    exit 1
  fi
}

function parse_args() {
  while (( "$#" )); do
    case "$1" in
      --cmd)
        CMD_BIN=$(parse_option_arg "$@")
        shift 2
        ;;
      --ovpn)
        OPENVPN_BIN=$(parse_option_arg "$@")
        shift 2
        ;;
      --conf)
        OPENVPN_CONF=$(parse_option_arg "$@")
        shift 2
        ;;
      --up)
        VPN_CLIENT_UP=$(parse_option_arg "$@")
        shift 2
        ;;
      --down)
        VPN_CLIENT_DOWN=$(parse_option_arg "$@")
        shift 2
        ;;
      --dns-updown)
        DNS_UPDOWN=$(parse_option_arg "$@")
        shift 2
        ;;
    esac
  done
}

function main() {
  parse_args "$@"
  debug
  connect
}

function debug() {
  echo "Connecting to AWS VPN using:"
  echo "CMD_BIN=$CMD_BIN"
  echo "OPENVPN_BIN=$OPENVPN_BIN"
  echo "OPENVPN_CONF=$OPENVPN_CONF"
  echo "VPN_CLIENT_UP=$VPN_CLIENT_UP"
  echo "VPN_CLIENT_DOWN=$VPN_CLIENT_DOWN"
  echo "DNS_UPDOWN=$DNS_UPDOWN"
}

function connect() {
  "$CMD_BIN" \
    -ovpn "$OPENVPN_BIN" \
    -config "$OPENVPN_CONF" \
    -verbose \
    2>| "/tmp/$CMD_NAME.log" \
    >| "/tmp/$CMD_NAME.saml"

  REMOTE_IP=$(grep 'Remote IP:' "/tmp/$CMD_NAME.log" | cut -d' ' -f5)

  # Derive the endpoint port from the config (AWS uses 443 or 1194) and strip
  # the config's own remote/remote-random-hostname lines, so OpenVPN connects to
  # the single pinned IP from phase 1. Both SAML phases must hit the same backend
  # instance for the session ID to stay valid.
  REMOTE_PORT=$(grep '^remote ' "$OPENVPN_CONF" | awk '{print $3}' | head -1)
  REMOTE_PORT=${REMOTE_PORT:-443}
  STRIPPED_CONF="$BASE_DIR/build/ovpn.stripped.conf"
  grep -vE '^[[:space:]]*remote |^[[:space:]]*remote-random-hostname' "$OPENVPN_CONF" > "$STRIPPED_CONF"

  sudo_args=(
    --config "$STRIPPED_CONF"
    --remote "$REMOTE_IP" "$REMOTE_PORT"
    --script-security 2
  )

  # macOS: OpenVPN's dns-updown applies the pushed DNS via scutil. Linux: legacy
  # resolv.conf up/down scripts.
  [[ -n "$DNS_UPDOWN" ]]      && sudo_args+=(--dns-updown "$DNS_UPDOWN")
  [[ -n "$VPN_CLIENT_UP" ]]   && sudo_args+=(--up "$VPN_CLIENT_UP")
  [[ -n "$VPN_CLIENT_DOWN" ]] && sudo_args+=(--down "$VPN_CLIENT_DOWN")

  sudo_args+=(
    --route-up "/usr/bin/env rm /tmp/$CMD_NAME.saml"
    --auth-user-pass "/tmp/$CMD_NAME.saml"
  )

  sudo "$OPENVPN_BIN" "${sudo_args[@]}"
}

main "$@"
