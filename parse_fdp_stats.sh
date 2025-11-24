#!/bin/bash
# Parse FDP Statistics Log properly

if [ ! -f /tmp/fdp_stats_after.bin ]; then
    echo "Error: /tmp/fdp_stats_after.bin not found"
    echo "Run this INSIDE the VM after running simple_fdp_test.sh"
    exit 1
fi

echo "=== FDP Statistics Log Analysis ==="
echo ""

# Show file size
SIZE=$(stat -c%s /tmp/fdp_stats_after.bin)
echo "File size: $SIZE bytes"
echo ""

# Show first 512 bytes in hex
echo "First 512 bytes of log (hex dump):"
xxd -l 512 /tmp/fdp_stats_after.bin
echo ""

# NvmeFdpStatsLog structure:
# Each RU has multiple 8-byte fields
# Offset calculation for 16 RUs:
# RU[i].host_bytes_written is at offset: i * 272 bytes (assuming structure packing)

echo "=== Parsing RU Statistics ==="
for i in 0 1 2 3; do
    # Try different offsets to find the right structure layout
    OFFSET=$((i * 272))
    
    echo ""
    echo "RU $i (trying offset $OFFSET):"
    xxd -s $OFFSET -l 64 /tmp/fdp_stats_after.bin | head -4
done

echo ""
echo "=== Alternative: Try every 8 bytes for first 512 bytes ==="
for OFFSET in 0 8 16 24 32 40 48 56 64 72 80 88 96 104 112 120 128 136 144 152 160; do
    VAL=$(xxd -s $OFFSET -l 8 -e /tmp/fdp_stats_after.bin 2>/dev/null | awk '{print $2$3}' | tr -d '\n')
    if [ -n "$VAL" ] && [ "$VAL" != "0000000000000000" ]; then
        echo "Offset $OFFSET: 0x$VAL ($(printf '%d' 0x$VAL) bytes)"
    fi
done

