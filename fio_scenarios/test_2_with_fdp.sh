#!/bin/bash
#
# Test 2: WITH FDP (Isolated workloads)
# Run this AFTER rebooting VM from Test 1
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/test_results/02_with_fdp_$(date +%Y%m%d_%H%M%S)"

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
     TEST 2: WITH FDP (Isolated)
     Demonstrates FDP's QoS isolation benefits
========================================================

This test measures victim workload latency when:
- Victim (RU 0) and noisy (RU 1) are physically isolated
- Noisy's GC doesn't affect victim
- Lower latency expected due to FDP isolation

Workload:
  - Pre-fill: NONE (preserves free lines for RU distribution)
  - Victim writes: 500 ops to RU 0 (PH=0)
  - Noisy writes: 7000 ops to RU 1 (PH=1)
  - EXTREME overwrites: 7000 ops to RU 1 ONLY
  - Victim reads: 300 ops (measures protected latency)

Duration: ~12 minutes

EOF

read -p "Press Enter to start Test 2 or Ctrl+C to cancel..."

echo ""
echo_section "TEST 2: WITH FDP (Isolated workloads)"
echo ""

# Clear device
echo_info "Clearing device..."
blkdiscard $NVME_NS 2>&1 | grep -v "Operation not supported" || true

# Enable FDP (no pre-fill to preserve free lines)
echo_info "Enabling FDP (fresh device with abundant free lines)..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1
sleep 1

ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
if [ "$ONCS" != "0x204" ]; then
    echo_error "FDP not enabled! ONCS=$ONCS (expected 0x204)"
    echo_error "Check FEMU logs for errors"
    exit 1
fi
echo_success "FDP enabled (ONCS=$ONCS)"

echo ""
echo_info "Phase 1: Writing 'victim' data to RU 0 (500 ops)"

VICTIM_LAT_FILE="${RESULT_DIR}/victim_write_latencies.txt"
> "$VICTIM_LAT_FILE"

for i in {1..500}; do
    LBA=$((RANDOM % 1000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=0 > /dev/null 2>&1  # PH=0 → RU 0
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$VICTIM_LAT_FILE"
    
    if [ $((i % 100)) -eq 0 ]; then
        echo_info "  Victim writes (RU 0): $i/500"
    fi
done

echo_success "Victim data written to RU 0 (500 ops)"

echo ""
echo_info "Phase 2: Writing 'noisy' data to RU 1 (7000 ops)"

NOISY_LAT_FILE="${RESULT_DIR}/noisy_write_latencies.txt"
> "$NOISY_LAT_FILE"

for i in {1..7000}; do
    LBA=$((RANDOM % 2000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=1 > /dev/null 2>&1  # PH=1 → RU 1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$NOISY_LAT_FILE"
    
    if [ $((i % 1000)) -eq 0 ]; then
        echo_info "  Noisy writes (RU 1): $i/7000"
    fi
done

echo_success "Noisy data written to RU 1 (7000 ops)"

echo ""
echo_info "Phase 2b: EXTREME overwrites to RU 1 (7000 ops) INTERLEAVED with victim reads"
echo_info "RU 1 has MASSIVE GC, RU 0 (victim) should be PROTECTED!"

OVERWRITE_LAT_FILE="${RESULT_DIR}/overwrite_latencies.txt"
VICTIM_READ_LAT_FILE="${RESULT_DIR}/victim_read_latencies.txt"
> "$OVERWRITE_LAT_FILE"
> "$VICTIM_READ_LAT_FILE"

READ_COUNT=0
for i in {1..7000}; do
    # Overwrite to RU 1 to force GC there
    LBA=$((RANDOM % 2000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=1 > /dev/null 2>&1  # PH=1 → RU 1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$OVERWRITE_LAT_FILE"
    
    # Every 23 overwrites, READ from victim area (RU 0)
    # This measures if RU 0 is protected from RU 1's GC
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
        echo_info "  Overwrites (RU 1): $i/7000, Victim reads (RU 0): $READ_COUNT/300"
    fi
done

echo_success "EXTREME overwrites to RU 1 complete with interleaved victim reads!"
echo_info "Victim reads: $READ_COUNT ops from RU 0 (should be protected)"

echo ""
echo_info "Collecting FDP statistics..."
nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b > "${RESULT_DIR}/fdp_stats.bin" 2>/dev/null

echo "FDP Statistics:"
for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET "${RESULT_DIR}/fdp_stats.bin" 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  RU $i: ${MB} MB written"
done

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
    local P99=$(awk -v p=0.99 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted")
    
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

analyze_latency "$VICTIM_READ_LAT_FILE" "Victim Reads (WITH FDP)"

echo ""
echo_success "Test 2 complete!"
echo ""
echo "=========================================="
echo "  Results saved to:"
echo "  $RESULT_DIR"
echo "=========================================="
echo ""
echo_info "To compare results, run:"
echo "  ./compare_results.sh"
echo ""

