#!/bin/bash
SCORE=0
TOTAL=6

# Test 1: pipeline.py exists
if [ -f /app/pipeline.py ]; then
    SCORE=$((SCORE + 1))
    echo "PASS: pipeline.py exists"
else
    echo "FAIL: pipeline.py not found"
    echo "0.0" > /logs/reward.txt
    exit 0
fi

# Test 2: pipeline runs without error
python3 /app/pipeline.py 2>/dev/null
if [ $? -eq 0 ]; then
    SCORE=$((SCORE + 1))
    echo "PASS: pipeline.py runs successfully"
else
    echo "FAIL: pipeline.py crashed"
fi

# Test 3: report.json exists and is valid JSON
if [ -f /app/output/report.json ]; then
    python3 -c "import json; json.load(open('/app/output/report.json'))" 2>/dev/null
    if [ $? -eq 0 ]; then
        SCORE=$((SCORE + 1))
        echo "PASS: report.json is valid JSON"
    else
        echo "FAIL: report.json is invalid JSON"
    fi
else
    echo "FAIL: report.json not found"
fi

# Test 4: report has required fields
python3 -c "
import json
r = json.load(open('/app/output/report.json'))
required = ['total_revenue', 'avg_order_value', 'top_products', 'monthly_revenue']
missing = [k for k in required if k not in r]
if missing:
    print(f'FAIL: missing fields: {missing}')
    exit(1)
print('PASS: all required fields present')
" 2>/dev/null && SCORE=$((SCORE + 1)) || echo "FAIL: missing required fields"

# Test 5: total_revenue is a positive number
python3 -c "
import json
r = json.load(open('/app/output/report.json'))
assert isinstance(r['total_revenue'], (int, float))
assert r['total_revenue'] > 0
print(f'PASS: total_revenue = {r[\"total_revenue\"]:.2f}')
" 2>/dev/null && SCORE=$((SCORE + 1)) || echo "FAIL: total_revenue invalid"

# Test 6: top_products has exactly 3 items sorted correctly
python3 -c "
import json
r = json.load(open('/app/output/report.json'))
tp = r['top_products']
assert len(tp) == 3, f'Expected 3 top products, got {len(tp)}'
assert tp[0]['revenue'] >= tp[1]['revenue'] >= tp[2]['revenue'], 'Not sorted'
print(f'PASS: top 3 products correctly sorted')
" 2>/dev/null && SCORE=$((SCORE + 1)) || echo "FAIL: top_products invalid"

FINAL=$(python3 -c "print(round($SCORE / $TOTAL, 4))")
echo "Score: $FINAL ($SCORE/$TOTAL)"
echo "$FINAL" > /logs/reward.txt
