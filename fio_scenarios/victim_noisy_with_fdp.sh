#!/bin/bash
#
# Victim + Noisy Neighbor WITH FDP
# Demonstrates FDP's QoS isolation benefits
# Expected: Low victim latency variance, isolated from noisy neighbor's GC
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
DURATION=30  # 30 seconds (reduced for stability)
VICTIM_IOPS_TARGET=300  # Reduced from 500
NOISY_IOPS_TARGET=600  # Reduced from 1000
ERROR_LOG="/tmp/fdp_errors.log"

# FDP Placement Handles
VICTIM_PH=0    # Victim → RU 0 (isolated)
NOISY_PH=1     # Noisy → RU 1 (separate RU)

echo "================================================"
echo "  FDP QoS Test: Victim + Noisy Neighbor"
echo "================================================"
echo "Duration: ${DURATION} seconds"
echo "Victim PH: ${VICTIM_PH} (latency-sensitive, ${VICTIM_IOPS_TARGET} IOPS)"
echo "Noisy PH:  ${NOISY_PH} (high-churn, ${NOISY_IOPS_TARGET} IOPS)"
echo "Error log: ${ERROR_LOG}"
echo ""

# Clear error log
> "$ERROR_LOG"

# Check if FDP is enabled
oncs=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
if [ "$oncs" != "0x204" ]; then
    echo "[ERROR] FDP not enabled (ONCS=$oncs)"
    echo "Run: sudo nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8"
    exit 1
fi

echo "[INFO] FDP enabled (ONCS=$oncs)"
echo ""

# Get initial FDP statistics
echo "[INFO] Collecting initial FDP statistics..."
nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b 2>/dev/null > /tmp/fdp_stats_before.bin

# Create results directory
RESULT_DIR="$(dirname "$0")/fdp_qos_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"
echo "[INFO] Results will be saved to: $RESULT_DIR"
echo ""

# Create latency log files
VICTIM_LAT_LOG="${RESULT_DIR}/victim_with_fdp_lat.log"
NOISY_LAT_LOG="${RESULT_DIR}/noisy_with_fdp_lat.log"

echo "timestamp_us,latency_us,iops,type" > "$VICTIM_LAT_LOG"
echo "timestamp_us,latency_us,iops,type" > "$NOISY_LAT_LOG"

# Function to run victim workload
run_victim_workload() {
    echo "[VICTIM] Starting latency-sensitive workload (PH=${VICTIM_PH})..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local lba=0
    local writes=0
    local reads=0
    local errors=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local timestamp=$(date +%s%N | cut -b1-16)
        
        # 70% reads, 30% writes
        if [ $((RANDOM % 100)) -lt 70 ]; then
            # Read operation
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
            # Write operation with FDP hint
            local t1=$(date +%s%N)
            if nvme write $NVME_NS --start-block=$lba --block-count=7 \
                --data=/dev/zero --data-size=4096 \
                --dir-type=2 --dir-spec=$VICTIM_PH > /dev/null 2>>"$ERROR_LOG"; then
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
        
        # Rate limiting: ~500 IOPS = 2000us per op (MUCH slower)
        sleep 0.002 2>/dev/null || sleep 0.002
        
        # Print progress every 100 ops
        if [ $((reads + writes)) -gt 0 ] && [ $(((reads + writes) % 100)) -eq 0 ]; then
            echo "[VICTIM] Progress: $reads reads, $writes writes, $errors errors"
        fi
    done
    
    echo "[VICTIM] Completed: $reads reads, $writes writes, $errors errors"
}

# Function to run noisy neighbor workload
run_noisy_workload() {
    echo "[NOISY] Starting high-churn workload (PH=${NOISY_PH})..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local lba_base=6291456  # Start at 3GB offset
    local lba=0
    local writes=0
    local errors=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local timestamp=$(date +%s%N | cut -b1-16)
        
        # Write operation with FDP hint (noisy PH)
        local t1=$(date +%s%N)
        if nvme write $NVME_NS --start-block=$((lba_base + lba)) --block-count=7 \
            --data=/dev/zero --data-size=4096 \
            --dir-type=2 --dir-spec=$NOISY_PH > /dev/null 2>>"$ERROR_LOG"; then
            local t2=$(date +%s%N)
            local lat=$(( (t2 - t1) / 1000 ))
            echo "$timestamp,$lat,1,write" >> "$NOISY_LAT_LOG"
            writes=$((writes + 1))
        else
            errors=$((errors + 1))
            echo "[NOISY] Write error at $(date)" >> "$ERROR_LOG"
        fi
        
        # Zipf-like distribution: 80% of accesses to 20% of space
        if [ $((RANDOM % 100)) -lt 80 ]; then
            # Hot region: first 200MB (409600 blocks)
            lba=$((RANDOM % 409600))
        else
            # Cold region: remaining 800MB
            lba=$((409600 + RANDOM % 1638400))
        fi
        
        # Rate limiting: ~1000 IOPS = 1000us per op (MUCH slower)
        sleep 0.001 2>/dev/null || sleep 0.001
        
        # Print progress every 100 ops
        if [ $writes -gt 0 ] && [ $((writes % 100)) -eq 0 ]; then
            echo "[NOISY] Progress: $writes writes, $errors errors"
        fi
    done
    
    echo "[NOISY] Completed: $writes writes, $errors errors"
}

