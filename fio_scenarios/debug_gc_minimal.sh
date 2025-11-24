#!/bin/bash
#
# Minimal GC Debug Test - Safe, Non-Crashing Version
# This version uses very conservative settings to avoid VM crashes
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"

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

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo_error "Please run as root (sudo)"
    exit 1
fi

cat << 'EOF'

========================================================
     Minimal GC Debug Test (Safe Version)
========================================================

This is a MINIMAL test designed to avoid crashes:
  - Very small pre-fill (2GB only)
  - Short test duration (30s)
  - Low write rate (100 IOPS)
  - Monitors for issues

Purpose: Verify basic GC behavior without overwhelming device

Duration: ~2 minutes total

EOF

read -p "Press Enter to start or Ctrl+C to cancel..."

echo ""
echo_info "Step 1: Detect device size"
echo ""

# Try to detect device size
DEVICE_SIZE_BYTES=$(blockdev --getsize64 $NVME_NS 2>/dev/null || echo "0")
DEVICE_SIZE_GB=$((DEVICE_SIZE_BYTES / 1024 / 1024 / 1024))

if [ $DEVICE_SIZE_GB -gt 0 ]; then
    echo_success "Device size: ${DEVICE_SIZE_GB}GB"
else
    echo_warn "Could not detect device size, assuming 16GB"
    DEVICE_SIZE_GB=16
fi

# Calculate safe pre-fill (10% of device)
PREFILL_GB=$((DEVICE_SIZE_GB / 10))
if [ $PREFILL_GB -lt 1 ]; then
    PREFILL_GB=1
fi

echo_info "Safe pre-fill size: ${PREFILL_GB}GB (10% of device)"

echo ""
echo_info "Step 2: Clear device"
echo ""

blkdiscard $NVME_NS 2>/dev/null || dd if=/dev/zero of=$NVME_NS bs=1M count=10 oflag=direct 2>/dev/null || true
echo_success "Device cleared"

echo ""
echo_info "Step 3: Minimal pre-fill (creates some data and victims)"
echo ""

# Very conservative pre-fill
echo_info "Writing ${PREFILL_GB}GB..."
dd if=/dev/urandom of=$NVME_NS bs=1M count=$((PREFILL_GB * 1024)) oflag=direct 2>&1 | tail -3

echo_success "Pre-fill complete"

echo ""
echo_info "Step 4: Enable FDP"
echo ""

nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')

if [ "$ONCS" != "0x204" ]; then
    echo_error "FDP not enabled (ONCS=$ONCS)"
    exit 1
fi

echo_success "FDP enabled (ONCS=$ONCS)"

echo ""
echo_info "Step 5: Get initial statistics"
echo ""

nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b > /tmp/stats_before.bin 2>/dev/null

echo "Initial RU Statistics:"
for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET /tmp/stats_before.bin 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  RU $i: ${MB} MB"
done

echo ""
echo_info "Step 6: Run MINIMAL write workload (30s, very low rate)"
echo ""

# Create minimal workload script
cat > /tmp/minimal_workload.sh << 'WORKLOAD'
#!/bin/bash
NVME_NS="/dev/nvme0n1"
DURATION=30
PH=1
WRITES=0
ERRORS=0

echo "[MINIMAL] Starting workload (30s, ~100 writes total)"

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

while [ $(date +%s) -lt $END_TIME ]; do
    # Write to small hot region (heavy overwrite)
    LBA=$((RANDOM % 10000))
    
    if nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=$PH > /dev/null 2>&1; then
        WRITES=$((WRITES + 1))
    else
        ERRORS=$((ERRORS + 1))
        if [ $ERRORS -gt 10 ]; then
            echo "[MINIMAL] Too many errors, stopping"
            break
        fi
    fi
    
    # Very conservative rate: ~3 writes per second
    sleep 0.3
    
    if [ $((WRITES % 20)) -eq 0 ]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        echo "[MINIMAL] Progress: ${ELAPSED}s, $WRITES writes, $ERRORS errors"
    fi
done

echo "[MINIMAL] Completed: $WRITES writes, $ERRORS errors"
WORKLOAD

chmod +x /tmp/minimal_workload.sh

# Run workload
/tmp/minimal_workload.sh

echo ""
echo_success "Workload completed"

echo ""
echo_info "Step 7: Get final statistics"
echo ""

nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b > /tmp/stats_after.bin 2>/dev/null

echo "Final RU Statistics:"
for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET /tmp/stats_after.bin 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  RU $i: ${MB} MB"
done

echo ""
echo_info "Step 8: Check for changes"
echo ""

BEFORE_RU1=$(od -An -t d8 -N 8 -j 8 /tmp/stats_before.bin 2>/dev/null | tr -d ' ')
AFTER_RU1=$(od -An -t d8 -N 8 -j 8 /tmp/stats_after.bin 2>/dev/null | tr -d ' ')

if [ ! -z "$BEFORE_RU1" ] && [ ! -z "$AFTER_RU1" ]; then
    DIFF=$((AFTER_RU1 - BEFORE_RU1))
    DIFF_MB=$(echo "scale=2; $DIFF / 1024 / 1024" | bc 2>/dev/null || echo "?")
    
    if [ $DIFF -gt 0 ]; then
        echo_success "RU 1 writes increased by ${DIFF_MB} MB"
        echo_success "Workload successfully wrote to RU 1"
    else
        echo_warn "RU 1 writes did not increase"
    fi
fi

echo ""
echo "=========================================================="
echo "  MINIMAL TEST SUMMARY"
echo "=========================================================="
echo ""
echo_success "Test completed without crashing! ✓"
echo ""
echo "Next steps:"
echo "  1. Check FEMU console for GC messages:"
echo "     grep 'GC:' ~/POSTECH/FEMU/build-femu/log | tail -20"
echo ""
echo "  2. Look for RU-aware returns:"
echo "     grep 'Returned line.*to RU' ~/POSTECH/FEMU/build-femu/log"
echo ""
echo "  3. If this test passed, you can try a longer test"
echo ""

# Cleanup
rm -f /tmp/minimal_workload.sh /tmp/stats_before.bin /tmp/stats_after.bin

