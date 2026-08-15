# Assemble the Duo S SD card: one MBR image with a FAT boot partition
# (fip.bin + both cores' kernels) and one shared ext4 root partition.
{ pkgs }:
{ bootDir, root }:
pkgs.runCommand "duos-sdcard"
  {
    nativeBuildInputs = [ pkgs.genimage pkgs.dosfstools pkgs.mtools pkgs.libfaketime ];
  }
  ''
    mkdir -p input emptyroot tmp

    # 1) Build the FAT boot partition image from the boot dir.
    #    Size = boot dir size + 256MiB slack, rounded up to a whole MiB.
    bytes=$(du -sb "${bootDir}" | cut -f1)
    mib=$(( (bytes + 256*1024*1024 + 1048575) / 1048576 ))
    truncate -s "''${mib}M" input/boot.vfat
    faketime -f "1970-01-01 00:00:00" mkfs.vfat -F 32 -n BOOT -i 12345678 input/boot.vfat
    # copy the whole boot tree in recursively (deterministic timestamps via faketime)
    ( cd "${bootDir}" && for entry in *; do \
        faketime -f "1970-01-01 00:00:00" \
          mcopy -s -i "$OLDPWD/input/boot.vfat" -- "$entry" :: ; \
      done )

    # 2) Stage the single combined root filesystem image.
    cp "${root}" input/root.ext4

    # 3) genimage config: MBR with FAT boot (0xc, bootable) + one ext4 root (0x83).
    cat > genimage.cfg <<'EOF'
    image sdcard.img {
      hdimage {
        partition-table-type = "mbr"
        disk-signature = 0x44554f53
        align = 1M
      }
      partition boot {
        partition-type = 0xc
        bootable = "true"
        image = "boot.vfat"
      }
      partition root {
        partition-type = 0x83
        image = "root.ext4"
      }
    }
    EOF

    genimage \
      --config genimage.cfg \
      --inputpath input \
      --outputpath output \
      --rootpath emptyroot \
      --tmppath tmp

    mkdir -p "$out"
    cp output/sdcard.img "$out/sdcard.img"
  ''
