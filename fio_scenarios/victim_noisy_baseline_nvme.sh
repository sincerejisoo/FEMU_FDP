#!/bin/bash
#
# Victim + Noisy Neighbor Baseline (WITHOUT FDP) using nvme-cli
# This provides an apples-to-apples comparison with the FDP version
# Expected: Higher latency variance due to GC interference
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
DURATION=30  # 30 seconds (same as FDP test)
VICTIM_IOPS_TARGET=300  # Same as FDP test
NOISY_IOPS_TARGET=600   # Same as FDP test
ERROR_LOG="/tmp/baseline_errors.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Clear error log
> "$ERROR_LOG"

echo "================================================"
echo "  Baseline QoS Test: Victim + Noisy Neighbor"
echo "  (WITHOUT FDP - Mixed Workloads)"
echo "================================================"
echo "Duration: $DURATION seconds"
echo "Victim: ${VICTIM_IOPS_TARGET} IOPS (NO FDP protection)"
echo "Noisy:  ${NOISY_IOPS_TARGET} IOPS (NO FDP separation)"
echo "Error log: $ERROR_LOG"
echo ""

# Disable FDP
echo_info "Disabling FDP for baseline test..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_info "FDP disabled (ONCS=$ONCS)"
echo ""

# Create results directory
RESULT_DIR="$(dirname "$0")/baseline_nvme_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"
echo_info "Results will be saved to: $RESULT_DIR"
echo ""

# Create latency log files
VICTIM_LAT_LOG="${RESULT_DIR}/victim_baseline_lat.log"
NOISY_LAT_LOG="${RESULT_DIR}/noisy_baseline_lat.log"

echo "timestamp_us,latency_us,iops,type" > "$VICTIM_LAT_LOG"
echo "timestamp_us,latency_us,iops,type" > "$NOISY_LAT_LOG"

# Function to run victim workload (NO FDP directives)
run_victim_workload() {
    echo "[VICTIM] Starting latency-sensitive workload (NO FDP protection)..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local lba=0
    local writes=0
    local reads=0
    local errors=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local timestamp=$(date +%s%N | cut -b1-16)
        
        # 70% reads, 30% writes (same ratio as FDP test)
        if [ $((RANDOM % 100)) -lt 70 ]; then
            # Read operation (NO FDP)
            local t1=$(date +%s%N)
            if nvme read $NVME_NS --start-block=$lba --block-count=7 \
                --data-size=4096 > /dev/null 2>>"$ERROR_LOG"; then
                local t2=$(date +%s%N)
                local lat=$(( (t2 - t1) / 1000 ))
                echo "$timestamp,$lat,1,read" >> "$VICTIM_LAT_LOG"
                reads=$((reads + 1))
            else
                errors=$((errors + 1))
                echo "[VICTIM] Read error at $(date)" >> "$ERROR_LOG"
            fi
        else
            # Write operation (NO FDP - no dir-type, no dir-spec)
            local t1=$(date +%s%N)
            if nvme write $NVME_NS --start-block=$lba --block-count=7 \
                --data=/dev/zero --data-size=4096 > /dev/null 2>>"$ERROR_LOG"; then
                local t2=$(date +%s%N)
                local lat=$(( (t2 - t1) / 1000 ))
                echo "$timestamp,$lat,1,write" >> "$VICTIM_LAT_LOG"
                writes=$((writes + 1))
            else
                errors=$((errors + 1))
                echo "[VICTIM] Write error at $(date)" >> "$ERROR_LOG"
            fi
        fi
        
        # Random LBA in victim range (0-2GB = 0-4194304 blocks)
        lba=$((RANDOM % 4194304))
        
        # Rate limiting: ~300 IOPS = 3333us per op
        sleep 0.0033 2>/dev/null || usleep 3333 2>/dev/null || sleep 0.003
        
        # Print progress every 100 ops
        if [ $((reads + writes)) -gt 0 ] && [ $(((reads + writes) % 100)) -eq 0 ]; then
            echo "[VICTIM] Progress: $reads reads, $writes writes, $errors errors"
        fi
    done
    
    echo "[VICTIM] Completed: $reads reads, $writes writes, $errors errors"
}

