#!/bin/bash
# Verifier for terminal-coding task
# Writes score (0.0–1.0) to /logs/reward.txt

set -e
SCORE=0
TOTAL=6

# Create test data
mkdir -p /app/data
cat > /app/data/test.json << 'EOF'
[
  {"name": "Alice", "age": 30, "dept": "eng", "address": {"city": "NYC"}},
  {"name": "Bob", "age": 25, "dept": "sales", "address": {"city": "LA"}},
  {"name": "Charlie", "age": 35, "dept": "eng", "address": {"city": "SF"}},
  {"name": "Diana", "age": 28, "dept": "sales", "address": {"city": "NYC"}}
]
EOF

# Test 1: File exists and is executable
if [ -f /app/jproc.py ]; then
    SCORE=$((SCORE + 1))
    echo "PASS: jproc.py exists"
else
    echo "FAIL: jproc.py not found"
    echo "0.0" > /logs/reward.txt
    exit 0
fi

# Test 2: --count works
RESULT=$(python3 /app/jproc.py /app/data/test.json --count 2>/dev/null || echo "ERROR")
if echo "$RESULT" | grep -q "4"; then
    SCORE=$((SCORE + 1))
    echo "PASS: --count returns 4"
else
    echo "FAIL: --count returned '$RESULT'"
fi

# Test 3: --keys works
RESULT=$(python3 /app/jproc.py /app/data/test.json --keys 2>/dev/null || echo "ERROR")
if echo "$RESULT" | grep -q "name" && echo "$RESULT" | grep -q "age"; then
    SCORE=$((SCORE + 1))
    echo "PASS: --keys returns expected keys"
else
    echo "FAIL: --keys returned '$RESULT'"
fi

# Test 4: --filter works
RESULT=$(python3 /app/jproc.py /app/data/test.json --filter dept=eng 2>/dev/null || echo "ERROR")
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d)==2" 2>/dev/null; then
    SCORE=$((SCORE + 1))
    echo "PASS: --filter dept=eng returns 2 items"
else
    echo "FAIL: --filter returned '$RESULT'"
fi

# Test 5: --flatten works
RESULT=$(python3 /app/jproc.py /app/data/test.json --flatten 2>/dev/null || echo "ERROR")
if echo "$RESULT" | grep -q "address.city"; then
    SCORE=$((SCORE + 1))
    echo "PASS: --flatten uses dot notation"
else
    echo "FAIL: --flatten returned '$RESULT'"
fi

# Test 6: handles malformed JSON
echo "not json" | python3 /app/jproc.py - 2>/dev/null
if [ $? -ne 0 ]; then
    SCORE=$((SCORE + 1))
    echo "PASS: rejects malformed JSON"
else
    echo "FAIL: accepted malformed JSON"
fi

# Calculate and write score
FINAL=$(python3 -c "print(round($SCORE / $TOTAL, 4))")
echo "Score: $FINAL ($SCORE/$TOTAL)"
echo "$FINAL" > /logs/reward.txt
