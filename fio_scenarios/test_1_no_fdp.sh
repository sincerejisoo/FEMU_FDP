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
  - Victim writes: 500 ops (LBA 0-1M)
  - Noisy writes: 7000 ops (LBA 0-2M, OVERLAPS victim)
  - EXTREME overwrites: 7000 ops (forces MASSIVE GC!)
  - Victim reads: 300 ops (measures latency under GC)

Duration: ~15 minutes

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
dd if=/dev/urandom of=$NVME_NS bs=1M count=25000 oflag=direct conv=fsync 2>&1 | tail -3

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
echo_info "Phase 2: Writing 'noisy' data (7000 ops, OVERLAPS victim)"

NOISY_LAT_FILE="${RESULT_DIR}/noisy_write_latencies.txt"
> "$NOISY_LAT_FILE"

for i in {1..7000}; do
    LBA=$((RANDOM % 2000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$NOISY_LAT_FILE"
    
    if [ $((i % 1000)) -eq 0 ]; then
        echo_info "  Noisy writes: $i/7000"
    fi
done

echo_success "Noisy data written (7000 ops)"

echo ""
echo_info "Phase 2b: EXTREME overwrites (7000 ops) INTERLEAVED with victim reads"
echo_info "This measures latency DURING MASSIVE GC activity!"

OVERWRITE_LAT_FILE="${RESULT_DIR}/overwrite_latencies.txt"
VICTIM_READ_LAT_FILE="${RESULT_DIR}/victim_read_latencies.txt"
> "$OVERWRITE_LAT_FILE"
> "$VICTIM_READ_LAT_FILE"

READ_COUNT=0
for i in {1..7000}; do
    # Overwrite to force GC
    LBA=$((RANDOM % 1000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$OVERWRITE_LAT_FILE"
    
    # Every 23 overwrites, do a victim READ to measure GC impact
    if [ $((i % 23)) -eq 0 ] && [ $READ_COUNT -lt 300 ]; then
        LBA_READ=$((RANDOM % 1000000))
        START_READ=$(date +%s%N)
        nvme read $NVME_NS --start-block=$LBA_READ --block-count=7 \
            --data-size=4096 > /dev/null 2>&1
        END_READ=$(date +%s%N)
        READ_LATENCY=$(( (END_READ - START_READ) / 1000 ))
        echo "$READ_LATENCY" >> "$VICTIM_READ_LAT_FILE"
        READ_COUNT=$((READ_COUNT + 1))
    fi
    
    if [ $((i % 1000)) -eq 0 ]; then
        echo_info "  Overwrites: $i/7000, Reads: $READ_COUNT/300 (MASSIVE GC!)"
    fi
done

echo_success "EXTREME overwrites complete with interleaved reads!"
echo_info "Victim reads: $READ_COUNT ops measured DURING MASSIVE GC"

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

