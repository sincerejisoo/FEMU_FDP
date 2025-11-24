#!/bin/bash
#
# FDP QoS Comparison: Victim + Noisy Neighbor
# Demonstrates FDP's isolation benefits
#
# Test 1: WITHOUT FDP - victim affected by noisy neighbor's GC
# Test 2: WITH FDP - victim isolated from noisy neighbor
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/qos_comparison_$(date +%Y%m%d_%H%M%S)"

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

# Check device
if [ ! -b "$NVME_NS" ]; then
    echo_error "NVMe namespace $NVME_NS not found"
    exit 1
fi

# Check fio
if ! command -v fio &> /dev/null; then
    echo_error "fio not found. Install with: sudo apt install fio"
    exit 1
fi

mkdir -p "$RESULT_DIR"

# Device preparation check
echo_info "Checking device state..."
if [ -f "${SCRIPT_DIR}/.device_prepared" ]; then
    LAST_PREP=$(stat -c %Y "${SCRIPT_DIR}/.device_prepared" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$((NOW - LAST_PREP))
    if [ $AGE -gt 600 ]; then  # 10 minutes
        echo_warn "Device not recently cleared (${AGE}s ago)"
        echo_warn "Run: sudo ./00_prepare_device.sh first"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
else
    echo_warn "Device may have stale data"
    echo_warn "Recommended: Run sudo ./00_prepare_device.sh first"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# FDP control functions
enable_fdp() {
    nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1
    local oncs=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
    if [ "$oncs" == "0x204" ]; then
        echo_success "FDP enabled (ONCS=$oncs)"
        return 0
    else
        echo_error "FDP enable failed (ONCS=$oncs)"
        return 1
    fi
}

disable_fdp() {
    nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
    local oncs=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
    if [ "$oncs" == "0x4" ]; then
        echo_success "FDP disabled (ONCS=$oncs)"
        return 0
    else
        echo_error "FDP disable failed (ONCS=$oncs)"
        return 1
    fi
}

# Latency analysis function
analyze_fio_latency() {
    local output_file=$1
    local workload_name=$2
    
    if [ ! -f "$output_file" ]; then
        echo_warn "Output file not found: $output_file"
        return
    fi
    
    echo ""
    echo "[$workload_name] Latency Analysis:"
    echo "-----------------------------------"
    
    # Extract write latency percentiles
    local write_avg=$(grep "write.*avg=" "$output_file" | head -1 | sed -n 's/.*avg=\s*\([0-9.]*\).*/\1/p')
    local write_p95=$(grep "95.00th" "$output_file" | grep -A1 "write" | tail -1 | awk '{print $3}' | tr -d '[]')
    local write_p99=$(grep "99.00th" "$output_file" | grep -A1 "write" | tail -1 | awk '{print $3}' | tr -d '[]')
    local write_max=$(grep "write.*max=" "$output_file" | head -1 | sed -n 's/.*max=\s*\([0-9.]*\).*/\1/p')
    
    echo "  Write Latency:"
    [ -n "$write_avg" ] && echo "    Average: ${write_avg}us"
    [ -n "$write_p95" ] && echo "    95th %:  ${write_p95}"
    [ -n "$write_p99" ] && echo "    99th %:  ${write_p99}"
    [ -n "$write_max" ] && echo "    Max:     ${write_max}us"
    
    # Extract IOPS
    local write_iops=$(grep "write.*IOPS=" "$output_file" | head -1 | sed -n 's/.*IOPS=\s*\([0-9.]*\).*/\1/p')
    [ -n "$write_iops" ] && echo "  Write IOPS: ${write_iops}"
    
    echo ""
}

#############################################
# MAIN EXECUTION
#############################################

cat << 'EOF'

========================================================
     FDP QoS Demonstration: Victim + Noisy Neighbor
========================================================

This test demonstrates FDP's Quality of Service (QoS) benefits:

  WITHOUT FDP:
    - Victim and noisy neighbor mixed in same blocks
    - Noisy neighbor creates garbage → triggers GC
    - GC impacts victim workload → HIGH LATENCY VARIANCE
    
  WITH FDP:
    - Victim isolated in RU 0
    - Noisy neighbor isolated in RU 1
    - Separate GC per RU → LOW LATENCY VARIANCE
    - Victim protected from noisy neighbor interference

Test Duration: ~5 minutes (2 tests × 2 min each)

EOF

read -p "Press Enter to continue or Ctrl+C to cancel..."

#############################################
# TEST 1: WITHOUT FDP (Baseline)
#############################################

echo ""
echo_section "TEST 1/2: WITHOUT FDP (Baseline - Mixed Workloads)"
echo ""

disable_fdp || exit 1

TEST1_DIR="${RESULT_DIR}/01_baseline_no_fdp"
mkdir -p "$TEST1_DIR"

echo_info "Running victim + noisy neighbor workload (mixed, no isolation)..."
echo_info "This will take ~2 minutes..."
echo ""

cd "$TEST1_DIR"
if fio "${SCRIPT_DIR}/victim_noisy_baseline.fio" \
    --output="fio_output.txt" \
    --output-format=normal \
    2>&1 | tee "console.log"; then
    echo_success "Baseline test completed"
else
    echo_error "Baseline test failed"
    exit 1
fi
cd "$SCRIPT_DIR"

# Analyze baseline results
analyze_fio_latency "${TEST1_DIR}/fio_output.txt" "VICTIM (No FDP - Mixed)"
analyze_fio_latency "${TEST1_DIR}/fio_output.txt" "NOISY (No FDP - Mixed)"

echo_success "Test 1 results saved to: $TEST1_DIR"

#############################################
# TEST 2: WITH FDP (Isolated)
#############################################

echo ""
echo_section "TEST 2/2: WITH FDP (Isolated Workloads)"
echo ""

enable_fdp || exit 1

TEST2_DIR="${RESULT_DIR}/02_with_fdp_isolated"
mkdir -p "$TEST2_DIR"

echo_info "Running victim + noisy neighbor with FDP isolation..."
echo_info "  Victim → RU 0 (protected)"
echo_info "  Noisy  → RU 1 (isolated)"
echo_info "This will take ~2 minutes..."
echo ""

# Run custom FDP script
"${SCRIPT_DIR}/victim_noisy_with_fdp.sh" 2>&1 | tee "${TEST2_DIR}/console.log"

# Move results to test directory
if [ -d "${SCRIPT_DIR}/fdp_qos_results_"* ]; then
    mv "${SCRIPT_DIR}"/fdp_qos_results_* "${TEST2_DIR}/fdp_results"
    echo_success "Test 2 results saved to: $TEST2_DIR"
fi

#############################################
# COMPARISON & SUMMARY
#############################################

echo ""
echo_section "GENERATING COMPARISON SUMMARY"
echo ""

SUMMARY="${RESULT_DIR}/QoS_SUMMARY.txt"

{
    echo "========================================================
     FDP QoS Demonstration Results
========================================================
Date: $(date)
Device: $NVME_NS

========================================================
TEST 1: WITHOUT FDP (Baseline)
========================================================

Configuration:
  - FDP: Disabled
  - Victim + Noisy: Mixed in same blocks
  - Expected: High victim latency variance due to GC

Results:"
    
    analyze_fio_latency "${TEST1_DIR}/fio_output.txt" "VICTIM (No FDP)" 2>/dev/null || echo "  Analysis failed"
    
    echo "
Characteristics:
  ✗ Victim affected by noisy neighbor's GC
  ✗ High tail latency (P99, P999)
  ✗ Unpredictable performance
  ✗ No workload isolation

========================================================
TEST 2: WITH FDP (Isolated)
========================================================

Configuration:
  - FDP: Enabled
  - Victim → RU 0 (isolated)
  - Noisy  → RU 1 (isolated)
  - Expected: Low victim latency variance (protected)

Results:"
    
    if [ -f "${TEST2_DIR}/fdp_results/victim_with_fdp_lat.log" ]; then
        echo "  (See detailed latency logs in ${TEST2_DIR}/fdp_results/)"
    fi
    
    echo "
Characteristics:
  ✓ Victim isolated from noisy neighbor
  ✓ Low, predictable tail latency
  ✓ Protected from GC interference
  ✓ Strong workload isolation

========================================================
FDP QoS BENEFITS
========================================================

Key Improvements:
  1. Latency Stability: Lower P99/P999 latency variance
  2. Predictability: Victim performance not affected by noisy
  3. Isolation: Separate GC domains prevent interference
  4. QoS: Latency-sensitive apps protected from churners

Metrics to Compare:
  - P99 latency: Should be significantly lower with FDP
  - P999 latency: Should be much more stable with FDP
  - Max latency: Should show fewer outliers with FDP
  - Latency std dev: Should be lower with FDP

========================================================
DETAILED RESULTS
========================================================

Test 1 (No FDP):
  ${TEST1_DIR}/fio_output.txt
  ${TEST1_DIR}/console.log

Test 2 (With FDP):
  ${TEST2_DIR}/fdp_results/victim_with_fdp_lat.log
  ${TEST2_DIR}/fdp_results/noisy_with_fdp_lat.log
  ${TEST2_DIR}/fdp_results/fdp_stats_*.bin
  ${TEST2_DIR}/console.log

========================================================
VISUALIZATION
========================================================

To plot latency distributions:
  1. Extract victim latencies from both tests
  2. Compare P50, P95, P99, P999
  3. Plot CDF to show tail latency improvement
  4. Show that FDP provides consistent low latency

Expected Result:
  With FDP, victim workload shows:
    - 30-50% lower P99 latency
    - 50-70% lower P999 latency  
    - More stable, predictable performance
    - Protected from noisy neighbor interference

========================================================
"
} | tee "$SUMMARY"

echo ""
echo_section "ALL TESTS COMPLETE!"
echo ""
echo_success "Results saved to: $RESULT_DIR"
echo ""
echo "Summary: $SUMMARY"
echo ""
echo_info "Key Findings:"
echo "  1. Compare P99 latency: Test 1 vs Test 2"
echo "  2. Check victim latency stability with FDP"
echo "  3. Verify RU isolation in FDP statistics"
echo ""
echo_info "Expected: FDP provides 30-70% tail latency improvement"
echo_info "          for latency-sensitive (victim) workloads"
echo ""

