#!/bin/bash -e

# These locations can be overridden with environment variables, which is mainly useful for testing.
usb_devices_dir="${USB_WAKEUP_CONTROL_USB_DEVICES_DIR:-/sys/bus/usb/devices}"
config_dir="${USB_WAKEUP_CONTROL_CONFIG_DIR:-/etc/usb-wakeup-control}"
systemd_dir="${USB_WAKEUP_CONTROL_SYSTEMD_DIR:-/etc/systemd/system}"

function usage {
  echo "usb-wakeup-control"
  echo
  echo "This simple utility enables or prevents specific USB devices from waking up the system upon suspend."
  echo "Pretty useful if your Linux laptop or PC refuses to go to sleep because some USB device (like my Logitech G915 wireless keyboard receiver) is keeping it awake."
  echo "Also useful to prevent unintended mouse movements from accidentally waking up your laptop."
  echo
  echo "Usage:"
  echo "  $0 install [--to directory]      install this script as <directory>/usb-wakeup-control (default: /usr/local/bin) and add a systemd service to /etc/systemd/system"
  echo "                             NOTE: This is required for the other commands to persist after rebooting or unplugging and replugging."
  echo "  $0 detect                        list all connected USB devices and their current wakeup status"
  echo "  $0 disable vendorId productId    disable wakeup for a specific USB device"
  echo "  $0 enable vendorId productId     enable wakeup for a specific USB device"
  echo
  echo "Vendor ID and product ID can either be found using [usb-wakeup-control] detect or [lsusb]."
  echo
  echo "For example, if [lsusb] shows:"
  echo
  echo "    Bus 001 Device 007: ID 046d:c52b Logitech, Inc. Unifying Receiver"
  echo
  echo "then the vendor ID is '046d' and the product ID is 'c52b'."
  echo
  echo "The disable and enable commands will store the given USB device vendor ID and product ID in /etc/usb-wakeup-control/disabled or /etc/usb-wakeup-control/enabled, respectively, to ensure persistance."
  echo "You could create these files manually, but it's recommended to use the disable and enable commands to ensure the correct format."
  echo
  echo "Examples:"
  echo "  $0 detect"
  echo "  $0 disable 0bda 8153"
  echo "  $0 enable 0bda 8153"
  echo
  echo "Note: The disable and enable commands require sudo (root privileges) to write to /sys/bus/usb/devices/*/power/wakeup"
  echo "      The install command also requires root privileges to write to /usr/local/bin and /etc/systemd/system"
}

#--------------------------------------------------------------------------------------------------
# Helpers
#--------------------------------------------------------------------------------------------------

