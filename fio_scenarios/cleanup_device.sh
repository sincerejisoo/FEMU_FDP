#!/bin/bash
#
# Cleanup NVMe Device Before FDP Testing
# This clears all existing data and resets the FTL
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"

echo "================================================"
echo "  NVMe Device Cleanup for FDP Testing"
echo "================================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "[ERROR] Please run as root (sudo)"
    exit 1
fi

# Check device exists
if [ ! -b "$NVME_NS" ]; then
    echo "[ERROR] Device $NVME_NS not found"
    exit 1
fi

echo "[WARNING] This will ERASE ALL DATA on $NVME_NS"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "================================================"
echo "  Step 1: Disable FDP (if enabled)"
echo "================================================"
echo ""

nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1 || true
oncs=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo "[INFO] FDP status: ONCS=$oncs"

echo ""
echo "================================================"
echo "  Step 2: TRIM/Discard Entire Device"
echo "================================================"
echo ""

echo "[INFO] Getting device size..."
size_bytes=$(blockdev --getsize64 $NVME_NS 2>/dev/null || echo "12884901888")
size_gb=$((size_bytes / 1024 / 1024 / 1024))
echo "[INFO] Device size: ${size_gb}GB (${size_bytes} bytes)"

echo "[INFO] Issuing TRIM/discard command..."
echo "[INFO] This may take 30-60 seconds..."

# Use blkdiscard if available (fast)
if command -v blkdiscard &> /dev/null; then
    blkdiscard $NVME_NS 2>&1
    echo "[SUCCESS] TRIM completed using blkdiscard"
else
    # Fallback: write zeros to first and last blocks
    echo "[INFO] blkdiscard not found, using dd fallback..."
    dd if=/dev/zero of=$NVME_NS bs=1M count=100 oflag=direct 2>/dev/null
    echo "[SUCCESS] Wrote zeros to device start"
fi

echo ""
echo "================================================"
echo "  Step 3: Reset FEMU FTL (Optional)"
echo "================================================"
echo ""

echo "[INFO] To fully reset FEMU's FTL, you need to:"
echo "  1. Shutdown the VM (poweroff)"
echo "  2. Delete FEMU's backend file:"
echo "     rm /tmp/femu-blknvme0n1"
echo "  3. Restart FEMU"
echo ""
echo "[INFO] For now, we'll continue with TRIM only..."

echo ""
echo "================================================"
echo "  Step 4: Verify Device is Clean"
echo "================================================"
echo ""

# Read first block to verify
echo "[INFO] Reading first block..."
dd if=$NVME_NS bs=4096 count=1 2>/dev/null | hexdump -C | head -5

echo ""
echo "================================================"
echo "  Cleanup Complete!"
echo "================================================"
echo ""
echo "Device $NVME_NS is now clean and ready for testing."
echo ""
echo "Next steps:"
echo "  1. Run: sudo ./run_qos_comparison.sh"
echo "  2. Or consider increasing device size (see instructions below)"
echo ""

echo "================================================"
echo "  To Increase Device Size (Recommended)"
echo "================================================"
echo ""
echo "Current device size: ${size_gb}GB"
echo ""
echo "To increase to 24GB or 32GB:"
echo ""
echo "  1. Shutdown the VM:"
echo "     sudo poweroff"
echo ""
echo "  2. Edit FEMU run script:"
echo "     vim ~/POSTECH/FEMU/femu-scripts/run-blackbox.sh"
echo ""
echo "  3. Find the line with 'nvme0n1_sz' and change:"
echo "     -device nvme,...,num_queues=8"
echo "     Add or modify: -drive file=/tmp/femu-blknvme0n1,if=none,id=nvm,size=24G"
echo ""
echo "  4. Delete old backend file:"
echo "     rm /tmp/femu-blknvme0n1"
echo ""
echo "  5. Restart FEMU with the run script"
echo ""
echo "With 24GB, you can safely run:"
echo "  - Longer tests (300+ seconds)"
echo "  - Higher IOPS rates"
echo "  - Multiple test iterations"
echo ""

