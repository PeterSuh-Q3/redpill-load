#!/usr/bin/sh
# This script is saved to /sbin/modprobe which is a so called UMH (user-mode-helper) for kmod (kernel/kmod.c)
# The kmod subsystem in the kernel is used to load modules from kernel. We exploit it a bit to load RP as soon as
# possible (which turns out to be via init/main.c => load_default_modules => load_default_elevator_module
# When the kernel is booted with "elevator=elevator" it will attempt to load a module "elevator-iosched"... and the rest
# should be obvious from the code below. DO NOT print anything here (kernel doesn't attach STDOUT)
    insmod /usr/lib/modules/rp.ko
    #rm /usr/lib/modules/rp.ko
    rm /sbin/modprobe
    ln -s /bin/busybox /sbin/modprobe
    modprobe $@
