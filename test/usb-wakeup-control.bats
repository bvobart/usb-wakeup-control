#!/usr/bin/env bats
#
# Tests for usb-wakeup-control.sh against a fake /sys/bus/usb/devices and a temporary config dir.
# Run with: bats test/

setup() {
  script="$BATS_TEST_DIRNAME/../usb-wakeup-control.sh"
  export USB_WAKEUP_CONTROL_USB_DEVICES_DIR="$BATS_TEST_TMPDIR/sys/bus/usb/devices"
  export USB_WAKEUP_CONTROL_CONFIG_DIR="$BATS_TEST_TMPDIR/etc/usb-wakeup-control"
  mkdir -p "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR" "$USB_WAKEUP_CONTROL_CONFIG_DIR"
  touch "$USB_WAKEUP_CONTROL_CONFIG_DIR/disabled" "$USB_WAKEUP_CONTROL_CONFIG_DIR/enabled"
}

# Usage: add_device bus vendorId productId wakeupState [productName]
add_device() {
  local dir="$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/$1"
  mkdir -p "$dir/power"
  echo "$2" >"$dir/idVendor"
  echo "$3" >"$dir/idProduct"
  echo "$4" >"$dir/power/wakeup"
  if [[ -n "$5" ]]; then echo "$5" >"$dir/product"; fi
}

wakeup_state_of() {
  cat "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/$1/power/wakeup"
}

config() {
  cat "$USB_WAKEUP_CONTROL_CONFIG_DIR/$1"
}

