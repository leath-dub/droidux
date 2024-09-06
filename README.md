# (WIP)

This is public because I am too lazy to make it private! This is basically a more generalized
implementation of (vboox)[https://github.com/leath-dub/vboox], which is in need of some TLC.
Basically that old project hard coded device specifications, this new one is able to use `adb getevent`
and parse its output of devices, and directly create the devices based on the data parsed. The goal of
this project will eventually be that you can create virtual devices generically based on the devices
read from your android device: e.g. you could use your android power button as device on linux, i don't know
how useful that is though, the main use case is that you can create a digitizer device so that you can use
a android drawing tablet as a wacom like external tablet.

# Setup

Install `adb`. Verify that you can connect to your device manually by running:

```sh
adb attach
```

If this does not work follow (androids guide)[https://developer.android.com/studio/run/device].

On the distro I use `voidlinux`. I install `android-tools` and `android-udev-rules`. Please open an issue
about your distro so I can help you to get it working and update the readme.
