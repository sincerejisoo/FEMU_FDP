#!/bin/bash
#
# Check FEMU logs for crash cause
#

LOG_FILE="$HOME/POSTECH/FEMU/build-femu/log"

echo "========================================"
echo "  Analyzing FEMU Crash Logs"
echo "========================================"
echo ""

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    exit 1
fi

echo "1. Checking for 'out of free lines' errors..."
grep "out of free lines" "$LOG_FILE" | tail -10
echo ""

echo "2. Checking for GC activity..."
GC_COUNT=$(grep -c "GC-ing line" "$LOG_FILE" || echo "0")
echo "   Total GC cycles: $GC_COUNT"
if [ $GC_COUNT -gt 0 ]; then
    echo "   Last 5 GC cycles:"
    grep "GC-ing line" "$LOG_FILE" | tail -5 | sed 's/^/   /'
fi
echo ""

echo "3. Checking for RU-aware GC returns..."
RU_RETURNS=$(grep -c "Returned line.*to RU" "$LOG_FILE" || echo "0")
echo "   RU-aware returns: $RU_RETURNS"
if [ $RU_RETURNS -gt 0 ]; then
    echo "   Last 5 returns:"
    grep "Returned line.*to RU" "$LOG_FILE" | tail -5 | sed 's/^/   /'
else
    echo "   ⚠️  NO RU-AWARE RETURNS FOUND!"
    echo "   This means GC is NOT returning lines to RUs"
    echo "   RU-aware GC implementation may have a bug"
fi
echo ""

echo "4. Checking FDP distribution..."
grep "FDP.*Distributing" "$LOG_FILE" | tail -3
echo ""

echo "5. Last 20 lines of log (crash context)..."
tail -20 "$LOG_FILE"
echo ""

echo "========================================"
echo "  Diagnosis"
echo "========================================"
echo ""

if [ $RU_RETURNS -eq 0 ] && [ $GC_COUNT -gt 0 ]; then
    echo "❌ CRITICAL: GC triggered but NOT returning lines to RUs"
    echo ""
    echo "   This means:"
    echo "   - GC is running"
    echo "   - But freed lines go to GLOBAL pool"
    echo "   - RUs cannot access them"
    echo "   - RUs run out of lines → crash"
    echo ""
    echo "   Root cause: RU-aware GC implementation bug"
    echo ""
    echo "   Check these functions:"
    echo "   - mark_line_free() in ftl.c"
    echo "   - Should check line->ru_owner"
    echo "   - Should return to RU's free list"
    echo ""
elif [ $GC_COUNT -eq 0 ]; then
    echo "⚠️  NO GC ACTIVITY"
    echo ""
    echo "   This means:"
    echo "   - No victim lines available"
    echo "   - GC cannot reclaim space"
    echo "   - Device truly full"
    echo ""
    echo "   Root cause: Pre-fill didn't create victims"
    echo "   Or victims not in the RU that needs them"
    echo ""
else
    echo "✓ RU-aware GC appears to be working"
    echo "   $RU_RETURNS lines returned to RUs"
    echo ""
    echo "   Crash might be due to:"
    echo "   - Workload too aggressive"
    echo "   - Not enough victim lines"
    echo "   - Or other issue"
fi
echo ""