# Find the wakeup file for specific USB devices
# Usage: find_wakeup_files vendorId productId
# Returns: the path to the wakeup file, guaranteed to exist
function find_wakeup_files {
  vendor=$1
  product=$2
  for bus in "$usb_devices_dir"/*; do
    if [[ ! -f "$bus/idVendor" ]] || [[ ! -f "$bus/idProduct" ]]; then continue; fi

    idVendor=$(cat "$bus/idVendor")
    idProduct=$(cat "$bus/idProduct")
    wakeup_files="$bus/power/wakeup"
    if [[ $idVendor = "$vendor" ]] && [[ $idProduct = "$product" ]] && [[ -f "$wakeup_files" ]]; then
      echo "$wakeup_files"
    fi
  done
}

# Set the wakeup state for a specific USB device
# Usage: set_wakeup_state vendor product state
# where: state is either "enabled" or "disabled"
# Returns: nothing (but prints the old and new state in journalctl format)
function set_wakeup_state {
  vendor=$1
  product=$2
  state=$3

  wakeup_files=$(find_wakeup_files "$vendor" "$product")
  if [[ -z "$wakeup_files" ]]; then
    echo "vendor=$vendor product=$product not connected, skipping. WakeUp will be set to $state once it is connected and usb-wakeup-control runs again."
    return 0
  fi

  for wakeup_file in $wakeup_files; do
    bus=${wakeup_file%/power/wakeup}
    # the device may have been unplugged since find_wakeup_files looked for it
    if [[ ! -e "$wakeup_file" ]]; then
      echo "Bus-port:$bus vendor=$vendor product=$product disconnected, skipping."
      continue
    fi

    product_name=$(cat "$bus/product" 2>/dev/null || true)
    old_state=$(cat "$wakeup_file")
    echo "$state" >"$wakeup_file"
    new_state=$(cat "$wakeup_file")
    echo "Bus-port:$bus vendor=$vendor product=$product name=$product_name WakeUp: old=$old_state new=$new_state"
  done
}

# Append a line to a config file, making sure it ends up on a line of its own
# Usage: add_to_config file line
function add_to_config {
  if [[ -s "$1" ]] && [[ -n "$(tail -c 1 "$1")" ]]; then echo >>"$1"; fi
  echo "$2" >>"$1"
}

# Check if a USB device is disabled in the config
# Usage: is_disabled_in_config vendor product
# Returns: 0 if the device is disabled, 1 otherwise
function is_disabled_in_config {
  vendor=$1
  product=$2

  if [[ -f "$config_dir/disabled" ]] && grep -q "$vendor $product" "$config_dir/disabled"; then
    return 0
  fi
  return 1
}

# Check if a USB device is enabled in the config
# Usage: is_enabled_in_config vendorId productId
# Returns: 0 if the device is enabled, 1 otherwise
function is_enabled_in_config {
  vendor=$1
  product=$2

  if [[ -f "$config_dir/enabled" ]] && grep -q "$vendor $product" "$config_dir/enabled"; then
    return 0
  fi
  return 1
}

#--------------------------------------------------------------------------------------------------
# Commands
#--------------------------------------------------------------------------------------------------

function install {
  bin_dir="/usr/local/bin"
  if [[ "$1" == "--to" ]] && [[ -n "$2" ]] && [[ $# -eq 2 ]]; then
    bin_dir=$2
  elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 install [--to directory]"
    exit 1
  fi
  # systemd needs an absolute path to the script
  mkdir -p "$bin_dir"
  bin_dir=$(cd "$bin_dir" && pwd)

  script=$(readlink -f "$0")
  cd "$(dirname "$script")" || exit

  echo "Installing usb-wakeup-control to $bin_dir"
  cp "$script" "$bin_dir/usb-wakeup-control"
  chmod +x "$bin_dir/usb-wakeup-control"

  service_file="usb-wakeup-control.service"
  target_dir="$systemd_dir"
  echo "Installing $service_file to $target_dir"
  sed "s|/usr/local/bin/usb-wakeup-control|$bin_dir/usb-wakeup-control|" $service_file >"$target_dir/$service_file"
  chmod 755 "$target_dir/$service_file"
  systemctl daemon-reload
  systemctl enable $service_file

  mkdir -p "$config_dir"
  touch "$config_dir/disabled"
  touch "$config_dir/enabled"

  echo "Done! Use [usb-wakeup-control enable] and [usb-wakeup-control disable] to control USB wakeup from specific devices."
}

function detect {
  for bus in "$usb_devices_dir"/*; do
    if [[ -f "$bus/idVendor" ]] && [[ -f "$bus/idProduct" ]]; then
      idVendor=$(cat "$bus/idVendor")
      idProduct=$(cat "$bus/idProduct")
      productName=""
      if [ -f "$bus/product" ]; then
        productName=$(cat "$bus/product")
      fi

      wakeup_files="$bus/power/wakeup"
      if [[ -f "$wakeup_files" ]]; then
        wakeup_state=$(cat "$wakeup_files")
        echo "$bus vendor=$idVendor product=$idProduct WakeUp=$wakeup_state name=$productName"
      fi
    fi
  done
}

function disable {
  vendor=$1
  product=$2

  if [[ -z "$vendor" ]] || [[ -z "$product" ]]; then
    echo "Usage: $0 disable vendorId productId"
    exit 1
  fi

  if is_enabled_in_config "$vendor" "$product"; then
    grep -v "$vendor $product" "$config_dir/enabled" > "$config_dir/enabled.tmp" || true
    mv "$config_dir/enabled.tmp" "$config_dir/enabled"
    echo "Config: removed USB device $vendor $product from $config_dir/enabled"
  fi

  if ! is_disabled_in_config "$vendor" "$product"; then
    mkdir -p "$config_dir"
    touch "$config_dir/disabled"
    add_to_config "$config_dir/disabled" "$vendor $product"
    echo "Config: added USB device $vendor $product to $config_dir/disabled"
  fi

  set_wakeup_state "$vendor" "$product" "disabled"
}

function enable {
  vendor=$1
  product=$2

  if [[ -z "$vendor" ]] || [[ -z "$product" ]]; then
    echo "Usage: $0 enable vendorId productId"
    exit 1
  fi

  if is_disabled_in_config "$vendor" "$product"; then
    grep -v "$vendor $product" "$config_dir/disabled" > "$config_dir/disabled.tmp" || true
    mv "$config_dir/disabled.tmp" "$config_dir/disabled"
    echo "Config: removed USB device $vendor $product from $config_dir/disabled"
  fi

  if ! is_enabled_in_config "$vendor" "$product"; then
    mkdir -p "$config_dir"
    touch "$config_dir/enabled"
    add_to_config "$config_dir/enabled" "$vendor $product"
    echo "Config: added USB device $vendor $product to $config_dir/enabled"
  fi

  set_wakeup_state "$vendor" "$product" "enabled"
}

function wakeup_disable_all_configured_devices {
  while read -r vendor product || [[ -n "$vendor" ]]; do
    if [[ -z "$vendor" ]] || [[ -z "$product" ]]; then continue; fi
    disable "$vendor" "$product"
  done < "$config_dir/disabled"
}

function wakeup_enable_all_configured_devices {
  while read -r vendor product || [[ -n "$vendor" ]]; do
    if [[ -z "$vendor" ]] || [[ -z "$product" ]]; then continue; fi
    enable "$vendor" "$product"
  done < "$config_dir/enabled"
}

#--------------------------------------------------------------------------------------------------
# Main
#--------------------------------------------------------------------------------------------------

if [[ "$1" == "install" ]]; then
  install "${@:2}"
  exit 0
elif [[ "$1" == "detect" ]]; then
  detect
  exit 0
elif [[ "$1" == "disable" ]]; then
  disable "$2" "$3"
  exit 0
elif [[ "$1" == "enable" ]]; then
  enable "$2" "$3"
  exit 0
elif [[ "$1" == "systemd-run-before-sleep" ]]; then
  wakeup_disable_all_configured_devices
  wakeup_enable_all_configured_devices
  exit 0
elif [[ "$1" == "help" || "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
else
  usage
  exit 1
fi
