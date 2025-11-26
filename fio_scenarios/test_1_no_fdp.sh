#!/bin/bash
#
# Test 1: WITHOUT FDP (Baseline with GC interference)
# Run this first, then REBOOT VM before Test 2
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/test_results/01_no_fdp_$(date +%Y%m%d_%H%M%S)"

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

mkdir -p "$RESULT_DIR"

cat << 'EOF'

========================================================
     TEST 1: WITHOUT FDP (Baseline)
     Demonstrates GC interference in mixed workload
========================================================

This test measures victim workload latency when:
- Victim and noisy neighbor share same physical space
- Overwrites cause GC in victim's area
- High latency expected due to GC interference

Workload:
  - Pre-fill: 25GB (creates EXTREME GC pressure, 78% full!)
  - WARM-UP: 10 minutes, ~6000 writes at 10 IOPS (stabilize GC)
  - Victim writes: 500 ops (LBA 0-1M)
  - Noisy writes: 15000 ops (LBA 0-3M, HEAVILY OVERLAPS)
  - MASSIVE overwrites: 20000 ops (CONTINUOUS GC!)
  - Victim reads: 500 ops (measures latency under heavy GC)

Duration: ~30 minutes

After this test, REBOOT the VM and run test_2_with_fdp.sh

EOF

read -p "Press Enter to start Test 1 or Ctrl+C to cancel..."

echo ""
echo_section "TEST 1: WITHOUT FDP (Mixed workload)"
echo ""

# Disable FDP
echo_info "Disabling FDP..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_success "FDP disabled (ONCS=$ONCS)"

# Clear device
echo_info "Clearing device..."
blkdiscard $NVME_NS 2>&1 | grep -v "Operation not supported" || true

# Pre-fill
echo_info "Writing 25GB base data (creates EXTREME GC pressure, 78% full!)..."
TEST_START=$(date +%s)
dd if=/dev/urandom of=$NVME_NS bs=1M count=25000 oflag=direct conv=fsync 2>&1 | tail -3

echo ""
echo_info "=== WARM-UP PHASE: 10 minutes of writes (throttled) ==="
echo_info "This stabilizes GC and ensures consistent baseline..."
WARMUP_START=$(date +%s)
WARMUP_LAT_FILE="${RESULT_DIR}/warmup_latencies.txt"
> "$WARMUP_LAT_FILE"

WARMUP_COUNT=0
WARMUP_TARGET=6000  # Target ~6000 operations over 10 minutes

