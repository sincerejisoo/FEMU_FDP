#!/bin/bash
#
# Analyze FEMU logs for GC behavior (post-test analysis)
# Run this AFTER debug_gc_behavior.sh to analyze results
#

LOG_FILE="${1:-$HOME/POSTECH/FEMU/build-femu/log}"

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    echo "Usage: $0 [log_file_path]"
    echo "Default: $HOME/POSTECH/FEMU/build-femu/log"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "========================================================="
echo "  FEMU GC Log Analysis"
echo "========================================================="
echo ""
echo "Analyzing: $LOG_FILE"
echo ""

# Extract GC statistics
GC_CYCLES=$(grep -c "GC-ing line" "$LOG_FILE" 2>/dev/null || echo "0")
RU_RETURNS=$(grep -c "Returned line.*to RU" "$LOG_FILE" 2>/dev/null || echo "0")
OUT_OF_LINES=$(grep -c "out of free lines" "$LOG_FILE" 2>/dev/null || echo "0")
FDP_WRITES=$(grep -c "\[FDP\] Write" "$LOG_FILE" 2>/dev/null || echo "0")

echo "=== GC Activity Summary ==="
echo ""
echo "  GC Cycles:            $GC_CYCLES"
echo "  RU-aware Returns:     $RU_RETURNS"
echo "  FDP Writes:           $FDP_WRITES"
echo "  Out of Lines Errors:  $OUT_OF_LINES"
echo ""

# Analyze RU return distribution
echo "=== RU Return Distribution ==="
echo ""
if [ $RU_RETURNS -gt 0 ]; then
    grep "Returned line.*to RU" "$LOG_FILE" 2>/dev/null | \
        sed 's/.*to RU \([0-9]\+\).*/\1/' | \
        sort | uniq -c | \
        awk '{printf "  RU %s: %s lines returned\n", $2, $1}'
else
    echo "  (No RU returns detected)"
fi
echo ""

# Show verdict
echo "=== Verdict ==="
echo ""

PASS=true

if [ $GC_CYCLES -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} No GC cycles detected"
    echo "     → Device may not have been full enough"
    echo "     → Try longer test or more pre-fill"
    PASS=false
elif [ $GC_CYCLES -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} GC triggered ($GC_CYCLES cycles)"
fi

if [ $RU_RETURNS -eq 0 ] && [ $GC_CYCLES -gt 0 ]; then
    echo -e "  ${RED}✗${NC} No RU-aware returns detected"
    echo "     → Lines went to global pool (broken!)"
    echo "     → RU-aware GC NOT working"
    PASS=false
elif [ $RU_RETURNS -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} RU-aware returns working ($RU_RETURNS returns)"
fi

if [ $OUT_OF_LINES -gt 0 ]; then
    echo -e "  ${RED}✗${NC} Out of lines errors ($OUT_OF_LINES times)"
    echo "     → RUs exhausted their line pools"
    echo "     → Critical failure!"
    PASS=false
else
    echo -e "  ${GREEN}✓${NC} No out of lines errors"
fi

if [ $FDP_WRITES -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} FDP writes detected ($FDP_WRITES writes)"
elif [ $FDP_WRITES -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} No FDP writes detected"
    echo "     → FDP may not have been enabled"
fi

echo ""
if [ "$PASS" = true ] && [ $RU_RETURNS -gt 0 ]; then
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  PASS: RU-aware GC is WORKING correctly! ✓${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
else
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
    echo -e "${RED}  FAIL: RU-aware GC has issues ✗${NC}"
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
fi
echo ""

# Show sample GC activity
if [ $RU_RETURNS -gt 0 ]; then
    echo "=== Sample GC Activity (first 5 returns) ==="
    echo ""
    grep "Returned line.*to RU" "$LOG_FILE" 2>/dev/null | head -5 | \
        sed 's/^/  /'
    echo ""
fi

# Helpful next steps
echo "=== Next Steps ==="
echo ""
if [ "$PASS" = true ] && [ $RU_RETURNS -gt 0 ]; then
    echo "  ✓ GC is working correctly!"
    echo "  → Proceed to full QoS test:"
    echo "    cd ~/fio_scenarios && sudo ./01_prefill_and_test.sh"
else
    echo "  ✗ GC needs debugging"
    echo "  → Check implementation in:"
    echo "    hw/femu/bbssd/ftl.c (mark_line_free function)"
    echo "    hw/femu/bbssd/bb.c (fdp_distribute_lines function)"
    echo "  → Recompile and test again"
fi
echo ""

