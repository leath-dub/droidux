# Droidux

Let your Linux device inherit the hardware components of your android device.
With this you can:

* Use your android tablets digitizer (touch-sensor) as though it was an
  external (wacom-like) tablet for your Linux device.

* Use your android phones touch screen on your Linux device.

NOTE: this is a WIP and it will almost certainly have bugs, especially due to the fact that I wrote the device parser based on only the hardware I have. If you have any issues please raise them and I am happy to fix them.

## Installation

Soon TM.

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

There is a template `udev` rules file in the repo `rules.d/00-droidux.rules.template`. It should look like this:

```
KERNEL=="uinput", GROUP="<your user name here>"
```

Just replace the `<your user name here>` with your user name. If you need other people to use `droidux` you can
create a group like `udev` and set all the users to be in that group. Then just `udev` on the right hand side
of the `GROUP` instead of your user name.

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

## How ?
