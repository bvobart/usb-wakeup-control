# `usb-wakeup-control`

This simple utility enables or prevents specific USB devices from waking up the system upon suspend. Pretty useful if your Linux laptop or PC refuses to go to sleep because some USB device (like my Logitech G915 wireless keyboard receiver) is keeping it awake. Also useful to prevent unintended mouse movements from accidentally waking up your laptop.

## Usage

| Command                                              | Description                                                                                                                                                                                                                        |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./usb-wakeup-control.sh install [--to directory]`   | install this script as `<directory>/usb-wakeup-control` (default: `/usr/local/bin`) and add a systemd service to `/etc/systemd/system`.<br /><br />_NOTE: This is required for the other commands to persist after rebooting or unplugging and replugging._ |
| `./usb-wakeup-control.sh detect`                     | list all connected USB devices and their current wakeup status                                                                                                                                                                     |
| `./usb-wakeup-control.sh disable vendorId productId` | disable wakeup for a specific USB device                                                                                                                                                                                           |
| `./usb-wakeup-control.sh enable vendorId productId`  | enable wakeup for a specific USB device                                                                                                                                                                                            |

Vendor ID and product ID can either be found using `usb-wakeup-control detect` or `lsusb`.

For example, if `lsusb` shows:

```
Bus 001 Device 007: ID 046d:c52b Logitech, Inc. Unifying Receiver
```

then the vendor ID is `046d` and the product ID is `c52b`.

The `disable` and `enable` commands will store the given USB device vendor ID and product ID in `/etc/usb-wakeup-control/disabled` or `/etc/usb-wakeup-control/enabled`, respectively, to ensure persistance after rebooting or unplugging and replugging.
You could create these files manually, but it's recommended to use the `disable` and `enable` commands to ensure the correct format.

### Examples

- `sudo ./usb-wakeup-control.sh install --to /usr/bin`
- `usb-wakeup-control detect`
- `usb-wakeup-control disable 046d c52b`
- `usb-wakeup-control enable 046d c52b`

> **Note:** `disable` and `enable` require `sudo` (root privileges) to write to `/sys/bus/usb/devices/*/power/wakeup`<br />
  `install` also requires root privileges to write to `/usr/local/bin` and `/etc/systemd/system`<br />

## Development

The tests use [bats](https://github.com/bats-core/bats-core) (e.g. `sudo apt install bats`, `sudo dnf install bats` or `brew install bats-core`) and run against a fake `/sys/bus/usb/devices` and config directory, so they need neither root privileges nor any USB devices:

```sh
bats test/
shellcheck usb-wakeup-control.sh
```

## Thanks

To [this StackExchange answer](https://askubuntu.com/a/1359890) that inspired me to write this simple tool to make the process described in the answer easier for daily use and multiple devices.

And to the contributors who reported and fixed bugs:

- [@devZer0](https://github.com/devZer0) for reporting and proposing a fix for the service exiting early when a configured USB device is disconnected ([#1](https://github.com/bvobart/usb-wakeup-control/issues/1))
- [@fluoriteByte](https://github.com/fluoriteByte) for following up on [#1](https://github.com/bvobart/usb-wakeup-control/issues/1) and carrying the fix forward in [their fork](https://github.com/fluoriteByte/usb-wakeup-control)
- [@patux](https://github.com/patux) for fixing the handling of USB devices that show up multiple times, e.g. behind a USB hub ([#2](https://github.com/bvobart/usb-wakeup-control/pull/2))
