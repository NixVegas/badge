#!/bin/sh

cache_upstream=cache.nixos.org
cache_store=/nix/store
cache_priority=40
cache_use_https=1
cache_p2p=1
boot_mesh=0
output=nvs.bin

while [[ $1 ]]; do
  case "$1" in
    --cache-cert=*)
      cache_cert=${1#*=}
      ;;
    --cache-upstream=*)
      cache_upstream=${1#*=}
      ;;
    --cache-store=*)
      cache_store=${1#=*}
      ;;
    --cache-priority=*)
      cache_priority=${1#*=}
      ;;
    --cache-use-https)
      cache_use_https=1
      ;;
    --cache-no-https)
      cache_use_https=0
      ;;
    --boot-mesh=*)
      boot_mesh=1
      ;;
    --boot-no-mesh=*)
      boot_mesh=0
      ;;
    --router-ssid=*)
      router_ssid=${1#*=}
      ;;
    --router-passwd=*)
      router_passwd=${1#*=}
      ;;
    --output=*)
      output=${1#*=}
      ;;
    --help|-h)
      echo "Options:"
      echo "  --cache-cert=FILE     Certificate to use for connecting to the upstream cache"
      echo "  --cache-upstream=DNS  Domain name for the upstream cache"
      echo "  --cache-store=PATH    Path to say where the store is at"
      echo "  --cache-priority=PRI  Caching priority for substitution"
      echo "  --cache-use-https     Enable HTTPS with the upstream cache"
      echo "  --cache-no-https      Disable HTTPS with the upstream cache"
      echo "  --boot-mesh           Enable ESP-MESH-LITE on boot"
      echo "  --boot-no-mesh        Disable ESP-MESH-LITE on boot"
      echo "  --router-ssid=SSID    Router SSID for ESP-MESH-LITE"
      echo "  --router-passwd=PSK   Password for the router for ESP-MESH-LITE"
      echo "  --output=FILE         File path to output the generated NVS at"
      exit 0
      ;;
    *)
      echo "Invalid argument: $1" >&2
      exit 1
      ;;
  esac
  shift 1
done

nvs_raw=$(mktemp)

cat << EOF >"$nvs_raw"
key,type,encoding,value
config,namespace,,
boot_mesh,data,u8,$boot_mesh
cache_p2p,data,u8,$cache_p2p
cache_use_https,data,u8,$cache_use_https
cache_priority,data,u8,$cache_priority
cache_store,data,string,$cache_store
cache_upstream,data,string,$cache_upstream
EOF

if [ $cache_use_https -ne 0 ]; then
  if [ ! -f "$cache_cert" ]; then
    echo "Cache certificate is required!" >&1
    exit 1
  fi

  echo "cache_cert,file,string,$cache_cert" >>"$nvs_raw"
fi

  if [ -z "$router_ssid" ] || [ -z "$router_passwd" ]; then
  echo "WARNING: router ssid or passwd is not set, this will make the mesh network and cache substitution not work." >&1
else
  echo "router_ssid,data,string,$router_ssid" >>"$nvs_raw"
  echo "router_passwd,data,string,$router_passwd" >>"$nvs_raw"
fi

python "$IDF_PATH"/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py generate "$nvs_raw" "$output" 0x3000
