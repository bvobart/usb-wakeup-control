#!/bin/bash -e

config_dir="/etc/usb-wakeup-control"

function usage {
  echo "usb-wakeup-control"
  echo
  echo "This simple utility enables or prevents specific USB devices from waking up the system upon suspend."
  echo "Pretty useful if your Linux laptop or PC refuses to go to sleep because some USB device (like my Logitech G915 wireless keyboard receiver) is keeping it awake."
  echo "Also useful to prevent unintended mouse movements from accidentally waking up your laptop."
  echo
  echo "Usage:"
  echo "  $0 install                       install this script as /usr/local/bin/usb-wakeup-control and add a systemd service to /etc/systemd/system"
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

# Find the wakeup file for a specific USB device
# Usage: find_wakeup_file vendorId productId
# Returns: the path to the wakeup file, guaranteed to exist
function find_wakeup_file {
  vendor=$1
  product=$2
  for bus in /sys/bus/usb/devices/*; do
    if [[ ! -f "$bus/idVendor" ]] || [[ ! -f "$bus/idProduct" ]]; then continue; fi

    idVendor=$(cat "$bus/idVendor")
    idProduct=$(cat "$bus/idProduct")
    wakeup_file="$bus/power/wakeup"
    if [[ $idVendor = "$vendor" ]] && [[ $idProduct = "$product" ]] && [[ -f "$wakeup_file" ]]; then
      echo "$wakeup_file"
    fi
  done
}

# Set the wakeup state for a specific USB device
# Usage: set_wakeup_state bus vendor product productName state
# where: state is either "enabled" or "disabled"
# Returns: nothing (but prints the old and new state in journalctl format)
function set_wakeup_state {
  bus=$1
  vendor=$2
  product=$3
  product_name=$4
  state=$5

  wakeup_file=$(find_wakeup_file "$vendor" "$product")
  bus=${wakeup_file%/power/wakeup}

  old_state=$(cat "$wakeup_file")
  echo "$state" > "$wakeup_file"
  new_state=$(cat "$wakeup_file")
  echo "Bus-port:$bus vendor=$vendor product=$product name=$product_name WakeUp: old=$old_state new=$new_state"
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
  here=$(dirname "$0")
  cd "$here" || exit

  echo "Installing usb-wakeup-control to /usr/local/bin"
  cp "$0" /usr/local/bin/usb-wakeup-control
  chmod +x /usr/local/bin/usb-wakeup-control

  service_file="usb-wakeup-control.service"
  target_dir="/etc/systemd/system"
  echo "Installing $service_file to $target_dir"
  cp $service_file $target_dir
  chmod 755 $target_dir/$service_file
  systemctl daemon-reload
  systemctl enable $service_file

  mkdir -p "$config_dir"
  touch "$config_dir/disabled"
  touch "$config_dir/enabled"

  echo "Done! Use [usb-wakeup-control enable] and [usb-wakeup-control disable] to control USB wakeup from specific devices."
}

function detect {
  for bus in /sys/bus/usb/devices/*; do
    if [[ -f "$bus/idVendor" ]] && [[ -f "$bus/idProduct" ]]; then
      idVendor=$(cat "$bus/idVendor")
      idProduct=$(cat "$bus/idProduct")
      if [ -f "$bus/product" ]; then
        productName=$(cat "$bus/product")
      fi

      wakeup_file="$bus/power/wakeup"
      if [[ -f "$wakeup_file" ]]; then
        wakeup_state=$(cat "$wakeup_file")
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
    echo "$vendor $product" >> "$config_dir/disabled"
    echo "Config: added USB device $vendor $product to $config_dir/disabled"
  fi
  
  set_wakeup_state "$bus" "$vendor" "$product" "$productName" "disabled"
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
    echo "$vendor $product" >> "$config_dir/enabled"
    echo "Config: added USB device $vendor $product to $config_dir/enabled"
  fi

  set_wakeup_state "$bus" "$vendor" "$product" "$productName" "enabled"
}

function wakeup_disable_all_configured_devices {
  while read -r vendor product; do
    disable "$vendor" "$product"
  done < "$config_dir/disabled"
}

function wakeup_enable_all_configured_devices {
  while read -r vendor product; do
    enable "$vendor" "$product"
  done < "$config_dir/enabled"
}

#--------------------------------------------------------------------------------------------------
# Main
#--------------------------------------------------------------------------------------------------

if [[ "$1" == "install" ]]; then
  install
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
