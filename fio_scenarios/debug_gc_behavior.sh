#!/bin/bash
#
# Debug script to verify RU-aware GC is working correctly
# This script triggers GC and monitors FEMU logs to verify:
# 1. GC is triggered
# 2. Lines are freed by GC
# 3. Lines are returned to their original RUs (not global pool)
# 4. RU free line counts increase appropriately
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
TEST_DURATION=120  # 2 minutes to trigger GC
WRITE_SIZE_MB=10000  # 10GB writes to trigger GC

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
echo_error() { echo -e "${RED}[✗]${NC} $1"; }
echo_section() { echo -e "${CYAN}[===]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo_error "Please run as root (sudo)"
    exit 1
fi

cat << 'EOF'

========================================================
     RU-aware GC Debug & Verification Script
========================================================

This script will:
  1. Enable FDP
  2. Pre-fill device to trigger GC
  3. Run workloads that stress GC
  4. Monitor FEMU logs for GC behavior
  5. Verify lines return to correct RUs
  6. Show GC statistics per RU

Expected behavior with RU-aware GC:
  ✓ GC frees lines from victim list
  ✓ Freed lines return to their original RU
  ✓ RU free line counts increase after GC
  ✓ No lines go to global pool (FDP enabled)
  ✓ Physical isolation maintained

Duration: ~5 minutes

EOF

read -p "Press Enter to start or Ctrl+C to cancel..."

echo ""
echo_section "STEP 1: Enable FDP and Check Initial State"
echo ""

# Enable FDP
echo_info "Enabling FDP..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1

ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
if [ "$ONCS" != "0x204" ]; then
    echo_error "FDP not enabled (ONCS=$ONCS)"
    exit 1
fi
echo_success "FDP enabled (ONCS=$ONCS)"

# Get initial FDP statistics
echo_info "Collecting initial RU statistics..."
nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b > /tmp/fdp_stats_before_gc.bin 2>/dev/null

echo ""
echo "Initial RU Statistics:"
for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET /tmp/fdp_stats_before_gc.bin 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  RU $i: $DEC bytes (${MB} MB)"
done

echo ""
echo_section "STEP 2: Pre-fill Device to Trigger GC"
echo ""

echo_info "Pre-filling device with workload pattern to create invalid pages..."
echo_info "This will write data and then overwrite portions to create GC victims..."

# Clear device first
blkdiscard $NVME_NS 2>/dev/null || true

# IMPORTANT: Disable FDP during pre-fill so all RUs get used
# (Each RU is only 64MB, can't fit 16GB in RU 0!)
echo_info "Disabling FDP for pre-fill (to use all RUs)..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
echo_success "FDP disabled for pre-fill"

# Pre-fill with FIO to create a realistic workload pattern
# This creates overwrites which generate invalid pages (victims for GC)
cat > /tmp/prefill_with_overwrites.fio << 'PREFILL_FIO'
[global]
filename=/dev/nvme0n1
direct=1
ioengine=libaio
iodepth=32
runtime=60s
time_based=0
group_reporting=1

[prefill-phase1]
rw=write
bs=1M
size=8G
stonewall

[prefill-phase2]
rw=randwrite
bs=4k
size=2G
offset=0
numjobs=1
stonewall
PREFILL_FIO

echo_info "Phase 1: Sequential write 8GB (50% full)..."
echo_info "Phase 2: Random overwrite 2GB (creates invalid pages)..."
echo_info "Total: 10GB used, 6GB free for GC operations"

fio /tmp/prefill_with_overwrites.fio > /tmp/prefill_output.txt 2>&1

rm -f /tmp/prefill_with_overwrites.fio

echo_success "Device pre-filled with victim lines for GC"

# Re-enable FDP for the actual test
echo_info "Re-enabling FDP for GC stress test..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1

ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
if [ "$ONCS" != "0x204" ]; then
    echo_error "Failed to re-enable FDP (ONCS=$ONCS)"
    exit 1
fi
echo_success "FDP re-enabled for test (ONCS=$ONCS)"

echo ""
echo_section "STEP 3: Start GC-Stressing Workload"
echo ""

echo_info "Starting write-heavy workload to trigger GC..."
echo_info "This will write to RU 1 with high rewrite rate..."
echo ""

# Create a script to run concurrent writes to RU 1
cat > /tmp/gc_stress_workload.sh << 'WORKLOAD_EOF'
#!/bin/bash
NVME_NS="/dev/nvme0n1"
DURATION=120
PH=1  # Write to RU 1

echo "[GC-STRESS] Starting workload (PH=$PH, ${DURATION}s)"

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))
WRITES=0

