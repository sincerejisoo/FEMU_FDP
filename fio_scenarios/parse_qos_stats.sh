#!/bin/bash
# Parse the FDP statistics from the QoS test that already ran

STATS_FILE="/home/femu/fio_scenarios/fdp_qos_results_20251118_192049/fdp_stats_after.bin"

if [ ! -f "$STATS_FILE" ]; then
    echo "Stats file not found. Run inside VM."
    exit 1
fi

echo "=== FDP Statistics from QoS Test ==="
echo ""
echo "Parsing: $STATS_FILE"
echo ""

for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET "$STATS_FILE" 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
    
    echo "RU $i: 0x$VAL bytes ($DEC bytes = ${MB} MB)"
done

echo ""
echo "Expected:"
echo "  RU 0: ~5.9 MB (1,451 writes × 4KB)"
echo "  RU 1: ~23 MB (5,734 writes × 4KB)"
