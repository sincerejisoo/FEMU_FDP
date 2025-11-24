#!/bin/bash
#
# Quick FIO syntax checker
# Tests if fio files have valid syntax without actually running I/O
#

echo "Testing FIO file syntax..."
echo ""

ERRORS=0

for fio_file in *.fio; do
    if [ -f "$fio_file" ]; then
        echo -n "Checking $fio_file... "
        if fio --parse-only "$fio_file" > /dev/null 2>&1; then
            echo "✓ OK"
        else
            echo "✗ FAILED"
            echo "  Running detailed check:"
            fio --parse-only "$fio_file" 2>&1 | head -10
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "✓ All FIO files have valid syntax!"
    exit 0
else
    echo "✗ Found $ERRORS file(s) with errors"
    exit 1
fi

