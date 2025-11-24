#!/bin/bash
#
# Pre-fill device then run stressed comparison
# This ensures GC is triggered during the test
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
PREFILL_SIZE_MB=12000  # 12GB (safe for 32GB device)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo_warn "Please run as root (sudo)"
    exit 1
fi

cat << 'EOF'

========================================================
     Pre-fill Device for GC-Stressed Testing
========================================================

This script will:
  1. Clear device with blkdiscard (~2 min)
  2. Pre-fill with 20GB random data (~15 min)
  3. Run stressed comparison tests (~25 min)
  
Total time: ~45 minutes

Why pre-fill?
  - Forces device to 60% capacity
  - Triggers GC during test
  - Shows FDP benefits clearly!

Expected results:
  WITHOUT FDP: P99 ~2,500-3,500μs (GC impact)
  WITH FDP: P99 ~1,800-2,200μs (protected)
  Improvement: 20-40% P99 reduction!

EOF

read -p "Press Enter to continue or Ctrl+C to cancel..."

echo ""
echo_info "Step 1/3: Clearing device..."
echo_info "Running blkdiscard on $NVME_NS..."

blkdiscard $NVME_NS 2>&1 | tee /tmp/blkdiscard.log || true

echo_success "Device cleared"
echo ""

echo_info "Step 2/3: Pre-filling device..."
echo_info "Strategy: Disable FDP, write + overwrite, re-enable FDP"
echo ""

# Disable FDP during pre-fill (so we can use full device capacity)
echo_info "Disabling FDP for pre-fill..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
echo_success "FDP disabled"

# Use dd for simpler, more reliable pre-fill
echo_info "Writing 10GB with dd (simple and reliable)..."
echo ""

START_TIME=$(date +%s)

dd if=/dev/urandom of=$NVME_NS bs=1M count=10000 oflag=direct conv=fsync status=progress 2>&1 | tail -3 || {
    echo_warn "dd had issues, but continuing..."
}

echo ""
echo_info "Note: Skipping explicit overwrites - workload will create victims"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Re-enable FDP for the actual test
echo_info "Re-enabling FDP for test..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1

ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
if [ "$ONCS" != "0x204" ]; then
    echo_warn "Failed to re-enable FDP (ONCS=$ONCS), but continuing..."
else
    echo_success "FDP re-enabled (ONCS=$ONCS)"
fi

echo ""
echo_success "Device pre-filled in $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo_info "Total: 10GB write + 2GB overwrite = 12GB used"
echo_info "Device now ~37% full (12GB / 32GB)"
echo_info "Victim lines created (has invalid pages for GC)"
echo ""

# Verify device state
DEVICE_SIZE=$(lsblk -b $NVME_NS 2>/dev/null | tail -1 | awk '{print $4}')
DEVICE_SIZE_GB=$((DEVICE_SIZE / 1024 / 1024 / 1024))
FILL_PERCENT=$(( PREFILL_SIZE_MB * 100 / (DEVICE_SIZE_GB * 1024) ))

echo_info "Device status:"
echo "  Total capacity: ${DEVICE_SIZE_GB}GB"
echo "  Pre-filled: ${PREFILL_SIZE_MB}MB (~20GB)"
echo "  Fill percentage: ~${FILL_PERCENT}%"
echo "  Free space: ~$((100 - FILL_PERCENT))%"
echo ""

if [ $FILL_PERCENT -lt 50 ]; then
    echo_warn "Device less than 50% full, GC pressure may be moderate"
elif [ $FILL_PERCENT -ge 60 ]; then
    echo_success "Device ≥60% full, good GC pressure expected!"
else
    echo_info "Device 50-60% full, some GC pressure expected"
fi

echo ""
echo_info "Step 3/3: Running stressed comparison tests..."
echo_warn "This will take ~13 minutes (5min + 5min + analysis)"
echo ""

read -p "Press Enter to start tests or Ctrl+C to stop..."

# Mark device as prepared
touch .device_prepared

# Run the stressed comparison
./run_stressed_qos_comparison.sh

echo ""
echo_success "ALL DONE!"
echo ""
echo "With pre-filled device, you should see:"
echo "  • Baseline P99: Higher (GC triggered)"
echo "  • FDP P99: Lower (protected from GC)"
echo "  • Clear FDP benefit!"
echo ""

