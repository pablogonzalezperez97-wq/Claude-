# Diagnóstico WiFi para Windows. Ejecutar en PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\diagnostico_wifi_windows.ps1
# Solo LEE información; no cambia ninguna configuración.
$out = "$env:USERPROFILE\Desktop\informe_wifi.txt"
function S($t){ "`n===== $t =====" | Tee-Object -FilePath $out -Append }
"Informe WiFi - $(Get-Date)" | Out-File $out

S "1. Interfaz WiFi (señal, canal, banda, velocidad negociada)"
netsh wlan show interfaces | Tee-Object -FilePath $out -Append

S "2. Redes cercanas (saturación de canales)"
netsh wlan show networks mode=bssid | Tee-Object -FilePath $out -Append

S "3. Driver y capacidades del adaptador"
netsh wlan show drivers | Select-String "Controlador|Driver|Versión|Version|Tipos de radio|Radio types|802.11" | Tee-Object -FilePath $out -Append

S "4. Ahorro de energía del adaptador"
Get-NetAdapter -Physical | Where-Object {$_.MediaType -match "802.11|Native"} | ForEach-Object {
  Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue | Format-List | Out-String
} | Tee-Object -FilePath $out -Append

S "5. Latencia y pérdida al router (100 pings)"
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1).NextHop
"Router: $gw" | Tee-Object -FilePath $out -Append
ping -n 100 $gw | Select-Object -Last 4 | Tee-Object -FilePath $out -Append

S "6. Latencia y pérdida a Internet (100 pings a 1.1.1.1)"
ping -n 100 1.1.1.1 | Select-Object -Last 4 | Tee-Object -FilePath $out -Append

S "7. Tiempo de resolución DNS"
foreach($d in "google.com","wikipedia.org","netflix.com"){
  $t = Measure-Command { Resolve-DnsName $d -DnsOnly -ErrorAction SilentlyContinue | Out-Null }
  "$d : $([int]$t.TotalMilliseconds) ms" | Tee-Object -FilePath $out -Append
}
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | Format-Table InterfaceAlias,ServerAddresses | Out-String | Tee-Object -FilePath $out -Append

S "8. Procesos que más red consumen ahora mismo"
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
  $p = Get-Process -Id $_.Name -ErrorAction SilentlyContinue; "{0,-30} {1} conexiones" -f $p.ProcessName, $_.Count
} | Tee-Object -FilePath $out -Append

S "9. Desconexiones WiFi en los últimos 7 días"
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; Id=8003; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Measure-Object | ForEach-Object { "Desconexiones: $($_.Count)" } | Tee-Object -FilePath $out -Append

"`nInforme guardado en: $out"