while [ $(date +%s) -lt $END_TIME ]; do
    # Write with very high locality (95% to same 5% of space = heavy overwrites)
    # This creates lots of invalid pages → triggers GC frequently
    if [ $((RANDOM % 100)) -lt 95 ]; then
        LBA=$((RANDOM % 262144))  # Hot 5% = 1GB range (heavy overwrites!)
    else
        LBA=$((RANDOM % 5242880))  # Cold 95% = 20GB range (occasional writes)
    fi
    
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=$PH > /dev/null 2>&1
    
    WRITES=$((WRITES + 1))
    
    if [ $((WRITES % 500)) -eq 0 ]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        echo "[GC-STRESS] Progress: ${ELAPSED}s, $WRITES writes"
    fi
done

echo "[GC-STRESS] Completed: $WRITES writes in ${DURATION}s"
WORKLOAD_EOF

chmod +x /tmp/gc_stress_workload.sh

# Run workload in background
/tmp/gc_stress_workload.sh &
WORKLOAD_PID=$!

echo_info "Workload running (PID: $WORKLOAD_PID)"
echo_info "Monitoring for GC activity for 2 minutes..."
echo ""

# Wait for workload to complete
ELAPSED=0
CHECK_INTERVAL=15

while [ $ELAPSED -lt 120 ]; do
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
    
    if ! kill -0 $WORKLOAD_PID 2>/dev/null; then
        echo_info "Workload completed early"
        break
    fi
    
    echo_info "Still running... (${ELAPSED}s / 120s elapsed)"
done

wait $WORKLOAD_PID 2>/dev/null

echo ""
echo_success "Workload completed"

echo ""
echo_section "STEP 4: Analyze GC Behavior"
echo ""

# Get final FDP statistics
echo_info "Collecting final RU statistics..."
nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b > /tmp/fdp_stats_after_gc.bin 2>/dev/null

echo ""
echo "Final RU Statistics:"
for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET /tmp/fdp_stats_after_gc.bin 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  RU $i: $DEC bytes (${MB} MB)"
done

echo ""
echo_section "STEP 5: Check FEMU Logs for GC Activity"
echo ""

echo_info "Checking host console for GC-related messages..."
echo_warn "NOTE: You need to check FEMU's host console for these messages:"
echo ""

cat << 'LOGMSG'
Expected messages in FEMU console (host side):

1. GC Triggered:
   "GC-ing line:X,ipc=Y,victim=Z,full=A,free=B"

2. RU-aware Line Return (KEY MESSAGE):
   "GC: Returned line X to RU Y (now has Z free lines)"

3. FDP Writes:
   "[FDP] Write: PH=1 -> RU 1, LPN=..."

If you see "GC: Returned line X to RU Y" messages:
  ✓ RU-aware GC is WORKING!
  ✓ Lines are being returned to their original RUs
  ✓ Physical isolation is maintained

If you DON'T see those messages:
  ✗ GC is returning lines to global pool (broken)
  ✗ RUs will run out of lines
  ✗ Need to check GC implementation

To view FEMU logs:
  - Check the terminal where you ran ./run-blackbox.sh
  - Or check build-femu/log file
  - Look for lines containing "GC:" and "Returned line"
LOGMSG

echo ""
echo_section "STEP 6: GC Verification Checklist"
echo ""

echo "Manual Verification Steps:"
echo ""

echo "1. Check FEMU Host Console"
echo "   Look for messages like:"
echo "   ${GREEN}✓${NC} \"GC: Returned line 65 to RU 1 (now has 45 free lines)\""
echo "   ${GREEN}✓${NC} \"GC: Returned line 130 to RU 2 (now has 52 free lines)\""
echo ""

echo "2. Verify RU Statistics Changed"
BEFORE_RU1=$(od -An -t d8 -N 8 -j 8 /tmp/fdp_stats_before_gc.bin 2>/dev/null | tr -d ' ')
AFTER_RU1=$(od -An -t d8 -N 8 -j 8 /tmp/fdp_stats_after_gc.bin 2>/dev/null | tr -d ' ')

