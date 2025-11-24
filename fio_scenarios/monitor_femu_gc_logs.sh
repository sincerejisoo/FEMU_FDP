#!/bin/bash
#
# Real-time monitor for FEMU GC logs (run on HOST, not in VM)
# This script monitors the FEMU console output for GC-related messages
#

LOG_FILE="$HOME/POSTECH/FEMU/build-femu/log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "========================================================="
echo "  FEMU GC Activity Monitor (Real-time)"
echo "========================================================="
echo ""
echo "Monitoring: $LOG_FILE"
echo "Press Ctrl+C to stop"
echo ""
echo "Watching for:"
echo "  ${GREEN}✓${NC} GC activity (\"GC-ing line\")"
echo "  ${GREEN}✓${NC} RU-aware line returns (\"Returned line X to RU Y\")"
echo "  ${RED}✗${NC} Out of lines errors (\"out of free lines\")"
echo "  ${BLUE}ℹ${NC} FDP writes (\"[FDP] Write\")"
echo ""
echo "========================================================="
echo ""

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: FEMU log file not found at $LOG_FILE"
    echo "Make sure FEMU is running!"
    exit 1
fi

# Track statistics
GC_COUNT=0
RETURN_TO_RU_COUNT=0
ERROR_COUNT=0
FDP_WRITE_COUNT=0

# Monitor log file in real-time
tail -f "$LOG_FILE" 2>/dev/null | while read line; do
    # Check for GC activity
    if echo "$line" | grep -q "GC-ing line"; then
        GC_COUNT=$((GC_COUNT + 1))
        echo -e "${YELLOW}[GC]${NC} $line"
    fi
    
    # Check for RU-aware line returns (KEY MESSAGE!)
    if echo "$line" | grep -q "GC: Returned line.*to RU"; then
        RETURN_TO_RU_COUNT=$((RETURN_TO_RU_COUNT + 1))
        echo -e "${GREEN}[RU-GC]${NC} $line  ${GREEN}← RU-aware GC working!${NC}"
    fi
    
    # Check for errors
    if echo "$line" | grep -q "out of free lines"; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo -e "${RED}[ERROR]${NC} $line  ${RED}← Problem detected!${NC}"
    fi
    
    # Check for FDP writes (optional, high volume)
    if echo "$line" | grep -q "\[FDP\] Write"; then
        FDP_WRITE_COUNT=$((FDP_WRITE_COUNT + 1))
        # Only show every 100th to avoid spam
        if [ $((FDP_WRITE_COUNT % 100)) -eq 0 ]; then
            echo -e "${BLUE}[FDP]${NC} (${FDP_WRITE_COUNT} total FDP writes)"
        fi
    fi
    
    # Check for FDP distribution (informational)
    if echo "$line" | grep -q "\[FDP\] Distributing.*lines"; then
        echo -e "${CYAN}[FDP-INIT]${NC} $line"
    fi
    
    # Check for FDP enable/disable
    if echo "$line" | grep -q "vSSD0,FDP"; then
        echo -e "${CYAN}[FDP-STATE]${NC} $line"
    fi
done

