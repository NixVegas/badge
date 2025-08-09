#!/bin/sh

if [[ $# -eq 0 ]]; then
  echo "Missing path to the serial device (ex: /dev/ttyACM0)" >&1
  exit 1
fi

dev=$1
shift 1

out=$(mktemp)
$(dirname $0)/gen_nvs.sh $@ --output=$out

python3 $IDF_PATH/components/partition_table/parttool.py -p "$dev" write_partition --partition-name=nvs --input="$out"
