#!/bin/bash
#
# run-benchmarks.sh
# Runs both io-bench and nio-bench in release mode and prints results.
#
# Usage:
#   ./run-benchmarks.sh              # Run all benchmarks
#   ./run-benchmarks.sh throughput   # Filter by name
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER="${1:-}"

echo "========================================"
echo " swift-io vs NIO Benchmark Suite"
echo "========================================"
echo ""

# Build both first
echo "Building io-bench (release)..."
(cd "$SCRIPT_DIR/io-bench" && swift build -c release 2>&1 | tail -1)
echo ""

echo "Building nio-bench (release)..."
(cd "$SCRIPT_DIR/nio-bench" && swift build -c release 2>&1 | tail -1)
echo ""

# Run io-bench
echo "========================================"
echo " swift-io Benchmarks"
echo "========================================"
echo ""

if [ -n "$FILTER" ]; then
    (cd "$SCRIPT_DIR/io-bench" && swift test -c release --filter "$FILTER" 2>&1) || true
else
    (cd "$SCRIPT_DIR/io-bench" && swift test -c release 2>&1) || true
fi

echo ""
echo "========================================"
echo " NIO Benchmarks"
echo "========================================"
echo ""

if [ -n "$FILTER" ]; then
    (cd "$SCRIPT_DIR/nio-bench" && swift test -c release --filter "$FILTER" 2>&1) || true
else
    (cd "$SCRIPT_DIR/nio-bench" && swift test -c release 2>&1) || true
fi

echo ""
echo "========================================"
echo " Done"
echo "========================================"