while [ $(($(date +%s) - WARMUP_START)) -lt 600 ]; do  # 10 minutes = 600 seconds
    LBA=$((RANDOM % 3000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$WARMUP_LAT_FILE"
    WARMUP_COUNT=$((WARMUP_COUNT + 1))
    
    # Throttle: Sleep 90ms between writes (~10 IOPS sustained)
    # This prevents overwhelming FEMU and allows GC to stabilize
    sleep 0.09
    
    if [ $((WARMUP_COUNT % 500)) -eq 0 ]; then
        ELAPSED=$(($(date +%s) - WARMUP_START))
        echo_info "  Warm-up: ${ELAPSED}s / 600s, $WARMUP_COUNT ops (~10 IOPS)"
    fi
    
    # Safety: Exit if we hit target early
    if [ $WARMUP_COUNT -ge $WARMUP_TARGET ]; then
        echo_info "  Reached target $WARMUP_TARGET ops, completing warm-up..."
        break
    fi
done

WARMUP_END=$(date +%s)
WARMUP_DURATION=$((WARMUP_END - WARMUP_START))
echo_success "Warm-up complete! $WARMUP_COUNT ops in ${WARMUP_DURATION}s"

echo ""
echo_info "Phase 1: Writing 'victim' data (500 ops)"

VICTIM_LAT_FILE="${RESULT_DIR}/victim_write_latencies.txt"
> "$VICTIM_LAT_FILE"

for i in {1..500}; do
    LBA=$((RANDOM % 1000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$VICTIM_LAT_FILE"
    
    if [ $((i % 100)) -eq 0 ]; then
        echo_info "  Victim writes: $i/500"
    fi
done

echo_success "Victim data written (500 ops)"

echo ""
echo_info "Phase 2: Writing 'noisy' data (15000 ops, HEAVILY OVERLAPS victim)"

NOISY_LAT_FILE="${RESULT_DIR}/noisy_write_latencies.txt"
> "$NOISY_LAT_FILE"

for i in {1..15000}; do
    LBA=$((RANDOM % 3000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$NOISY_LAT_FILE"
    
    if [ $((i % 2000)) -eq 0 ]; then
        echo_info "  Noisy writes: $i/15000"
    fi
done

echo_success "Noisy data written (15000 ops)"

echo ""
echo_info "Phase 2b: MASSIVE overwrites (20000 ops) INTERLEAVED with victim reads"
echo_info "This creates CONTINUOUS GC activity - maximum stress!"

OVERWRITE_LAT_FILE="${RESULT_DIR}/overwrite_latencies.txt"
VICTIM_READ_LAT_FILE="${RESULT_DIR}/victim_read_latencies.txt"
> "$OVERWRITE_LAT_FILE"
> "$VICTIM_READ_LAT_FILE"

OVERWRITE_START=$(date +%s)
READ_COUNT=0
for i in {1..20000}; do
    # Overwrite to force GC
    LBA=$((RANDOM % 2000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$OVERWRITE_LAT_FILE"
    
    # Every 40 overwrites, do a victim READ to measure GC impact
    if [ $((i % 40)) -eq 0 ] && [ $READ_COUNT -lt 500 ]; then
        LBA_READ=$((RANDOM % 1000000))
        START_READ=$(date +%s%N)
        nvme read $NVME_NS --start-block=$LBA_READ --block-count=7 \
            --data-size=4096 > /dev/null 2>&1
        END_READ=$(date +%s%N)
        READ_LATENCY=$(( (END_READ - START_READ) / 1000 ))
        echo "$READ_LATENCY" >> "$VICTIM_READ_LAT_FILE"
        READ_COUNT=$((READ_COUNT + 1))
    fi
    
    if [ $((i % 2000)) -eq 0 ]; then
        echo_info "  Overwrites: $i/20000, Reads: $READ_COUNT/500 (CONTINUOUS GC!)"
    fi
done

OVERWRITE_END=$(date +%s)
OVERWRITE_DURATION=$((OVERWRITE_END - OVERWRITE_START))

echo_success "MASSIVE overwrites complete with interleaved reads!"
echo_info "Victim reads: $READ_COUNT ops measured DURING CONTINUOUS GC"

echo ""
echo_info "Analyzing results..."

# Analyze latencies
analyze_latency() {
    local FILE=$1
    local LABEL=$2
    
    if [ ! -f "$FILE" ] || [ ! -s "$FILE" ]; then
        echo_warn "$LABEL: No data"
        return
    fi
    
    sort -n "$FILE" > "${FILE}.sorted"
    local COUNT=$(wc -l < "${FILE}.sorted")
    local MIN=$(head -1 "${FILE}.sorted")
    local MAX=$(tail -1 "${FILE}.sorted")
    local AVG=$(awk '{sum+=$1} END {print int(sum/NR)}' "${FILE}.sorted")
    local P50=$(awk -v p=0.50 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted")
    local P95=$(awk -v p=0.95 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted")
    local P99=$(awk -v p=0.99 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted}")
    
    echo ""
    echo "[$LABEL]"
    echo "  Operations: $COUNT"
    echo "  Min:     ${MIN}μs"
    echo "  Average: ${AVG}μs"
    echo "  P50:     ${P50}μs"
    echo "  P95:     ${P95}μs"
    echo "  P99:     ${P99}μs"
    echo "  Max:     ${MAX}μs"
}

analyze_latency "$VICTIM_READ_LAT_FILE" "Victim Reads (NO FDP)"

# Save metadata for Python analysis
TEST_END=$(date +%s)
TEST_DURATION=$((TEST_END - TEST_START))
cat > "${RESULT_DIR}/metadata.txt" << METADATA
test_name=NO_FDP
test_start=$TEST_START
test_end=$TEST_END
test_duration=$TEST_DURATION
warmup_ops=$WARMUP_COUNT
warmup_duration=$WARMUP_DURATION
victim_writes=500
noisy_writes=15000
overwrites=20000
overwrite_duration=$OVERWRITE_DURATION
victim_reads=$READ_COUNT
prefill_gb=25
device_capacity_gb=32
METADATA

echo ""
echo_success "Test 1 complete!"
echo ""
echo "=========================================="
echo "  Results saved to:"
echo "  $RESULT_DIR"
echo "=========================================="
echo ""
echo_warn "⚠️  NEXT STEP: REBOOT THE VM"
echo ""
echo "To get a clean SSD for Test 2:"
echo "  1. Exit the VM"
echo "  2. Restart FEMU (./run-blackbox.sh)"
echo "  3. SSH back in"
echo "  4. Run: sudo ./test_2_with_fdp.sh"
echo ""
echo "This ensures FDP starts with a fresh device!"
echo ""