# Function to run noisy neighbor workload (NO FDP directives)
run_noisy_workload() {
    echo "[NOISY] Starting high-churn workload (NO FDP separation)..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local lba_base=6291456  # Start at 3GB offset
    local lba=0
    local writes=0
    local errors=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local timestamp=$(date +%s%N | cut -b1-16)
        
        # Write operation (NO FDP - no dir-type, no dir-spec)
        local t1=$(date +%s%N)
        if nvme write $NVME_NS --start-block=$((lba_base + lba)) --block-count=7 \
            --data=/dev/zero --data-size=4096 > /dev/null 2>>"$ERROR_LOG"; then
            local t2=$(date +%s%N)
            local lat=$(( (t2 - t1) / 1000 ))
            echo "$timestamp,$lat,1,write" >> "$NOISY_LAT_LOG"
            writes=$((writes + 1))
        else
            errors=$((errors + 1))
            echo "[NOISY] Write error at $(date)" >> "$ERROR_LOG"
        fi
        
        # Zipf-like distribution: 80% of accesses to 20% of space
        # Creates hot data (frequently rewritten) → triggers GC
        if [ $((RANDOM % 100)) -lt 80 ]; then
            # Hot data: first 20% of range
            lba=$((RANDOM % 419430))  # 20% of 2097152
        else
            # Cold data: full range
            lba=$((RANDOM % 2097152))  # 1GB range
        fi
        
        # Rate limiting: ~600 IOPS = 1666us per op
        sleep 0.0016 2>/dev/null || usleep 1666 2>/dev/null || sleep 0.002
        
        # Print progress every 100 ops
        if [ $((writes % 100)) -eq 0 ] && [ $writes -gt 0 ]; then
            echo "[NOISY] Progress: $writes writes, $errors errors"
        fi
    done
    
    echo "[NOISY] Completed: $writes writes, $errors errors"
}

echo "================================================"
echo "  Starting Concurrent Workloads"
echo "  (Both mixed in same RUs - NO isolation)"
echo "================================================"
echo ""

# Start both workloads in background
run_victim_workload &
VICTIM_PID=$!

run_noisy_workload &
NOISY_PID=$!

echo_info "Workloads running..."
echo "  Victim PID: $VICTIM_PID (NO FDP protection)"
echo "  Noisy PID:  $NOISY_PID (NO FDP separation)"
echo ""
echo "This will take $DURATION seconds..."
echo "Both workloads are mixed in the same RUs!"
echo "Monitoring for errors in: $ERROR_LOG"
echo ""

# Monitor progress
ELAPSED=0
CHECK_INTERVAL=5
while [ $ELAPSED -lt $((DURATION + 10)) ]; do
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
    
    # Check if both processes are still running
    if ! kill -0 $VICTIM_PID 2>/dev/null && ! kill -0 $NOISY_PID 2>/dev/null; then
        echo_info "Both workloads completed"
        break
    fi
    
    echo_info "Still running... ($((ELAPSED / CHECK_INTERVAL))x${CHECK_INTERVAL} seconds elapsed)"
    
    # Show any errors
    if [ -s "$ERROR_LOG" ]; then
        echo_warn "Errors detected! Last few:"
        tail -3 "$ERROR_LOG" | grep -v "^$" || echo "  (no recent errors)"
    fi
done

# Wait for both to finish
wait $VICTIM_PID 2>/dev/null
VICTIM_STATUS=$?
wait $NOISY_PID 2>/dev/null
NOISY_STATUS=$?

echo_info "Victim workload finished (status: $VICTIM_STATUS)"
echo_info "Noisy workload finished (status: $NOISY_STATUS)"
echo ""

echo "================================================"
echo "  Workloads Completed - Analyzing Results"
echo "================================================"
echo ""

# Analyze latency
analyze_latency() {
    local log_file=$1
    local name=$2
    
    if [ ! -s "$log_file" ]; then
        echo "[$name] No data collected"
        return
    fi
    
    # Skip header, extract latencies
    local latencies=$(tail -n +2 "$log_file" | cut -d',' -f2 | sort -n)
    local count=$(echo "$latencies" | wc -l)
    
    if [ $count -eq 0 ]; then
        echo "[$name] No valid latency data"
        return
    fi
    
    local min=$(echo "$latencies" | head -1)
    local max=$(echo "$latencies" | tail -1)
    local p50=$(echo "$latencies" | awk -v p=50 -v c=$count 'NR==int(c*p/100)+1')
    local p95=$(echo "$latencies" | awk -v p=95 -v c=$count 'NR==int(c*p/100)+1')
    local p99=$(echo "$latencies" | awk -v p=99 -v c=$count 'NR==int(c*p/100)+1')
    local avg=$(echo "$latencies" | awk '{sum+=$1} END {if(NR>0) print int(sum/NR); else print 0}')
    
    echo "[$name] Latency Statistics:"
    echo "  Operations: $count"
    echo "  Min:        ${min}us"
    echo "  Average:    ${avg}us"
    echo "  Median:     ${p50}us"
    echo "  95th:       ${p95}us"
    echo "  99th:       ${p99}us"
    echo "  Max:        ${max}us"
    echo ""
}

echo "================================================"
echo "  Latency Analysis"
echo "================================================"
echo ""

analyze_latency "$VICTIM_LAT_LOG" "VICTIM (NO FDP - Mixed with noisy)"
analyze_latency "$NOISY_LAT_LOG" "NOISY (NO FDP - Mixed with victim)"

echo "================================================"
echo "  Test Complete!"
echo "================================================"
echo ""
echo "Results saved to: $RESULT_DIR"
echo ""
echo "Characteristics of this test (WITHOUT FDP):"
echo "  ✗ Victim and noisy mixed in same RUs"
echo "  ✗ Noisy neighbor's GC impacts victim"
echo "  ✗ Higher latency variance expected"
echo "  ✗ Unpredictable tail latency (P99, P999)"
echo ""
echo "Compare with FDP test to see isolation benefits!"
echo ""

