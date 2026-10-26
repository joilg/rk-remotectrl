# rockchip_pwm_remotectl â€” Rockchip IR-Remotectl-Treiber fÃ¼r Linux 7.3 (Mainline)

Port des Rockchip-PWM-IR-Fernbedienungstreibers aus dem Armbian-Vendor-Zweig
(`rk-6.1-rkr7.2`) auf den Linux-Mainline-Kernel **7.3**. Der Port ist minimal
und funktional gehalten: Device-Tree-Schnittstelle, NEC-Auswertung,
Tastentabellen, Repeat-Logik und Capture-Pfad sind unverÃ¤ndert; behoben wurden
ausschlieÃŸlich die API-BrÃ¼che zwischen Vendor-6.1 und Mainline-7.3 â€” plus eine
Reihe klar markierter Fehler im Vendor-Code.

BestÃ¤tigt: **IR-Empfang** auf einer **X88PRO13 (RK3528)** mit
Armbian `7.3.0-rc7-edge-rockchip64` (Einrichtung siehe unten). Suspend/Resume,
Wakeup Ã¼ber IR, Repeat-Verhalten und Teardown sind nicht separat getestet
(Details im Abschnitt [Teststatus](#teststatus-und-einschrÃ¤nkungen)).

---

## Inhalt

- [Funktionsumfang](#funktionsumfang)
- [V1 vs. V4 â€” der wichtigste Stolperstein](#v1-vs-v4--der-wichtigste-stolperstein)
- [Installation](#installation)
- [Device-Tree-Konfiguration](#device-tree-konfiguration)
- [Debugging](#debugging)
- [API-Ã„nderungen 6.1 â†’ 7.3](#api-Ã¤nderungen-61--73)
- [Mitgefallene Vendor-Fehler](#mitgefallene-vendor-fehler)
- [Teststatus und EinschrÃ¤nkungen](#teststatus-und-einschrÃ¤nkungen)
- [Lizenz](#lizenz)
- [Danksagung](#danksagung)

---

## Funktionsumfang

Der Treiber nutzt einen PWM-Kanal im Capture-Modus, um NEC-codierte
IR-Fernbedienungssignale zu dekodieren, und meldet die Tasten als Standard-Input-Events
(`evtest`, LXDE/GNOME/Kodi, Domoticz-Bindings usw. kÃ¶nnen sie direkt nutzen).

- NEC-Protokoll, mehrere Fernbedienungen parallel (Key-Tables aus dem DT)
- Pwrkey-Capture (Aufwecken aus dem Suspend, v4-Hardware) bzw. ATF-/SIP-Wakeup-Pfad
  (`remote_support_psci`)
- `wakeup-source`-UnterstÃ¼tzung
- LÃ¤uft als Modul (`rockchip_pwm_remotectl.ko`) oder eingebaut

## V1 vs. V4 â€” der wichtigste Stolperstein

Der Treiber enthÃ¤lt zwei Hardware-Varianten mit **vÃ¶llig unterschiedlichen
Registerlayouts**:

| | PWM v1 (alte SoCs) | PWM v4 (neuere SoCs) |
|---|---|---|
| Register | HPR 0x04, LPR 0x08, CTRL 0x0c; gemeinsames INT_EN des PWM-Blocks (PWM3: Kanalbasis +0x14) | ENABLE 0x04, CTRL 0x0c, INT_EN 0x74 |
| Zuordnung | Ã¤ltere PWM-IPs (RK3328-kompatibel â€” **dazu zÃ¤hlt der RK3528**) | neuere PWM-IPs mit v4-Registerlayout |
| DT-Property `remote_pwm_id` | wird gelesen | wird ignoriert |

Welche Variante geladen wird, entscheidet **die Reihenfolge der Compatibles
im Device-Tree** â€” das erste passende Compatible gewinnt die
OF-Matching-Bewertung.

**Achtung, RK3528:** Obwohl der RK3528 ein neuer SoC ist, ist sein PWM-IP
laut [rk3528.dtsi](https://github.com/armbian/linux-rockchip/blob/rk-6.1-rkr7.2/arch/arm64/boot/dts/rockchip/rk3528.dtsi)
**registerkompatibel mit dem RK3328** (`compatible = "rockchip,rk3528-pwm",
"rockchip,rk3328-pwm"`) â€” der RK3528 lÃ¤uft also im **v1-Pfad**. Richtig ist:

```dts
compatible = "rockchip,remotectl-pwm", "rockchip,remotectl-pwm-v4";
```

(v1 zuerst â€” genau so steht es auch im Vendor-DTS des [joilg/x88pro](https://github.com/joilg/x88pro)-Projekts.)

**Symptom bei falscher Wahl** (nur `-v4`): Der Treiber lÃ¤dt fehlerfrei, das
Input-Device erscheint in `evtest`, dmesg meldet `Controller support pwrkey
capture` â€” aber es kommen **keine IR-Events an**. Ursache: Die v4-`init_hw`
schreibt an Offset 0x04 â€” im v1-Layout ist das das HPR-Periodenregister statt
eines Enable-Registers; das echte Interrupt-Enable wird nie gesetzt, die
Capture lÃ¶st keinen IRQ aus.

## Installation

### Voraussetzungen

- Linux-Kernel-Header des laufenden Kernels (z. B.
  `linux-headers-$(uname -r)`)
- `build-essential` (bzw. gcc + make)

### Variante A: DKMS (empfohlen)

DKMS braucht neben den Quellen zwei Zusatzdateien im Paketverzeichnis:

`dkms.conf`:

```text
PACKAGE_NAME="rk-remotectl"
PACKAGE_VERSION="7.3"
BUILT_MODULE_NAME[0]="rockchip_pwm_remotectl"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
```

Mit `MAKE[0]` ruft DKMS den Kbuild im Kernel-Quellverzeichnis auf â€” ein nacktes
`obj-m`-Makefile allein ist fÃ¼r einen gewÃ¶hnlichen `make`-Aufruf nicht
ausfÃ¼hrbar.

`Makefile` (AuÃŸerhalb-des-Kernel-Baums, DKMS-Modus â€” das In-tree-Makefile
aus dem Patch mit `obj-$(CONFIG_â€¦)` funktioniert hier nicht, weil die
Distribution den Schalter nicht setzt):

```make
obj-m := rockchip_pwm_remotectl.o
```

```bash
sudo apt install dkms
git clone https://github.com/<dein-fork>/rk-remotectl.git
sudo cp -r rk-remotectl /usr/src/rk-remotectl-7.3
sudo dkms add -m rk-remotectl -v 7.3
sudo dkms build  -m rk-remotectl -v 7.3
sudo dkms install -m rk-remotectl -v 7.3
```

Nach Kernel-Updates wird das Modul automatisch neu gebaut.

### Variante B: Direktbau gegen die Kernel-Header

Voraussetzung ist ein `Makefile` fÃ¼r den AuÃŸerhalb-des-Baums-Bau (siehe
Variante A â€” `obj-m := rockchip_pwm_remotectl.o`); das In-tree-Makefile des
Patches baut auÃŸerhalb des Kernel-Baums nichts, weil
`CONFIG_ROCKCHIP_REMOTECTL_PWM` im Distributionskernel nicht gesetzt ist:

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo cp rockchip_pwm_remotectl.ko /lib/modules/$(uname -r)/
sudo depmod -a
sudo modprobe rockchip_pwm_remotectl
```

### Im Kernel-Baum (Patch)

```bash
git clone --depth=1 --branch v7.3 https://github.com/torvalds/linux.git linux-7.3
cd linux-7.3
git apply 0001-input-rockchip-add-pwm-remotectl-driver-for-v7.3.patch
make ARCH=arm64 CROSS_COMPILE=<aarch64-...>- defconfig
./scripts/config -m ROCKCHIP_REMOTECTL -m ROCKCHIP_REMOTECTL_PWM
make ARCH=arm64 CROSS_COMPILE=<aarch64-...>- olddefconfig
make ARCH=arm64 CROSS_COMPILE=<aarch64-...>- M=drivers/input/remotectl modules
```

Hinweis zu MODPOST: â€žsymbol â€¦ undefinedâ€œ kann zwei verschiedene Ursachen
haben. (a) Gegen Distributions-Header (DKMS, Variante A) liefert das
Header-Paket die `Module.symvers` mit â€” ein dann gemeldetes Symbol ist
wirklich nicht exportiert (genau so fiel der `irq_to_desc`-Fehler aus,
siehe [API-Ã„nderungen](#api-Ã¤nderungen-61--73)). (b) In einem frisch
geklasten Kernelbaum ohne Vollbuild fehlt die Symboltabelle komplett, und
MODPOST meldet sÃ¤mtliche Symbole. In diesem Fall nur gegen ein vollstÃ¤ndig
gebautes Kernel-Verzeichnis bauen; `KBUILD_MODPOST_WARN=1` dient
ausschlieÃŸlich dem Kompilierungstest (`.o`) und beweist keine Ladbarkeit â€”
es unterdrÃ¼ckt auch echte Fehler.

Die Build-Integration hÃ¤ngt den Treiber unter `drivers/input/remotectl/` ein
(`menuconfig ROCKCHIP_REMOTECTL`, `depends on ARCH_ROCKCHIP || COMPILE_TEST`).

## Device-Tree-Konfiguration

Beispiel fÃ¼r die X88PRO13 (PWM3):

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
		/* Paare <Scancode Keycode>; hier: Scancode 0xf4 = KEY_POWER */
		rockchip,key_table = <0xf4 0x74>;
	};
};
```

Weitere Tasten und weitere `ir_keyN`-Knoten (weitere Fernbedienungen) werden
analog ergÃ¤nzt â€” die vollstÃ¤ndigen Tabellen der X88PRO13-Fernbedienungen
finden sich im [joilg/x88pro](https://github.com/joilg/x88pro)-Projekt.

| Property | Bedeutung |
|---|---|
| `compatible` | v1 **vor** v4 (siehe oben); beim RK3528 entscheidet die Reihenfolge |
| `remote_pwm_id` | PWM-Kanal (nur v1-Pfad; `remote_pwm_id = <3>` fÃ¼r PWM3) |
| `handle_cpu_id` | CPU-Kern, auf dem der IRQ pinned wird |
| `remote_support_psci` | `1` = ATF-Wakeup-Pfad (SMC `0x8200000b`) aktivieren |
| `wakeup-source` | Aufwecken aus dem Suspend per IR |
| `rockchip,usercode` | NEC-Adresswort der Fernbedienung (hex) |
| `rockchip,key_table` | Paare `<Scancode Keycode>`; Keycodes als Linux-Input-Codes gemÃ¤ÃŸ `include/uapi/linux/input-event-codes.h` (z. B. `0x74` = KEY_POWER, `0x1c` = KEY_ENTER, `0x184` = KEY_TEXT) |

Mehrere `ir_keyN`-Knoten erlauben mehrere Fernbedienungen parallel. Die
Keycodes folgen der Linux-Input-Historie (`include/uapi/linux/input-event-codes.h`).

## Debugging

Die `/sys/module/<modulname>/parameters/`-Pfade richten sich nach dem Namen
des tatsÃ¤chlich gebundenen Moduls. Der Modulname lÃ¤sst sich am GerÃ¤t ablesen:

```bash
readlink -f /sys/bus/platform/devices/ffa90030.pwm/driver/module
```

```bash
# Modul-Parameter: zusÃ¤tzliche Decoder-/Treiberausgaben im Kernel-Log
echo 1 > /sys/module/rockchip_pwm_remotectl/parameters/code_print
echo 4 > /sys/module/rockchip_pwm_remotectl/parameters/dbg_level

# LÃ¤uft der IRQ? (ZÃ¤hler muss bei Tastendruck steigen)
cat /proc/interrupts | grep pwm_rc

# Events prÃ¼fen
evtest /dev/input/by-path/*ffa90030*

# dmesg
dmesg | grep -i "remotectl\|pwm"
```

Typische dmesg-Bilder:

- `Controller support pwrkey capture` â†’ Treiber lÃ¤uft im **v4-Pfad**. Auf dem
  RK3528 ist das das Symptom eines falschen Compatibles (siehe oben).
- `Donot support ATF Wakeup` â†’ normal bei `remote_support_psci = <0>`;
  der Kernel-Capture-Pfad Ã¼bernimmt die IR-Auswertung.

## API-Ã„nderungen 6.1 â†’ 7.3

Reine API-Migration (Details im [Port-Diff](0000-vendor-to-7.3-port.diff)):

1. **Wake-Lock-API entfernt** (Mainline hat kein `wakelock.h`):
   `wake_lock_timeout(â€¦, HZ)` â†’ `pm_wakeup_event(dev, MSEC_PER_SEC)`
2. **`from_timer()` existiert nicht mehr**: `container_of()`-Muster
3. **`.remove` muss `void` sein** (seit 6.11)
4. **`del_timer_sync()` heiÃŸt jetzt** `timer_delete_sync()`
5. **`irq_set_affinity_hint()` deprecated**: `irq_set_affinity()` (die
   `_and_hint`-Variante speichert den cpumask-Zeiger dauerhaft â€” mit der
   Stack-Adresse des Vendor-Codes wÃ¤re das ein hÃ¤ngender Zeiger)
6. **Rockchip-SIP-Layer ersetzt** (`include/linux/rockchip/rockchip_sip.h`
   ist Vendor-only): `sip_smc_remotectl_config()` lokal Ã¼ber
   `arm_smccc_smc(SIP_REMOTECTL_CFG=0x8200000b, func, data, â€¦)` â€” Registerlayout
   und Fallback-Verhalten identisch zur
   [Vendor-Implementierung](https://github.com/rockchip-linux/kernel/blob/develop-6.1/drivers/firmware/rockchip_sip.c)
7. **`irq_to_desc()` ersetzt durch `irq_get_irq_data()`**: Bei
   `CONFIG_SPARSE_IRQ=y` (Standard bei arm64) ist `irq_to_desc()` nur unter
   `CONFIG_KVM_BOOK3S_64_HV_MODULE` exportiert â€” der DKMS-Build scheitert
   sonst mit `modpost: symbol 'irq_to_desc' undefined`. Beide liefern
   `irq_data->hwirq`/`irq_data->domain`, `irq_get_irq_data()` ist bedingungslos
   GPL-exportiert
8. **Kosmetik**: Duplikat-Includes, `pr_err`-Boot-Banner â†’ `dev_info()`,
   `MODULE_DESCRIPTION()` ergÃ¤nzt

Bewusst unverÃ¤ndert: Tasklets (deprecated, aber in 7.3 vorhanden; Umstellung
auf threaded IRQs wÃ¤re ein eigenes Projekt), `input_event()`-Aufrufe und die
v1/v4-Registerlogik.

## Mitgefallene Vendor-Fehler

Im Port behoben und im Code kommentiert:

- **Leerer Remove-Callback**: sauberer Teardown â€” Capture-Engine quiescen,
  bedingtes `disable_irq_wake()`, `devm_free_irq()` (kein globales
  `disable_irq()`, da v1 mit `IRQF_SHARED` auf der gemeinsamen PWM-Leitung
  lÃ¤uft), Tasklet killen, Timer lÃ¶schen
- **`module_platform_driver_probe` â†’ `module_platform_driver`** mit echtem
  `.probe`/`.remove`
- **`rk_pwm_clk_ctrl_v4()` auf v1-Hardware aufgerufen** (Suspend/Resume):
  jetzt `pwm_version >= 4`-Guard
- **Uninitialisiertes `cpu_id`** bei fehlendem DT-Property â†’ `cpu_id = 0`
- **Ignorierter RÃ¼ckgabewert** der Key-Table-Parsung â†’ Probe bricht ab
- **`enable_irq_wake()` ungeprÃ¼ft** â†’ Fehler protokolliert, symmetrischer
  Teardown Ã¼ber `irq_wake_enabled`

## Teststatus und EinschrÃ¤nkungen

- Kompiliert ohne Warnungen gegen Linux v7.3 (Bootlin aarch64, GCC 15.3.0);
  der Patch wurde per `git apply --check` gegen ein sauberes, frisches
  v7.3-Checkout verifiziert
- **Laufzeit bestÃ¤tigt** auf X88PRO13/RK3528 mit Armbian 7.3.0-rc7-edge:
  IR-Empfang funktioniert (v1-Pfad, siehe [V1 vs. V4](#v1-vs-v4--der-wichtigste-stolperstein))
- Nicht getestet: Suspend/Resume-Wakeup Ã¼ber IR, ATF-Pwrkey-Pfad
  (`remote_support_psci = 1`), Verhalten auf v4-Hardware
- Der MODPOST-Durchlauf beim DKMS-Bau gegen Distributions-Kernel setzt eine
  intakte `Module.symvers` der Kernel-Header voraus (Standardfall)

## Lizenz

**GPL-2.0** â€” die Quelldateien tragen
`SPDX-License-Identifier: GPL-2.0` (`.c` und `.h`), die Modul-Deklaration ist
`MODULE_LICENSE("GPL")`. Die Copyright- und SPDX-Header der
Rockchip-/Armbian-Autoren sind erhalten; die verÃ¶ffentlichte Fassung muss
unter GPL-2.0 bleiben. FÃ¼r die VerÃ¶ffentlichung eine `LICENSE`-Datei mit dem
GPL-2.0-Text mit ins Repo legen.

## Danksagung

- Ursprung: [armbian/linux-rockchip](https://github.com/armbian/linux-rockchip),
  Branch `rk-6.1-rkr7.2` (Commit `85233a85`) â€” dort liegt der unverÃ¤nderte
  Vendor-Treiber
- Kontext Board-Support: [joilg/x88pro](https://github.com/joilg/x88pro)
  (Armbian fÃ¼r die X88PRO13)
- Die Portierung auf Linux 7.3 (API-Migration, Modul-Symbol-Verifikation,
  DKMS-Fix `irq_to_desc` â†’ `irq_get_irq_data` und die V1/V4-Diagnose) entstand
  mit UnterstÃ¼tzung von [Perplexity Computer](https://www.perplexity.ai/).

## Quellen

- [Vendor-Treiber rk-6.1-rkr7.2](https://github.com/armbian/linux-rockchip/blob/rk-6.1-rkr7.2/drivers/input/remotectl/rockchip_pwm_remotectl.c)
- [Vendor-SIP-Implementierung](https://github.com/rockchip-linux/kernel/blob/develop-6.1/drivers/firmware/rockchip_sip.c)
- [rk3528.dtsi â€” PWM als rk3328-kompatibel](https://github.com/armbian/linux-rockchip/blob/rk-6.1-rkr7.2/arch/arm64/boot/dts/rockchip/rk3528.dtsi)
- [Linux v7.3](https://github.com/torvalds/linux/tree/v7.3)
- [Bootlin-Toolchains](https://toolchains.bootlin.com/)
