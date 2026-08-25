# Power status for the Milk-V Duo S badge: rail voltages, USB VBUS detect, and the
# per-supply fault flags. Exposed as the `badge-power` CLI.
#
# Analog (cv1800b SARADC over IIO, see &saradc in the shared dtsi): three channels,
# each through a 2.2M/1M divider (x3.2). The driver reports in_voltageN_raw plus a
# shared in_voltage_scale (3300/4096 mV per LSB), so a rail is raw * scale * 3.2.
#   ch0 = VSEL (system rail, = VBUS through the TPS2116 mux while on USB power)
#   ch1 = VBAT (battery)
#   ch2 = J6   (external test point)
#
# Digital (named GPIO lines, read with libgpiod v2 `gpioget --by-name`):
#   usb-vbus-det   high  = USB VBUS present
#   *-fault-n      low   = fault active (TPS2553 open-drain /FAULT, active-low):
#     usb-5v-fault-n (U14 host port), hdmi-5v-fault-n (U19), sd-fault-n (U8),
#     sao-fault-n (U13).
#
# VSEL is the meaningful "VBUS" analog value (there is no separate raw-VBUS ADC);
# usb-vbus-det is the digital "is USB attached" bit. Together they say whether the
# board is on USB and at what rail voltage. The measurements can later drive LED
# brightness derating (cap output as VSEL nears the ~3.5V LED floor).
#
# Reading the SARADC (IIO sysfs) and claiming GPIO lines generally needs root; run
# `sudo badge-power` (sudo is passwordless on the badge, see deploy.nix).
{ pkgs, ... }:
let
  badge-power = pkgs.writeShellApplication {
    name = "badge-power";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.libgpiod
    ];
    text = ''
      # --- Rail voltages (SARADC) -------------------------------------------
      # On-board divider ratio: both taps are 2.2M (top) / 1M (bottom) = x3.2.
      div=3.2

      dev=""
      for d in /sys/bus/iio/devices/iio:device*; do
        [ -r "$d/name" ] || continue
        case "$(cat "$d/name")" in
          *adc*) dev="$d"; break ;;
        esac
      done

      if [ -n "$dev" ]; then
        scale="$(cat "$dev/in_voltage_scale")"   # mV per LSB (driver: 3300/4096)
        volt() { # $1 = channel index
          raw="$(cat "$dev/in_voltage''${1}_raw")"
          awk -v r="$raw" -v s="$scale" -v d="$div" \
            'BEGIN { printf "%.3f", r * s * d / 1000 }'
        }
        printf 'VSEL (system / VBUS): %s V\n' "$(volt 0)"
        printf 'VBAT (battery):       %s V\n' "$(volt 1)"
        printf 'J6   (ext ADC):       %s V\n' "$(volt 2)"
      else
        echo "VSEL/VBAT: no SARADC IIO device (is &saradc enabled + booted?)" >&2
      fi

      # --- Digital detect / fault lines (libgpiod v2) -----------------------
      # Echo 1 for a logic-high (active) line, 0 for low (inactive), ? otherwise.
      gpio_level() { # $1 = line name
        case "$(gpioget --by-name "$1" 2>/dev/null)" in
          *=active)   printf 1 ;;
          *=inactive) printf 0 ;;
          *)          printf '?' ;;
        esac
      }

      case "$(gpio_level usb-vbus-det)" in
        1) printf 'USB VBUS present:     yes\n' ;;
        0) printf 'USB VBUS present:     no\n' ;;
        *) printf 'USB VBUS present:     unknown\n' ;;
      esac

      # Active-low fault lines: a low level means the fault is asserted.
      printf 'Faults:\n'
      for pair in "usb-5v:usb-5v-fault-n" "hdmi-5v:hdmi-5v-fault-n" \
                  "sd:sd-fault-n" "sao:sao-fault-n"; do
        label="''${pair%%:*}"
        line="''${pair#*:}"
        case "$(gpio_level "$line")" in
          0) state="FAULT" ;;
          1) state="ok" ;;
          *) state="unknown" ;;
        esac
        printf '  %-8s %s\n' "$label:" "$state"
      done
    '';
  };
in
{
  environment.systemPackages = [ badge-power ];
}
