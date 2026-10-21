#!/bin/bash
# Build the shim and wrap it in a boot.img v4 for Lenovo Legion Y70 (halo, SM8475).
# Compatible with both macOS (clang + aarch64-elf-binutils) and Linux (aarch64-linux-gnu-gcc).
set -euo pipefail
cd "$(dirname "$0")"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	CC="aarch64-linux-gnu-gcc"
	LD="aarch64-linux-gnu-ld"
	OBJCOPY="aarch64-linux-gnu-objcopy"
	READELF="aarch64-linux-gnu-readelf"
	NM="aarch64-linux-gnu-nm"
elif command -v aarch64-elf-ld >/dev/null 2>&1; then
	CC="clang --target=aarch64-none-elf"
	LD="aarch64-elf-ld"
	OBJCOPY="aarch64-elf-objcopy"
	READELF="aarch64-elf-readelf"
	NM="aarch64-elf-nm"
else
	echo "error: No suitable aarch64 cross-toolchain found" >&2
	exit 1
fi

CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c "$f" -o "out/${f%.*}.o"
done

# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }

$LD -T shim.ld --build-id=none --no-warn-rwx-segments -N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf

$OBJCOPY -O binary out/shim.elf out/Image

# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$((16#$($NM out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image

# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	# ABL passes vendor_boot ramdisk for v4: append payload behind the Image at
	# the first 4K boundary after _end (loader.c) and grow image_size.
	truncate -s $(( (size + 0xfff) & ~0xfff )) out/Image
	cat "$1" >> out/Image
	python3 -c 'import os,struct,sys; f=open(sys.argv[1],"r+b"); f.seek(16); f.write(struct.pack("<Q", os.path.getsize(sys.argv[1])))' out/Image
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi

MKBOOTIMG="${MKBOOTIMG:-python3 ../tools/mkbootimg.py}"
$MKBOOTIMG --header_version 4 --kernel out/Image --ramdisk out/ramdisk.bin \
	--os_version 13.0.0 --os_patch_level 2025-01 \
	--cmdline "console=null" -o out/shim-boot.img

# Host render of the console layout
${HOSTCC:-clang} -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
