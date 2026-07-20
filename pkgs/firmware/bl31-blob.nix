# BL31 (ARM secure monitor) for SG2000. No public source exists; Sophgo ships
# it only as a prebuilt blob in the fsbl repo. Pinned fixed-output fetch.
{ pkgs }:
pkgs.fetchurl {
  name = "sg2000-bl31.bin";
  url = "https://raw.githubusercontent.com/sophgo/fsbl/29edcfa0b5f999c8ea8f0759b0dd0038421e6c25/plat/cv181x/prebuilt/bl31.bin";
  hash = "sha256-BV8bjxhvU43JAqXA0bExDTobIqny8riz1LsN5ybjONI=";
}
