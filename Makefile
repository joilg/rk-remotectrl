# SPDX-License-Identifier: GPL-2.0
#
# Makefile for the input remotectl drivers.
#

# Each configuration option enables a list of files.

obj-m := rk-remotectl.o
rk-remotectl-objs += rockchip_pwm_remotectl.o

