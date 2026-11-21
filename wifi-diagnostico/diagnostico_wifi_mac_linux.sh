#!/usr/bin/env bash
# Diagnóstico WiFi para macOS / Linux. Ejecutar:  bash diagnostico_wifi_mac_linux.sh
# Solo LEE información; no cambia ninguna configuración.
OUT="$HOME/informe_wifi.txt"; : > "$OUT"
s(){ printf '\n===== %s =====\n' "$1" | tee -a "$OUT"; }
r(){ "$@" 2>&1 | tee -a "$OUT"; }
echo "Informe WiFi - $(date)" | tee -a "$OUT"

if [[ "$(uname)" == "Darwin" ]]; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
  s "1. Interfaz WiFi (señal RSSI, ruido, canal, tasa)"
  r system_profiler SPAirPortDataType
  s "2. Calidad de red (Apple networkQuality)"
  r networkQuality -v
else
  GW=$(ip route | awk '/default/{print $3; exit}')
  IF=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  s "1. Interfaz WiFi ($IF)"
  r iw dev "$IF" link
  r iw dev "$IF" get power_save
  s "2. Redes cercanas (saturación de canales)"
  r nmcli -f SSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list
fi

s "3. Latencia y pérdida al router ($GW, 100 pings)"
r bash -c "ping -c 100 -i 0.2 $GW | tail -3"
s "4. Latencia y pérdida a Internet (1.1.1.1, 100 pings)"
r bash -c "ping -c 100 -i 0.2 1.1.1.1 | tail -3"
s "5. Tiempo de resolución DNS"
for d in google.com wikipedia.org netflix.com; do
  r bash -c "dig $d | grep 'Query time' | sed 's/^/$d -> /'"
done
echo -e "\nInforme guardado en: $OUT"
