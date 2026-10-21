# iOS 16 on Lenovo Legion Y70 (halo, SM8475) - working notes

## Project Goal
Boot unmodified Apple iOS 16.7.16 (20H392, iPhone X / D22AP userland) natively on the Lenovo Legion Y70 (Qualcomm Snapdragon 8+ Gen 1, SM8475 "halo" / L71091) using Apple's open-source XNU kernel (xnu-8796) and a bare-metal boot shim over Android Boot Image v4 via `fastboot boot`.

---

## Active Handoff & Current Status (2026-10-21)

### Hardware Facts (extracted from official DTB and DTBO dumps)
* **SoC**: Qualcomm SM8475 Snapdragon 8+ Gen 1 (ARMv9.0-A)
* **CPU Cluster**: 8 cores total
  * 4x Cortex-A510 (LITTLE, MPIDR `0x000, 0x100, 0x200, 0x300`)
  * 3x Cortex-A710 (MID, MPIDR `0x400, 0x500, 0x600`)
  * 1x Cortex-X2 (PRIME, MPIDR `0x700`)
  * **All 8 cores support 16K translation granule** (`TGran16 = 1`). No need to park cores like on SM6225.
  * **Native ARMv8.5-A / LSE atomics**: `cas`, `ldadd`, `swp`, `ldapr` supported in hardware. No software emulation traps.
* **GICv3 (GIC-600)**:
  * GICD: `0x17100000` (size 64 KiB, `0x10000`)
  * GICR: `0x17180000` (size 2 MiB, `0x200000`, 8 cores)
  * Redistributor Stride: **256 KiB (`0x40000`)** (4x 64KB pages per PE)
* **Timer**:
  * Architecture generic timer CNTFRQ: 19.2 MHz (`19200000`)
  * Virtual Timer INTID: `27` (PPI 11, `16 + 11 = 27`)
  * Physical Timer INTID: `26` (PPI 10, `16 + 10 = 26`)
* **Display / Continuous Splash**:
  * Base physical address: `0xb8000000` (size `0x2b00000` = 43 MiB)
  * Resolution: 1080x2400 AMOLED @ 32 bpp (stride 4320)
  * Virtual canvas presented to iOS: 1125x2436 (iPhone X canvas centered)
* **Internal Storage**:
  * UFS 3.1 Host Controller (`ufshc`): `0x01d84000` (size `0x3000`)
* **Touchscreen**:
  * Goodix GT9916 (`0x5d`) on QUPv3 GENI SE4 I2C (`0x00990000`)
  * Reset GPIO 20 (`0x14`), IRQ GPIO 21 (`0x15`)
* **Reset / Power Control**:
  * PSCI EL3 `SYSTEM_RESET` (SMC `0x84000009`)
  * IMEM restart reason: `0x146aa65cUL` (restart_reason@65c in `msm-imem@146aa000`)

---

## Milestones Achieved

### Milestone 1: Diagnostic Boot Shim
* **Artifact**: `shim/out/shim-boot.img` (196 KiB, Android boot image v4)
* **Status**: BUILT & READY FOR PHONE VERIFICATION.
* **Compiler**: Built using `clang --target=aarch64-none-elf` + `aarch64-elf-binutils` (ELF ld, objcopy, nm).
* **Fixes applied**:
  * `-fno-jump-tables` added to avoid Clang commoning strings into absolute `.rodata` pointer tables.
  * Inline `streq()` implemented in `ufs.c` to remove dependency on libc `strcmp`.
  * GICD/GICR, VTIMER, UFS, and FB_BASE constants remapped to SM8475.
  * Secondary core redistributor preparation implemented for all 8 cores.

### Milestone 2: Apple Device Tree (ADT) Generator
* **Artifact**: `tools/mkadt.py` with `--halo` flag.
* **Generated ADT**: `shim/out/halo.adt` (12,976 bytes).
* **Properties**:
  * Memory: 4 GiB upper bank at `0x100000000` (8GB+ RAM).
  * 8 CPU nodes (`cpu0`..`cpu7`) with exact MPIDRs and cluster IDs.
  * GICv3 node with INTID 27 and `0x40000` stride.
  * Framebuffer nub at `0xb8000000` (1080x2400).
  * UFS host node at `0x01d84000`.
  * Real Apple iPhone X `/product` node integrated: 63 authentic product and calibration properties extracted directly from `DeviceTree.d22ap.im4p` (iOS 16.7.16 20H392).
  * Identity: `D22AP` / `iPhone10,3` (`lenovo,halo`).

### Milestone 3: XNU Build Configuration & Patches
* **Workflow**: `.github/workflows/xnu.yml` updated to `-march=armv8.5-a`.
* **Patch 0081**: Tuned for SM8475: preserves native hardware PAN (`__ARM_PAN_AVAILABLE__ 1`) and native ARMv8.5-A `casa` atomic instructions in `commpage_asm.s` (no software emulation loops needed).
* **Patch 0004**: `GICR_PE_SIZE` updated to `0x40000` (256 KiB) for GIC-600.
* **GitHub Repository**: https://github.com/iHackFX/ios-halo (public)
* **CI Build Run**: Run ID [`39689272289`](https://github.com/iHackFX/ios-halo/actions/runs/39689272289), Job ID `119531118203` (in progress on `macos-14` runner).

---

## Next Concrete Actions (What to do without the phone)

1. **Prepare the iOS 16 Rootfs Image**:
   * Verified Apple CDN direct access to iOS 16.7.16 (20H392) IPSW via HTTP range requests.
   * `research/ipsw-x/d22ap.adt` decompressed and active.
   * Prepare/download the DMGs (`OS.dmg`, `SystemOS.dmg`, `AppOS.dmg`) when ready to construct `ios16-root.simg`.

2. **Trigger XNU Kernel Build**:
   * Authenticate / push the repo to GitHub (`gh auth login` or git push).
   * Run workflow `.github/workflows/xnu.yml`.
   * Download the compiled `kernel.development.sweet`.

3. **Pack Payload**:
   * Run `python3 tools/mkpayload.py kernel.development.sweet shim/out/halo.adt shim/out/payload.bin --cmdline "debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60"`.
   * Rebuild `shim/build.sh shim/out/payload.bin` to generate `shim-boot.img` containing the full XNU kernel!

4. **Prepare Touchscreen Driver for Goodix GT9916**:
   * Refine `sweet_touch.c` for GENI SE4 (`0x00990000`) and Goodix GT9916 protocol.
