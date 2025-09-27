#!/bin/bash
set -euo pipefail

# =============== helpery ===============
ask() { # ask "pytanie" "domyślna"
  local q="$1" d="${2:-}"
  if [[ -n "$d" ]]; then
    read -rp "$q [$d]: " _a || true
    echo "${_a:-$d}"
  else
    read -rp "$q: " _a || true
    echo "$_a"
  fi
}

confirm() { # confirm "pytanie"
  read -rp "$1 [y/N]: " _c || true
  [[ "${_c,,}" == "y" || "${_c,,}" == "yes" ]]
}

# =============== zbieranie danych ===============
echo "=== NAT / DNAT kreator (iptables) ==="

LAN_IF=$(ask "Interfejs LAN (np. eth0/enp0s8)" "eth0")
WAN_IF=$(ask "Interfejs WAN (np. eth1/enp0s3)" "eth1")
LAN_CIDR=$(ask "Podsieć LAN w CIDR (np. 10.0.0.0/24)" "10.0.0.0/24")

echo
DO_MASK=false; DO_SNAT=false; DO_DNAT=false

confirm "Włączyć MASQUERADE dla ${LAN_CIDR} na wyjściu ${WAN_IF}?" && DO_MASK=true
if confirm "Dodać SNAT (statyczny --to-source)?"; then
  DO_SNAT=true
  SNAT_IP=$(ask "Adres źródłowy dla SNAT (--to-source)" "")
fi
if confirm "Konfigurować DNAT (port forwarding)?"; then
  DO_DNAT=true
fi

# opcjonalne reguły FORWARD (gdy polityki nie są ACCEPT)
ADD_FORWARD=false
confirm "Dodać pomocnicze reguły łańcucha FORWARD (zalecane)?" && ADD_FORWARD=true

# zbierz DNAT-y (dowolna liczba)
DNAT_RULES=()
if $DO_DNAT; then
  echo
  echo "Dodawanie reguł DNAT. Zakończ, odpowiadając 'n' na pytanie o 'Dodaj kolejną?'"
  while :; do
    PROTO=$(ask "Protokół (tcp/udp)" "tcp")
    EXT_IF=$(ask "Wejściowy interfejs (zwykle WAN)" "$WAN_IF")
    EXT_IP=$(ask "Adres docelowy na WAN (pozostaw puste aby nie dopasowywać po -d)" "")
    EXT_PORT=$(ask "Port zewnętrzny na WAN (np. 1001)" "")
    DST_IP=$(ask "Adres docelowy w LAN (np. 10.0.0.11)" "")
    DST_PORT=$(ask "Port docelowy w LAN (np. 22/80)" "")

    [[ -z "$EXT_PORT" || -z "$DST_IP" || -z "$DST_PORT" ]] && { echo "⚠️  Port zewn., IP i port docelowy są wymagane — pomiń tę pozycję lub wpisz ponownie."; } || {
      # zbuduj linię DNAT
      if [[ -n "$EXT_IP" ]]; then
        DNAT_RULES+=("iptables -t nat -A PREROUTING -i ${EXT_IF} -p ${PROTO} -d ${EXT_IP} --dport ${EXT_PORT} -j DNAT --to-destination ${DST_IP}:${DST_PORT}")
      else
        DNAT_RULES+=("iptables -t nat -A PREROUTING -i ${EXT_IF} -p ${PROTO} --dport ${EXT_PORT} -j DNAT --to-destination ${DST_IP}:${DST_PORT}")
      fi
      echo "  ✔ dodano DNAT: ${PROTO} :${EXT_PORT} -> ${DST_IP}:${DST_PORT}"
    }

    confirm "Dodać kolejną regułę DNAT?" || break
  done
fi

# =============== generowanie /root/nat.sh ===============
TARGET=/root/nat.sh
echo
echo "➡️  Generuję ${TARGET} …"

{
cat <<'HDR'
#!/bin/bash
set -euo pipefail
# === AUTOMATYCZNIE WYGENEROWANY SKRYPT NAT ===

# włącz routing
echo 1 > /proc/sys/net/ipv4/ip_forward

# czyść bieżące reguły (bez zmian polityk)
iptables -F INPUT || true
iptables -F OUTPUT || true
iptables -F FORWARD || true
iptables -t nat -F POSTROUTING || true
iptables -t nat -F PREROUTING  || true
HDR

# MASQUERADE / SNAT
$DO_MASK && echo "iptables -t nat -A POSTROUTING -s ${LAN_CIDR} -o ${WAN_IF} -j MASQUERADE"
$DO_SNAT  && echo "iptables -t nat -A POSTROUTING -s ${LAN_CIDR} -o ${WAN_IF} -j SNAT --to-source ${SNAT_IP}"

# FORWARD helper
if $ADD_FORWARD; then
  cat <<EOF
# reguły pomocnicze FORWARD
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -s ${LAN_CIDR} -o ${WAN_IF} -j ACCEPT
iptables -A FORWARD -i ${WAN_IF} -d ${LAN_CIDR} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
EOF
fi

# DNAT-y
if $DO_DNAT; then
  echo
  echo "# DNAT (port forwarding)"
  for r in "${DNAT_RULES[@]}"; do
    echo "$r"
  done
fi

cat <<'FOOT'

# podgląd
echo
echo "=== FILTER ==="
iptables -L -v
echo
echo "=== NAT ==="
iptables -t nat -L -v
FOOT
} > "$TARGET"

chmod +x "$TARGET"

# =============== uruchom od razu ===============
echo "▶️  Uruchamiam ${TARGET} …"
bash "$TARGET"

echo
echo "✅ Gotowe. Skrypt zapamiętany w ${TARGET}"
echo "ℹ️  Utrwalenie po restarcie (opcjonalnie):"
echo "    apt -y install iptables-persistent && netfilter-persistent save"
