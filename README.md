# rockchip_pwm_remotectl â€” Rockchip IR Remote Control Driver for Linux 7.3 (mainline)

Port of the Rockchip PWM IR remote control driver from the Armbian vendor
branch (`rk-6.1-rkr7.2`) to Linux mainline **7.3**. The port is deliberately
minimal and functional: the device tree interface, NEC decoding, key tables,
repeat logic and the capture path are unchanged; only the API breaks between
vendor 6.1 and mainline 7.3 have been fixed â€” plus a set of clearly marked
bugs inherited from the vendor code.

Confirmed working: **IR reception** on an **X88PRO13 (RK3528)** running
Armbian `7.3.0-rc7-edge-rockchip64` (setup below). Suspend/resume, wakeup via
IR, repeat behaviour and teardown have not been tested separately (details in
the [Test status](#test-status-and-limitations) section).

---

## Contents

- [Feature overview](#feature-overview)
- [V1 vs. V4 â€” the most important pitfall](#v1-vs-v4--the-most-important-pitfall)
- [Installation](#installation)
- [Device tree configuration](#device-tree-configuration)
- [Debugging](#debugging)
- [API changes 6.1 â†’ 7.3](#api-changes-61--73)
- [Vendor bugs fixed along the way](#vendor-bugs-fixed-along-the-way)
- [Test status and limitations](#test-status-and-limitations)
- [License](#license)
- [Credits](#credits)

---

## Feature overview

The driver uses a PWM channel in capture mode to decode NEC-encoded IR
remote signals and reports the keys as standard input events (usable directly
by `evtest`, LXDE/GNOME/Kodi, Domoticz bindings, etc.).

- NEC protocol, several remotes in parallel (key tables from the DT)
- Pwrkey capture (wakeup from suspend, v4 hardware) or the ATF/SIP wakeup
  path (`remote_support_psci`)
- `wakeup-source` support
- Runs as a module (`rockchip_pwm_remotectl.ko`) or built-in

## V1 vs. V4 â€” the most important pitfall

The driver contains two hardware variants with **completely different
register layouts**:

| | PWM v1 (older SoCs) | PWM v4 (newer SoCs) |
|---|---|---|
| Registers | HPR 0x04, LPR 0x08, CTRL 0x0c; shared INT_EN of the PWM block (PWM3: channel base +0x14) | ENABLE 0x04, CTRL 0x0c, INT_EN 0x74 |
| Assignment | older PWM IPs (RK3328-compatible â€” **this includes the RK3528**) | newer PWM IPs with the v4 register layout |
| DT property `remote_pwm_id` | read | ignored |

Which variant is loaded is decided by the **order of the compatibles in the
device tree** â€” the first matching compatible wins the OF matching score.

**Note on the RK3528:** although the RK3528 is a recent SoC, its PWM IP is
register-compatible with the RK3328 according to
[rk3528.dtsi](https://github.com/armbian/linux-rockchip/blob/rk-6.1-rkr7.2/arch/arm64/boot/dts/rockchip/rk3528.dtsi)
(`compatible = "rockchip,rk3528-pwm", "rockchip,rk3328-pwm"`) â€” so the RK3528
runs the **v1 path**. The correct configuration is:

```dts
compatible = "rockchip,remotectl-pwm", "rockchip,remotectl-pwm-v4";
```

(v1 first â€” exactly as in the vendor DTS of the [joilg/x88pro](https://github.com/joilg/x88pro)
project.)

**Symptom of a wrong choice** (only `-v4`): the driver loads cleanly, the
input device shows up in `evtest`, dmesg reports `Controller support pwrkey
capture` â€” but **no IR events arrive**. Cause: the v4 `init_hw` writes to
offset 0x04 â€” in the v1 layout that is the HPR period register, not an enable
register; the real interrupt enable is never set, so the capture never
raises an IRQ.

## Installation

### Requirements

- Kernel headers for the running kernel (e.g.
  `linux-headers-$(uname -r)`)
- `build-essential` (i.e. gcc + make)

### Option A: DKMS (recommended)

DKMS needs two additional files in the package directory besides the sources:

`dkms.conf`:

```text
PACKAGE_NAME="rk-remotectl"
PACKAGE_VERSION="7.3"
BUILT_MODULE_NAME[0]="rockchip_pwm_remotectl"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
```

With `MAKE[0]` DKMS invokes Kbuild in the kernel source directory â€” a bare
`obj-m` Makefile on its own is not executable by a plain `make` call.

`Makefile` (out-of-tree, DKMS mode â€” the in-tree Makefile from the patch with
`obj-$(CONFIG_â€¦)` does not build anything here, because the distribution
kernel does not set that option):

```make
obj-m := rockchip_pwm_remotectl.o
```

```bash
sudo apt install dkms
git clone https://github.com/<your-fork>/rk-remotectl.git
sudo cp -r rk-remotectl /usr/src/rk-remotectl-7.3
sudo dkms add -m rk-remotectl -v 7.3
sudo dkms build  -m rk-remotectl -v 7.3
sudo dkms install -m rk-remotectl -v 7.3
```

After kernel updates the module is rebuilt automatically.

### Option B: Direct build against the kernel headers

This requires a Makefile for out-of-tree builds (see option A â€”
`obj-m := rockchip_pwm_remotectl.o`); the in-tree Makefile from the patch
builds nothing outside the kernel tree because
`CONFIG_ROCKCHIP_REMOTECTL_PWM` is not set in the distribution kernel:

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo cp rockchip_pwm_remotectl.ko /lib/modules/$(uname -r)/
sudo depmod -a
sudo modprobe rockchip_pwm_remotectl
```

### Option C: Inside the kernel tree (patch)

```bash
git clone --depth=1 --branch v7.3 https://github.com/torvalds/linux.git linux-7.3
cd linux-7.3
git apply 0001-input-rockchip-add-pwm-remotectl-driver-for-v7.3.patch
make ARCH=arm64 CROSS_COMPILE=<aarch64-...>- defconfig
./scripts/config -m ROCKCHIP_REMOTECTL -m ROCKCHIP_REMOTECTL_PWM
make ARCH=arm64 CROSS_COMPILE=<aarch64-...>- olddefconfig
make ARCH=arm64 CROSS_COMPILE=<aarch64-...>- M=drivers/input/remotectl modules
```

Note on MODPOST: "symbol â€¦ undefined" can have two different causes.
(a) Against distribution headers (DKMS, option A) the header package ships
`Module.symvers` â€” a symbol reported in that case is genuinely not exported
(this is exactly how the `irq_to_desc` error surfaced, see
[API changes](#api-changes-61--73)). (b) In a freshly cloned kernel tree
without a full build the symbol table is missing entirely, and MODPOST
reports every symbol. In that case, build only against a fully built kernel
tree; `KBUILD_MODPOST_WARN=1` is solely a compile test (`.o`) and does not
prove loadability â€” it also suppresses real errors.

## Device tree configuration

Example for the X88PRO13 (PWM3):

```dts
&pwm3 {
	compatible = "rockchip,remotectl-pwm", "rockchip,remotectl-pwm-v4";
	/delete-property/ #pwm-cells;
	pinctrl-names = "default";
	pinctrl-0 = <&pwm3m0_pins>;
	interrupts = <GIC_SPI 53 IRQ_TYPE_LEVEL_HIGH GIC_SPI 54 IRQ_TYPE_LEVEL_HIGH>;
	remote_pwm_id = <3>;
	handle_cpu_id = <1>;
	remote_support_psci = <0>;
	wakeup-source;
	status = "okay";

	ir_key5 {
		rockchip,usercode = <0xf708>;
		/* pairs of <scancode keycode>; here: scancode 0xf4 = KEY_POWER */
		rockchip,key_table = <0xf4 0x74>;
	};
};
```

Further keys and further `ir_keyN` nodes (additional remotes) are added in the
same way â€” the complete tables for the X88PRO13 remotes can be found in the
[joilg/x88pro](https://github.com/joilg/x88pro) project.

| Property | Meaning |
|---|---|
| `compatible` | v1 **before** v4 (see above); on the RK3528 the order decides |
| `remote_pwm_id` | PWM channel (v1 path only; `remote_pwm_id = <3>` for PWM3) |
| `handle_cpu_id` | CPU core the IRQ is pinned to |
| `remote_support_psci` | `1` = enable the ATF wakeup path (SMC `0x8200000b`) |
| `wakeup-source` | wake from suspend via IR |
| `rockchip,usercode` | NEC address word of the remote (hex) |
| `rockchip,key_table` | pairs `<scancode keycode>`; keycodes are Linux input codes as per `include/uapi/linux/input-event-codes.h` (e.g. `0x74` = KEY_POWER, `0x1c` = KEY_ENTER, `0x184` = KEY_TEXT) |

Several `ir_keyN` nodes allow several remotes in parallel. The keycodes
follow the Linux input history (`include/uapi/linux/input-event-codes.h`).

## Debugging

The `/sys/module/<module-name>/parameters/` paths depend on the name of the
module actually bound. The module name can be read from the device:

```bash
readlink -f /sys/bus/platform/devices/ffa90030.pwm/driver/module
```

```bash
# module parameters: additional decoder/driver output in the kernel log
echo 1 > /sys/module/rockchip_pwm_remotectl/parameters/code_print
echo 4 > /sys/module/rockchip_pwm_remotectl/parameters/dbg_level

# is the IRQ firing? (counter must increase when keys are pressed)
cat /proc/interrupts | grep pwm_rc

# check events
evtest /dev/input/by-path/*ffa90030*

# dmesg
dmesg | grep -i "remotectl\|pwm"
```

Typical dmesg patterns:

- `Controller support pwrkey capture` â†’ the driver is running the **v4 path**.
  On the RK3528 this is the symptom of a wrong compatible (see above).
- `Donot support ATF Wakeup` â†’ normal with `remote_support_psci = <0>`;
  the kernel capture path handles the IR decoding.

## API changes 6.1 â†’ 7.3

Pure API migration (details in the [port diff](0000-vendor-to-7.3-port.diff)):

1. **Wake lock API removed** (mainline has no `wakelock.h`):
   `wake_lock_timeout(â€¦, HZ)` â†’ `pm_wakeup_event(dev, MSEC_PER_SEC)`
2. **`from_timer()` no longer exists**: `container_of()` pattern
3. **`.remove` must be `void`** (since 6.11)
4. **`del_timer_sync()` is now** `timer_delete_sync()`
5. **`irq_set_affinity_hint()` deprecated**: `irq_set_affinity()` (the
   `_and_hint` variant stores the cpumask pointer permanently â€” with the
   stack address used by the vendor code that would be a dangling pointer)
6. **Rockchip SIP layer replaced** (`include/linux/rockchip/rockchip_sip.h`
   is vendor-only): `sip_smc_remotectl_config()` locally via
   `arm_smccc_smc(SIP_REMOTECTL_CFG=0x8200000b, func, data, â€¦)` â€” register
   layout and fallback behaviour identical to the
   [vendor implementation](https://github.com/rockchip-linux/kernel/blob/develop-6.1/drivers/firmware/rockchip_sip.c)
7. **`irq_to_desc()` replaced by `irq_get_irq_data()`**: with
   `CONFIG_SPARSE_IRQ=y` (the arm64 default) `irq_to_desc()` is only
   exported under `CONFIG_KVM_BOOK3S_64_HV_MODULE` â€” otherwise the DKMS
   build fails with `modpost: symbol 'irq_to_desc' undefined`. Both provide
   `irq_data->hwirq`/`irq_data->domain`, and `irq_get_irq_data()` is
   unconditionally GPL-exported
8. **Cosmetics**: duplicate includes, `pr_err` boot banner â†’ `dev_info()`,
   `MODULE_DESCRIPTION()` added

Deliberately unchanged: tasklets (deprecated, but still present in 7.3;
converting to threaded IRQs would be a separate project), `input_event()`
calls and the v1/v4 register logic.

## Vendor bugs fixed along the way

Fixed in the port and commented in the code:

- **Empty remove callback**: clean teardown â€” quiesce the capture engine,
  conditional `disable_irq_wake()`, `devm_free_irq()` (no global
  `disable_irq()`, because v1 runs with `IRQF_SHARED` on the shared PWM
  line), kill the tasklet, delete the timer
- **`module_platform_driver_probe` â†’ `module_platform_driver`** with proper
  `.probe`/`.remove`
- **`rk_pwm_clk_ctrl_v4()` called on v1 hardware** (suspend/resume):
  now guarded by `pwm_version >= 4`
- **Uninitialised `cpu_id`** when the DT property is missing â†’ `cpu_id = 0`
- **Ignored return value** of the key table parsing â†’ probe aborts
- **`enable_irq_wake()` unchecked** â†’ errors are logged, symmetric teardown
  via `irq_wake_enabled`

## Test status and limitations

- Compiles without warnings against Linux v7.3 (Bootlin aarch64, GCC 15.3.0);
  the patch was verified with `git apply --check` against a clean, fresh
  v7.3 checkout
- **Runtime confirmed** on X88PRO13/RK3528 with Armbian 7.3.0-rc7-edge:
  IR reception works (v1 path, see [V1 vs. V4](#v1-vs-v4--the-most-important-pitfall))
- Not tested: suspend/resume wakeup via IR, the ATF pwrkey path
  (`remote_support_psci = 1`), behaviour on v4 hardware
- The MODPOST pass during a DKMS build against a distribution kernel requires
  an intact `Module.symvers` from the kernel headers (the standard case)

## License

**GPL-2.0** â€” the source files carry
`SPDX-License-Identifier: GPL-2.0` (`.c` and `.h`), the module declaration is
`MODULE_LICENSE("GPL")`. The copyright and SPDX headers of the
Rockchip/Armbian authors are preserved; the published version must remain
GPL-2.0. For publication, add a `LICENSE` file with the GPL-2.0 text to the
repository.

## Credits

- Origin: [armbian/linux-rockchip](https://github.com/armbian/linux-rockchip),
  branch `rk-6.1-rkr7.2` (commit `85233a85`) â€” this is where the unchanged
  vendor driver lives
- Board support context: [joilg/x88pro](https://github.com/joilg/x88pro)
  (Armbian for the X88PRO13)
- The port to Linux 7.3 (API migration, module symbol verification, the
  DKMS fix `irq_to_desc` â†’ `irq_get_irq_data` and the V1/V4 diagnosis) was
  done with assistance from [Perplexity Computer](https://www.perplexity.ai/).

## Sources

- [Vendor driver rk-6.1-rkr7.2](https://github.com/armbian/linux-rockchip/blob/rk-6.1-rkr7.2/drivers/input/remotectl/rockchip_pwm_remotectl.c)
- [Vendor SIP implementation](https://github.com/rockchip-linux/kernel/blob/develop-6.1/drivers/firmware/rockchip_sip.c)
- [rk3528.dtsi â€” PWM declared rk3328-compatible](https://github.com/armbian/linux-rockchip/blob/rk-6.1-rkr7.2/arch/arm64/boot/dts/rockchip/rk3528.dtsi)
- [Linux v7.3](https://github.com/torvalds/linux/tree/v7.3)
- [Bootlin toolchains](https://toolchains.bootlin.com/)
