#!/bin/bash
# Verifier for sysadmin-debug task
SCORE=0
TOTAL=7

# Wait for server to be ready
sleep 2

# Test 1: Server is running on port 5000
if curl -s http://localhost:5000/ >/dev/null 2>&1; then
    SCORE=$((SCORE + 1))
    echo "PASS: Server is running on port 5000"
else
    echo "FAIL: Server not responding on port 5000"
    echo "0.0" > /logs/reward.txt
    exit 0
fi

# Test 2: Root returns status ok
RESULT=$(curl -s http://localhost:5000/)
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='ok'" 2>/dev/null; then
    SCORE=$((SCORE + 1))
    echo "PASS: GET / returns status ok"
else
    echo "FAIL: GET / returned '$RESULT'"
fi

# Test 3: GET /users returns array
RESULT=$(curl -s http://localhost:5000/users)
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)" 2>/dev/null; then
    SCORE=$((SCORE + 1))
    echo "PASS: GET /users returns array"
else
    echo "FAIL: GET /users returned '$RESULT'"
fi

# Test 4: POST /users creates a user
RESULT=$(curl -s -X POST http://localhost:5000/users \
    -H "Content-Type: application/json" \
    -d '{"name":"Test User","email":"test@example.com"}')
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['name']=='Test User'" 2>/dev/null; then
    SCORE=$((SCORE + 1))
    echo "PASS: POST /users creates user"
else
    echo "FAIL: POST /users returned '$RESULT'"
fi

# Test 5: GET /users/1 returns the created user
RESULT=$(curl -s http://localhost:5000/users/1)
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['name']=='Test User'" 2>/dev/null; then
    SCORE=$((SCORE + 1))
    echo "PASS: GET /users/1 returns correct user"
else
    echo "FAIL: GET /users/1 returned '$RESULT'"
fi

# Test 6: Healthcheck script exists and works
if [ -f /app/healthcheck.sh ]; then
    chmod +x /app/healthcheck.sh
    if bash /app/healthcheck.sh >/dev/null 2>&1; then
        SCORE=$((SCORE + 1))
        echo "PASS: healthcheck.sh exists and passes"
    else
        echo "FAIL: healthcheck.sh exists but fails"
    fi
else
    echo "FAIL: healthcheck.sh not found"
fi

# Test 7: All 5 bugs were fixed (check server.py for corrections)
FIXED=0
SERVER=$(cat /app/server.py 2>/dev/null)
echo "$SERVER" | grep -q "__name__" && FIXED=$((FIXED + 1))         # Bug 1
echo "$SERVER" | grep -q "load_users()" && FIXED=$((FIXED + 1))     # Bug 2
echo "$SERVER" | grep -q "int(id)" && FIXED=$((FIXED + 1)) || \
echo "$SERVER" | grep -q "<int:id>" && FIXED=$((FIXED + 1))         # Bug 3+4
echo "$SERVER" | grep -q "port=5000" && FIXED=$((FIXED + 1))        # Bug 5

if [ "$FIXED" -ge 3 ]; then
    SCORE=$((SCORE + 1))
    echo "PASS: $FIXED/5 bugs fixed in server.py"
else
    echo "FAIL: only $FIXED/5 bugs fixed"
fi

FINAL=$(python3 -c "print(round($SCORE / $TOTAL, 4))")
echo "Score: $FINAL ($SCORE/$TOTAL)"
echo "$FINAL" > /logs/reward.txt
