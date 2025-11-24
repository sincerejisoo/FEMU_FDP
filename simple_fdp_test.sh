#!/bin/bash
# Simple FDP Statistics Test
# Run this INSIDE the VM to verify FDP statistics tracking

NVME_NS="/dev/nvme0n1"

echo "================================================"
echo "  Simple FDP Statistics Test"
echo "================================================"
echo ""

# Enable FDP
echo "[1/5] Enabling FDP..."
sudo nvme admin-passthru /dev/nvme0 --opcode=0xef --cdw10=8 > /dev/null 2>&1
sudo nvme id-ctrl /dev/nvme0 | grep oncs
echo ""

# Get initial statistics
echo "[2/5] Getting initial FDP statistics..."
sudo nvme get-log /dev/nvme0 --log-id=0x21 --log-len=4096 -b > /tmp/fdp_stats_before.bin
# host_bytes_written[16] starts at offset 0
# RU 0 = offset 0, RU 1 = offset 8, RU 2 = offset 16, RU 3 = offset 24
# Parse as little-endian uint64
RU0_BEFORE=$(od -An -t x8 -N 8 -j 0 /tmp/fdp_stats_before.bin | tr -d ' ')
RU1_BEFORE=$(od -An -t x8 -N 8 -j 8 /tmp/fdp_stats_before.bin | tr -d ' ')
echo "  RU 0 before: 0x$RU0_BEFORE"
echo "  RU 1 before: 0x$RU1_BEFORE"
echo ""

# Perform test writes
echo "[3/5] Writing test data..."
echo "  Writing 10 blocks to RU 0 (PH=0)..."
for i in {1..10}; do
    sudo nvme write $NVME_NS --start-block=$((i * 1000)) --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=0 > /dev/null 2>&1
done

echo "  Writing 20 blocks to RU 1 (PH=1)..."
for i in {1..20}; do
    sudo nvme write $NVME_NS --start-block=$((100000 + i * 1000)) --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=1 > /dev/null 2>&1
done
echo "  Writes completed!"
echo ""

# Get final statistics
echo "[4/5] Getting final FDP statistics..."
sleep 1  # Give FEMU a moment to update statistics
sudo nvme get-log /dev/nvme0 --log-id=0x21 --log-len=4096 -b > /tmp/fdp_stats_after.bin
RU0_AFTER=$(od -An -t x8 -N 8 -j 0 /tmp/fdp_stats_after.bin | tr -d ' ')
RU1_AFTER=$(od -An -t x8 -N 8 -j 8 /tmp/fdp_stats_after.bin | tr -d ' ')
echo "  RU 0 after:  0x$RU0_AFTER"
echo "  RU 1 after:  0x$RU1_AFTER"
echo ""

# Calculate differences
echo "[5/5] Analysis..."
RU0_DIFF=$((0x$RU0_AFTER - 0x$RU0_BEFORE))
RU1_DIFF=$((0x$RU1_AFTER - 0x$RU1_BEFORE))

echo "  RU 0 delta: $RU0_DIFF bytes"
echo "  RU 1 delta: $RU1_DIFF bytes"
echo ""

# Expected: 10 writes × 4KB = 40,960 bytes for RU 0
# Expected: 20 writes × 4KB = 81,920 bytes for RU 1

if [ $RU0_DIFF -gt 0 ] && [ $RU1_DIFF -gt 0 ]; then
    echo "✓ SUCCESS: FDP statistics are being tracked!"
    echo "  Expected RU 0: ~40,960 bytes (10 × 4KB)"
    echo "  Expected RU 1: ~81,920 bytes (20 × 4KB)"
elif [ $RU0_DIFF -eq 0 ] && [ $RU1_DIFF -eq 0 ]; then
    echo "✗ FAILURE: Statistics are still zero!"
    echo ""
    echo "This means either:"
    echo "  1. DMA fix wasn't applied correctly"
    echo "  2. Writes aren't using FDP directives"
    echo "  3. Statistics aren't being incremented in FTL"
    echo ""
    echo "Check FEMU console/dmesg for debug messages:"
    echo "  dmesg | grep -E 'FEMU-FDP|FDP.*Write' | tail -30"
else
    echo "⚠ PARTIAL: Some statistics updated"
    echo "  This might indicate an issue with PH routing"
fi

echo ""
echo "================================================"
echo "Test complete!"
echo "================================================"