# Point install at a temporary systemd dir and replace systemctl with a stub that logs its arguments
setup_install() {
  export USB_WAKEUP_CONTROL_SYSTEMD_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  mkdir -p "$USB_WAKEUP_CONTROL_SYSTEMD_DIR" "$BATS_TEST_TMPDIR/stubs"
  rm -r "$USB_WAKEUP_CONTROL_CONFIG_DIR"
  printf '#!/bin/bash\necho "$*" >>"%s"\n' "$BATS_TEST_TMPDIR/systemctl.log" >"$BATS_TEST_TMPDIR/stubs/systemctl"
  chmod +x "$BATS_TEST_TMPDIR/stubs/systemctl"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

@test "help prints usage and exits 0, unknown command exits 1" {
  run "$script" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  run "$script" foo
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "install --to installs the script in the given directory and points the systemd service at it" {
  setup_install
  bin_dir="$BATS_TEST_TMPDIR/opt/bin"

  run "$script" install --to "$bin_dir"
  [ "$status" -eq 0 ]
  [ -x "$bin_dir/usb-wakeup-control" ]
  cmp "$script" "$bin_dir/usb-wakeup-control"
  grep -qx "ExecStart=$bin_dir/usb-wakeup-control systemd-run-before-sleep" "$USB_WAKEUP_CONTROL_SYSTEMD_DIR/usb-wakeup-control.service"
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.log")" = "$(printf 'daemon-reload\nenable usb-wakeup-control.service')" ]
  [ -f "$USB_WAKEUP_CONTROL_CONFIG_DIR/disabled" ]
  [ -f "$USB_WAKEUP_CONTROL_CONFIG_DIR/enabled" ]
}

@test "install --to with a relative directory and script path uses absolute paths" {
  setup_install
  mkdir -p "$BATS_TEST_TMPDIR/cwd"
  cd "$BATS_TEST_TMPDIR/cwd"
  relative_script=$(realpath --relative-to=. "$script")

  run "$relative_script" install --to bin
  [ "$status" -eq 0 ]
  [ -x "$BATS_TEST_TMPDIR/cwd/bin/usb-wakeup-control" ]
  grep -qx "ExecStart=$BATS_TEST_TMPDIR/cwd/bin/usb-wakeup-control systemd-run-before-sleep" "$USB_WAKEUP_CONTROL_SYSTEMD_DIR/usb-wakeup-control.service"
}

@test "install with invalid arguments exits 1 without installing anything" {
  setup_install

  for args in "--to" "--foo" "--to a b"; do
    # shellcheck disable=SC2086
    run "$script" install $args
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage: "*" install [--to directory]"* ]]
  done
  [ ! -e "$USB_WAKEUP_CONTROL_SYSTEMD_DIR/usb-wakeup-control.service" ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.log" ]
}

@test "detect lists every USB device with a wakeup file on its own line" {
  add_device 1-1 046d c52b enabled "Unifying Receiver"
  add_device 1-2 0bda 8153 disabled "USB 10/100/1000 LAN"
  # interfaces and devices without power/wakeup are not listed
  mkdir -p "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-1:1.0"
  mkdir -p "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-3"
  echo 1234 >"$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-3/idVendor"
  echo 5678 >"$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-3/idProduct"

  run "$script" detect
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-1 vendor=046d product=c52b WakeUp=enabled name=Unifying Receiver" ]
  [ "${lines[1]}" = "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-2 vendor=0bda product=8153 WakeUp=disabled name=USB 10/100/1000 LAN" ]
}

@test "detect does not reuse the name of the previous device for a device without a name" {
  add_device 1-1 046d c52b enabled "Unifying Receiver"
  add_device 1-2 8087 0033 disabled

  run "$script" detect
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/1-2 vendor=8087 product=0033 WakeUp=disabled name=" ]
}

@test "disable stores the device in the config and disables its wakeup" {
  add_device 1-1 046d c52b enabled
  add_device 1-2 0bda 8153 enabled

  run "$script" disable 046d c52b
  [ "$status" -eq 0 ]
  [ "$(config disabled)" = "046d c52b" ]
  [ "$(config enabled)" = "" ]
  [ "$(wakeup_state_of 1-1)" = disabled ]
  [ "$(wakeup_state_of 1-2)" = enabled ]
}

@test "enable moves the device from disabled to enabled and enables its wakeup" {
  add_device 1-1 046d c52b enabled

  run "$script" disable 046d c52b
  [ "$status" -eq 0 ]
  run "$script" enable 046d c52b
  [ "$status" -eq 0 ]
  [ "$(config disabled)" = "" ]
  [ "$(config enabled)" = "046d c52b" ]
  [ "$(wakeup_state_of 1-1)" = enabled ]
}

@test "disabling the same device twice stores it only once" {
  add_device 1-1 046d c52b enabled

  run "$script" disable 046d c52b
  run "$script" disable 046d c52b
  [ "$status" -eq 0 ]
  [ "$(config disabled)" = "046d c52b" ]
}

@test "enable and disable without vendor and product ID exit 1" {
  run "$script" disable
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]

  run "$script" enable 046d
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# https://github.com/bvobart/usb-wakeup-control/pull/2
@test "disable sets the wakeup state of every device matching vendor and product ID (e.g. behind a hub)" {
  add_device usb1 1d6b 0002 enabled "xHCI Host Controller"
  add_device usb2 1d6b 0002 enabled "EHCI Host Controller"
  add_device usb3 1d6b 0003 enabled "xHCI Host Controller"

  run "$script" disable 1d6b 0002
  [ "$status" -eq 0 ]
  [ "$(wakeup_state_of usb1)" = disabled ]
  [ "$(wakeup_state_of usb2)" = disabled ]
  [ "$(wakeup_state_of usb3)" = enabled ]
  [[ "${lines[1]}" == "Bus-port:$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/usb1 vendor=1d6b product=0002 "*"WakeUp: old=enabled new=disabled" ]]
  [[ "${lines[2]}" == "Bus-port:$USB_WAKEUP_CONTROL_USB_DEVICES_DIR/usb2 vendor=1d6b product=0002 "*"WakeUp: old=enabled new=disabled" ]]
}

# https://github.com/bvobart/usb-wakeup-control/issues/1
@test "disable stores a disconnected device in the config and reports it as not connected" {
  run "$script" disable dead beef
  [ "$status" -eq 0 ]
  [ "$(config disabled)" = "dead beef" ]
  [[ "$output" == *"vendor=dead product=beef not connected, skipping."* ]]
}

# https://github.com/bvobart/usb-wakeup-control/issues/1
@test "systemd-run-before-sleep applies all connected devices even if configured devices are disconnected" {
  add_device 2-1 046d c077 enabled
  add_device 2-2 03f0 0024 disabled
  printf 'dead beef\n046d c077\n' >"$USB_WAKEUP_CONTROL_CONFIG_DIR/disabled"
  printf 'cafe babe\n03f0 0024\n' >"$USB_WAKEUP_CONTROL_CONFIG_DIR/enabled"

  run "$script" systemd-run-before-sleep
  [ "$status" -eq 0 ]
  [ "$(wakeup_state_of 2-1)" = disabled ]
  [ "$(wakeup_state_of 2-2)" = enabled ]
  [[ "$output" == *"vendor=dead product=beef not connected, skipping."* ]]
  [[ "$output" == *"vendor=cafe product=babe not connected, skipping."* ]]
  # the config is left as is
  [ "$(config disabled)" = "$(printf 'dead beef\n046d c077')" ]
  [ "$(config enabled)" = "$(printf 'cafe babe\n03f0 0024')" ]
}
