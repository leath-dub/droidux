# Droidux

Let your Linux device inherit the hardware components of your android device.
With this you can:

* Use your android tablets digitizer (touch-sensor) as though it was an
  external (wacom-like) tablet for your Linux device.

* Use your android phones touch screen on your Linux device.

NOTE: this is a WIP and it will almost certainly have bugs, especially due to the fact that I wrote the device parser based on only the hardware I have. If you have any issues please raise them and I am happy to fix them.

## Installation

Binary builds are in the releases page on this repository: [latest one here](https://github.com/leath-dub/droidux/releases/latest).

### Example on how to download and install

```sh
curl -LO https://github.com/leath-dub/droidux/releases/download/latest/droidux-x86_64-linux-musl.xz
xz -d droidux-x86_64-linux-musl.xz
doas install -m +x droidux-x86_64-linux-musl /usr/local/bin/droidux
```

This will install `droidux` binary into `/usr/local/bin`.

Replace `x86_64` with your CPU architecture (most likely you are `x86_64` too).

**IMPORTANT:** You still need to follow the steps below with binary release, you
just don't need `zig` or have to build the project.

## Building

To build the project you will need `zig` version `0.13.0` and `adb`.

### ADB

This project uses `adb` for getting device information and reading device
events.

On archlinux:

```sh
sudo pacman -S android-tools
```

This will install `adb` and and `android-udev` which will setup the udev rules
for `adb` to work.

On voidlinux:

```sh
sudo xbps-install -S android-tools android-udev-rules
```

On other distros the their naming maybe slightly different however the important thing is that you get `adb` binary and the proper `udev` rules.

You can test that adb works by running:

```sh
adb devices
```

If you get any warnings or errors, make sure you login and out
again (or reboot) as the `udev` rules may not be realised yet.

### Droidux specific udev rules and hwdb files

IMPORTANT: make sure you complete this step otherwise `droidux` will not be able to run, either due to permission issues
or libinput not being happy about the initial values of certain devices.

#### Udev

First make sure you have `udev` running on your distro. This is more than likely already setup however at least
for voidlinux you need to make sure you the `udevd` service is running. Also I think on voidlinux you will have to add your user to the `plugdev` group.

There is a example `udev` rules file in the repo `rules.d/00-droidux.rules`. It should look like this:

```
KERNEL=="uinput", GROUP="wheel"
```

Either add your user to the `wheel` group or replace the "wheel" with your user name.

#### Hwdb

Hwdb as far as I know is just a way to set default values for devices that the drivers of which do not properly
set. Unfortunately I have hit this issue with my boox note air 2. The tell tale sign that you need a hwdb entry
is if libinput is complaining about skipping the device when you run:

```sh
sudo libinput list-devices
```

Consult these docs if you are hitting this issue with a different device: https://wayland.freedesktop.org/libinput/doc/1.12.0/tablet-debugging.html. Also feel free to make an issue about it and I can try to help you out with it.

A boox devices hwdb file is in this repo at `hwdb.d/00-boox.hwdb`. This should work for most boox devices as from my limited knowledge from an older version of this project they seem to all have the same digitizer. The idea is to have many different devices in `hwdb.d/` on this repo. Also if you know of a list of android's `hwdb` files that would be super helpful for this of course !

Similar to `udev` you need to put the files in `/etc/udev`, however this time at `/etc/udev/hwdb.d/00-boox.hwdb`. Unlike udev you need
to also trigger a recompilation of the database (at `/etc/udev/hwdb.bin` for me).

On systemd-distros (most distros) you run:

```sh
sudo sytemd-hwdb update
```

Many doc also tell you to run `udevadm trigger /dev/input/eventXX` however for `droidux` this is not really applicable unless you are running it while you run `systemd-hwdb update`.

On non-systemd distros, or at least on voidlinux you can run:

```sh
sudo udevadm hwdb --root=/ --update
```

### Zig

Don't worry the hard part is over if you have setup `adb` and `hwdb`. Now you just need to install `zig` compiler. If your distro
ships version `0.13.0` you should install it via that, otherwise you can install it at https://ziglang.org/download/.

### Finally

You can build the project with:

```sh
zig build -Doptimize=ReleaseFast
```

The binary for `droidux` will be in `zig-out/bin/droidux`. Make sure it is in your path, or the simplest is to just copy it to
`/usr/local/bin/` directory.


## Usage

The general usage of the tool has 2 main parts:

1. getting device information
2. setting up the virtual device you choose

NOTE: make sure you enable usb debugging on your android device. See https://developer.android.com/studio/debug/dev-options.

After you plug in you android device via usb (you can also use wifi consult https://developer.android.com/tools/adb). You can run:

```sh
droidux -l
```

You will need to accept "usb debugging" message on your device. If you are not lightning fast `droidux` will likely exit as it failed
to connect to the device. Just re-run the command after you have accepted the "usb debugging" message.

The command will dump the list of hardware devices on your android device as json. You can use a tool like `jq` to filter this output
to for example list only the names:

```sh
droidux -l | jq ".name"
```

Once you have found a device you wish to use just copy the name, for boox users it will likely be "onyx_emp_Wacom I2C Digitizer".

Now just run `droidux` passing that device name, e.g.:

```sh
droidux "onyx_emp_Wacom I2C Digitizer"
```

This should setup your device and proxy and events it reads.
To check that it is setup run something like this:

```sh
cat /proc/bus/input/devices | grep "<put device name here!>"
```

It is fine to "Ctrl+C" this to stop it, or if it is running in
the background you can stop it with:

```sh
pkill -USR1 droidux
```

Or run `kill -USR1` after finding the pid of `droidux`.

## Mapping tablet output

The default behaviour on linux is to stretch the viewport of the tablet onto
that of the screen.

A good general resource for reading is this [archwiki](https://wiki.archlinux.org/title/Graphics_tablet) post.

Depending on your tablet dimensions with respect to the screen you are mapping
it onto (NOTE: width and height are swapped if you rotate the tablet*), your
strategy for mapping may be different.

if your tablets `width / height` is less than that of the monitor you are
mapping to (e.g. `4 / 3 < 16 / 9`). You should fix the height to be the same as
the monitor you are mapping to. If we fix the height, we must sacrifice some of
the width of the monitor, so we need to calculate a horizontal offset position
of the new viewport onto the monitors resolution and we need to find how wide
the new viewport is. The following calculates these variables:
`horizontal_offset` and `new_viewport_width`:

```
proportion_change_in_height = (tablet_height - monitor_width) / tablet_height
change_in_width = tablet_width * proportion_change_in_height

new_viewport_width = tablet_width - change_in_width
horizontal_offset = (monitor_width - new_viewport_width) / 2
```

This basically just calculates the proportional change that happens if we
linearly map the height of the tablets viewport to height of the monitors
viewport. We just use this change to calculate the new view port and the offset
that would center it on the screen.

For example if we have a tablet with `width * height = 1872 * 1404` (ONYX BOOX
        Note Air 2 orientated horizontally). If we calculate the values above we
get `new_viewport_width = 1440` and `horizontal_offset = 240`.

The same process applies for if you want to fix the width, if for example you
have
a `4:3` monitor and `16:9` tablet (lazy example).

Now finally if you have these values, I know that at least for fellow sway users
you can change the tablets mapping like so:

```sh
input "11551:299:onyx_emp_Wacom_I2C_Digitizer" map_to_region 240 0 1440 1080
#                                  This is the width offset  --^ ^ ^-------- This is the new viewport
#                                                                |
#                                                                `-- Height offset stays the same
```

That first argument to `input` is the device identifier you can get by
extracting the `identifier` field from `swaymsg`:

```sh
DROIDUX_DEVICE="onyx_emp_Wacom I2C Digitizer"
swaymsg -rt get_inputs | jq -r '.[] | select(.name == "'"$DROIDUX_DEVICE"'").identifier'
```

## Services

I do not use systemd myself. However I plan to write a service file for it (unless somebody else beats me !).

As for voidlinux. I am using `turnstiled` following how to setup user services via https://docs.voidlinux.org/config/services/user-services.html#turnstile. Then I run the following command in my window manager's config:

```sh
turnstile-update-runit-env DROIDUX_DEVICE='onyx_emp_Wacom I2C Digitizer'
```

This sets up the environment for the following service script, which I put in `$HOME/.config/service/droidux/run` (make sure `run` is executable!):

```sh
#!/bin/sh

exec droidux "$(cat "$TURNSTILE_ENV_DIR/DROIDUX_DEVICE")"
```
