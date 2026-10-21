# ios-halo

**Apple's iOS 16 running on Lenovo Legion Y70 (Snapdragon 8+ Gen 1 / SM8475 "halo").**

This is an adaptation of [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz) and [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) (Apple's open-source XNU kernel, xnu-8796) for the **Lenovo Legion Y70** (`halo` / `L71091`, Qualcomm **SM8475** / Snapdragon 8+ Gen 1).

On top of XNU runs the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X (D22AP)**: `launchd`, system daemons, `backboardd`, and `SpringBoard`.

---

## Hardware Specifications & Architecture

| Component | Hardware details | Address / Mapping |
| :--- | :--- | :--- |
| **SoC / Chipset** | Qualcomm SM8475 (Snapdragon 8+ Gen 1) | ARMv9.0-A |
| **CPU Cluster** | 1x Cortex-X2 + 3x Cortex-A710 + 4x Cortex-A510 | MPIDR `0x000, 0x100, ... 0x700` (8 cores, all with 16K translation granule) |
| **GIC (Interrupts)** | ARM GICv3 / GIC-600 | GICD `0x17100000` (64K), GICR `0x17180000` (2MB, 256K stride) |
| **Timer** | Generic ARMv8 Arch Timer | Frequency: 19.2 MHz (`19200000`), VTIMER INTID: `27` |
| **Display / Framebuffer**| 1080x2400 AMOLED (Continuous splash) | Physical address: `0xb8000000`, size `0x2b00000` (43 MB), stride 4320 |
| **Internal Storage** | Universal Flash Storage (UFS 3.1) | `ufshc@1d84000` (`0x01d84000`) |
| **Touchscreen** | Goodix GT9916 (`0x5d`) | QUPv3 GENI SE4 I2C (`0x00990000`), Reset GPIO 20, IRQ GPIO 21 |
| **Boot Mode** | ABL -> Android Boot Image v4 | `fastboot boot shim-boot.img` |

---

## Why Legion Y70 (SM8475) is superior for iOS/XNU

1. **Native 16KB Pages on ALL 8 Cores**: Unlike Cortex-A53 (which lacked `TGran16`), Cortex-A510, A710, and X2 all natively support the 16KB translation granule required by iOS. All 8 cores can participate in SMP.
2. **Native ARMv8.5-A / LSE Atomics**: iPhone X userland binaries use LSE atomic instructions (`cas`, `ldadd`, `swp`, `ldapr`). On SM8475 they execute in hardware with zero overhead and no emulation traps needed.
3. **High RAM Capacity (8GB / 12GB / 16GB)**: Ample memory for the kernel, page tables, and iOS userland caching without tight carveout restrictions.

---

## How to Build and Run

### 1. Build the Diagnostic Boot Shim

The boot shim is a bare-metal payload that initializes the GIC, verifies 16KB granule support, probes UFS partitions, and sets up the handoff to XNU.

```bash
./shim/build.sh
```

Output: `shim/out/shim-boot.img`

To test boot on the unlocked device:
```bash
adb reboot bootloader
fastboot boot shim/out/shim-boot.img
```

The screen will turn red and display CPU registers (`MIDR`, `MMFR0`), GIC state, and partition table detected on UFS.

### 2. Generate the Apple Device Tree (ADT)

```bash
python3 tools/mkadt.py shim/out/halo.adt --halo
```

### 3. Build the XNU Kernel

The kernel builds via GitHub Actions on macOS runners using `.github/workflows/xnu.yml`.
Artifact: `kernel.development.sweet`

### 4. Pack Kernel Payload and Boot Image

```bash
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/halo.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60'

./shim/build.sh ../shim/out/payload.bin
```

### 5. Flash iOS Root and Boot

Download the iPhone X iOS 16.7.16 IPSW and generate the root image:
```bash
sudo bash tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg

# Flash into userdata partition (wipes existing Android data):
fastboot -S 512M flash userdata ios16-root.simg
fastboot boot shim/out/shim-boot.img
```