echo "================================================"
echo "  Starting Concurrent Workloads"
echo "================================================"
echo ""

# Run both workloads in parallel
run_victim_workload &
VICTIM_PID=$!

run_noisy_workload &
NOISY_PID=$!

echo "[INFO] Workloads running..."
echo "  Victim PID: $VICTIM_PID (PH=${VICTIM_PH})"
echo "  Noisy PID:  $NOISY_PID (PH=${NOISY_PH})"
echo ""
echo "This will take ${DURATION} seconds..."
echo "Monitoring for errors in: $ERROR_LOG"
echo ""

# Monitor both processes
victim_running=1
noisy_running=1
check_count=0

while [ $victim_running -eq 1 ] || [ $noisy_running -eq 1 ]; do
    sleep 5
    check_count=$((check_count + 1))
    
    # Check if victim is still running
    if [ $victim_running -eq 1 ] && ! kill -0 $VICTIM_PID 2>/dev/null; then
        wait $VICTIM_PID
        victim_status=$?
        echo "[INFO] Victim workload finished (status: $victim_status)"
        victim_running=0
    fi
    
    # Check if noisy is still running
    if [ $noisy_running -eq 1 ] && ! kill -0 $NOISY_PID 2>/dev/null; then
        wait $NOISY_PID
        noisy_status=$?
        echo "[INFO] Noisy workload finished (status: $noisy_status)"
        noisy_running=0
    fi
    
    # Print status every 10 seconds
    if [ $((check_count % 2)) -eq 0 ]; then
        echo "[INFO] Still running... (${check_count}x5 seconds elapsed)"
        if [ -s "$ERROR_LOG" ]; then
            echo "[WARNING] Errors detected! Last few:"
            tail -3 "$ERROR_LOG"
        fi
    fi
done

echo "[INFO] Both workloads completed"

# Final wait to collect exit codes
wait $VICTIM_PID 2>/dev/null
wait $NOISY_PID 2>/dev/null

echo ""
echo "================================================"
echo "  Workloads Completed - Collecting Statistics"
echo "================================================"
echo ""

# Get final FDP statistics
echo "[INFO] Collecting final FDP statistics..."
nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b 2>/dev/null > /tmp/fdp_stats_after.bin

# Copy stats to result directory
cp /tmp/fdp_stats_before.bin "${RESULT_DIR}/"
cp /tmp/fdp_stats_after.bin "${RESULT_DIR}/"

# Analyze latency
echo ""
echo "================================================"
echo "  Latency Analysis"
echo "================================================"
echo ""

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

analyze_latency "$VICTIM_LAT_LOG" "VICTIM (FDP-isolated)"
analyze_latency "$NOISY_LAT_LOG" "NOISY (FDP-isolated)"

# Analyze FDP statistics
echo "================================================"
echo "  FDP Statistics Comparison"
echo "================================================"
echo ""

parse_fdp_stats() {
    local stats_file=$1
    # host_bytes_written[16] is at offset 0
    # RU 0 = offset 0, RU 1 = offset 8, RU 2 = offset 16, RU 3 = offset 24
    # Use od to parse little-endian uint64
    local ru0=$(od -An -t x8 -N 8 -j 0 "$stats_file" 2>/dev/null | tr -d ' ')
    local ru1=$(od -An -t x8 -N 8 -j 8 "$stats_file" 2>/dev/null | tr -d ' ')
    local ru2=$(od -An -t x8 -N 8 -j 16 "$stats_file" 2>/dev/null | tr -d ' ')
    local ru3=$(od -An -t x8 -N 8 -j 24 "$stats_file" 2>/dev/null | tr -d ' ')
    
    echo "RU 0: 0x$ru0 bytes"
    echo "RU 1: 0x$ru1 bytes"
    echo "RU 2: 0x$ru2 bytes"
    echo "RU 3: 0x$ru3 bytes"
}

echo "Before test:"
parse_fdp_stats "${RESULT_DIR}/fdp_stats_before.bin"
echo ""
echo "After test:"
parse_fdp_stats "${RESULT_DIR}/fdp_stats_after.bin"
echo ""

echo "================================================"
echo "  Test Complete!"
echo "================================================"
echo ""
echo "Results saved to: $RESULT_DIR"
echo ""
echo "Expected Results:"
echo "  - Victim workload → RU $VICTIM_PH (isolated)"
echo "  - Noisy workload → RU $NOISY_PH (isolated)"
echo "  - Low victim latency variance (no GC interference)"
echo "  - High noisy RU $NOISY_PH bytes written"
echo ""
echo "Compare with baseline test (no FDP) to see QoS improvement!"
echo ""