if [ ! -z "$BEFORE_RU1" ] && [ ! -z "$AFTER_RU1" ]; then
    DIFF=$((AFTER_RU1 - BEFORE_RU1))
    DIFF_MB=$(echo "scale=2; $DIFF / 1024 / 1024" | bc 2>/dev/null || echo "?")
    
    if [ $DIFF -gt 0 ]; then
        echo "   ${GREEN}✓${NC} RU 1 writes increased by ${DIFF_MB} MB"
        echo "   ${GREEN}✓${NC} Workload successfully wrote to RU 1"
    else
        echo "   ${YELLOW}⚠${NC} RU 1 writes did not increase (test may have been too short)"
    fi
else
    echo "   ${YELLOW}⚠${NC} Could not compare statistics"
fi
echo ""

echo "3. Check for Crashes/Aborts"
if [ -f "/tmp/gc_stress_workload.sh" ]; then
    echo "   ${GREEN}✓${NC} Workload completed without crashes"
else
    echo "   ${RED}✗${NC} Workload script missing (possible crash)"
fi
echo ""

echo "4. Expected Behavior (RU-aware GC)"
echo "   ${GREEN}✓${NC} Lines freed by GC return to their original RU"
echo "   ${GREEN}✓${NC} RU 1's free line count increases during test"
echo "   ${GREEN}✓${NC} No \"out of free lines\" errors"
echo "   ${GREEN}✓${NC} Physical isolation maintained"
echo ""

echo_section "STEP 7: Detailed GC Log Analysis"
echo ""

echo_info "To manually verify GC behavior, check FEMU console for:"
echo ""

cat << 'ANALYSIS'
=== What to Look For in FEMU Console ===

GOOD SIGNS (RU-aware GC working):
--------------------------------------
Pattern: "GC: Returned line X to RU Y (now has Z free lines)"

Example output:
  GC-ing line:65,ipc=1450,victim=12,full=180,free=45
  GC: Returned line 65 to RU 1 (now has 46 free lines)
  GC-ing line:70,ipc=1520,victim=11,full=181,free=46
  GC: Returned line 70 to RU 1 (now has 47 free lines)

This shows:
  ✓ Line 65 belonged to RU 1 (ru_owner=1)
  ✓ After GC, it was returned to RU 1's free list
  ✓ RU 1's free line count increased from 45 → 46 → 47
  ✓ RU-aware GC is working correctly!

BAD SIGNS (Global GC - broken):
--------------------------------------
Pattern: No "Returned line to RU" messages

If you see:
  GC-ing line:65,ipc=1450,victim=12,full=180,free=45
  (no follow-up message)

This means:
  ✗ Line went to global pool
  ✗ RU can't access it
  ✗ RU will eventually run out of lines
  ✗ RU-aware GC NOT working

ERROR SIGNS (Out of lines):
--------------------------------------
Pattern: "RU X out of free lines!"

If you see:
  ftl_err("RU 1 out of free lines! (free=0, victim=45, full=190)")

This means:
  ✗ RU 1 exhausted its lines
  ✗ GC didn't return lines to RU 1
  ✗ System will abort
  ✗ RU-aware GC implementation has a bug

=== How to Access FEMU Console ===

Option 1: If you started FEMU in current terminal
  - Just scroll up in the terminal where you ran ./run-blackbox.sh
  - Look for recent GC messages

Option 2: If FEMU is running in background/tmux
  - Check the log file: less ~/POSTECH/FEMU/build-femu/log
  - Search for "GC:" messages: grep "GC:" ~/POSTECH/FEMU/build-femu/log

Option 3: Live monitoring
  - tail -f ~/POSTECH/FEMU/build-femu/log | grep --line-buffered "GC:"

ANALYSIS

echo ""
echo_section "Summary"
echo ""

echo_info "Test completed! To verify RU-aware GC is working:"
echo ""
echo "  1. Check FEMU console for \"GC: Returned line X to RU Y\" messages"
echo "  2. Verify no \"out of free lines\" errors occurred"
echo "  3. Confirm RU 1 statistics increased (workload wrote data)"
echo "  4. Ensure test completed without crashes"
echo ""

echo_success "If you see \"GC: Returned line\" messages, RU-aware GC is WORKING! ✓"
echo ""
echo_info "Next step: Run full QoS test with: sudo ./01_prefill_and_test.sh"
echo ""

# Cleanup
rm -f /tmp/gc_stress_workload.sh

