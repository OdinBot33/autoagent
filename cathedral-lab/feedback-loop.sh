#!/bin/bash
# Cathedral Lab — Production Feedback Loop
#
# Pulls failure logs from Merlin on FURNACE, converts them into
# new benchmark tasks, and feeds them back to the lab.
#
# The loop:
#   1. SSH to FURNACE, pull recent Hermes failure logs
#   2. Extract failed commands, error patterns, task descriptions
#   3. Generate Harbor-format benchmark tasks from real failures
#   4. Add to cathedral-lab/tasks/ for next generation
#
# Usage: ./feedback-loop.sh
# Run after each lab cycle or on a cron

set +e

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
TASKS_DIR="$LAB_DIR/tasks"
FEEDBACK_DIR="$LAB_DIR/feedback"
FURNACE="furnace"
LOG="$LAB_DIR/logs/feedback-loop.log"

mkdir -p "$FEEDBACK_DIR" "$TASKS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Production Feedback Loop ==="

# ── 1. Pull Merlin's recent failure/error events ──────────
log "Pulling failure logs from FURNACE..."

# Hermes session logs with errors
ssh "$FURNACE" "find ~/.hermes/sessions/ -name '*.json' -mtime -7 -exec grep -l 'error\|Error\|FAIL\|failed\|exception' {} \;" 2>/dev/null > "$FEEDBACK_DIR/error-sessions.txt" || true

ERROR_COUNT=$(wc -l < "$FEEDBACK_DIR/error-sessions.txt" 2>/dev/null | tr -d ' ')
log "Found $ERROR_COUNT sessions with errors in last 7 days"

# Pull the actual error content
if [ "$ERROR_COUNT" -gt 0 ]; then
    # Get up to 10 most recent error sessions
    head -10 "$FEEDBACK_DIR/error-sessions.txt" | while read session_file; do
        basename_file=$(basename "$session_file" .json)
        ssh "$FURNACE" "cat '$session_file' 2>/dev/null" > "$FEEDBACK_DIR/session-${basename_file}.json" 2>/dev/null || true
    done
fi

# ── 2. Extract error patterns ─────────────────────────────
log "Extracting error patterns..."

python3 << 'PYEOF'
import json
import os
import re
from pathlib import Path
from collections import Counter

feedback_dir = Path(os.environ.get("FEEDBACK_DIR", "feedback"))
patterns = Counter()
failures = []

for f in feedback_dir.glob("session-*.json"):
    try:
        data = json.load(open(f))
        # Extract error messages from session
        content = json.dumps(data)
        
        # Common error patterns
        for pattern in [
            r'(FileNotFoundError: .*)',
            r'(PermissionError: .*)',
            r'(ModuleNotFoundError: .*)',
            r'(ConnectionRefusedError: .*)',
            r'(SyntaxError: .*)',
            r'(TypeError: .*)',
            r'(command not found: \S+)',
            r'(No such file or directory: .*)',
            r'(timeout|timed out)',
        ]:
            matches = re.findall(pattern, content, re.IGNORECASE)
            for m in matches[:3]:  # Limit per pattern
                clean = m[:200].strip()
                patterns[clean] += 1
                failures.append({"pattern": clean, "source": f.name})
    except (json.JSONDecodeError, Exception):
        continue

# Write extracted patterns
summary = {
    "timestamp": str(Path(feedback_dir).stat().st_mtime if feedback_dir.exists() else 0),
    "total_failures": len(failures),
    "top_patterns": patterns.most_common(10),
    "failures": failures[:20],
}
with open(feedback_dir / "patterns.json", "w") as f:
    json.dump(summary, f, indent=2)

print(f"Extracted {len(failures)} failures, {len(patterns)} unique patterns")
for p, count in patterns.most_common(5):
    print(f"  [{count}x] {p[:80]}")
PYEOF

# ── 3. Generate benchmark tasks from failures ─────────────
log "Generating benchmark tasks from failures..."

python3 << 'PYEOF'
import json
import os
from pathlib import Path
from datetime import datetime

feedback_dir = Path(os.environ.get("FEEDBACK_DIR", "feedback"))
tasks_dir = Path(os.environ.get("TASKS_DIR", "tasks"))

patterns_file = feedback_dir / "patterns.json"
if not patterns_file.exists():
    print("No patterns found. Skipping task generation.")
    exit(0)

patterns = json.load(open(patterns_file))
generated = 0

for pattern, count in patterns.get("top_patterns", [])[:3]:
    # Create a task that tests the agent's ability to handle this error
    task_name = f"prod-failure-{datetime.now().strftime('%Y%m%d')}-{generated}"
    task_dir = tasks_dir / task_name
    
    if task_dir.exists():
        continue

    task_dir.mkdir(parents=True, exist_ok=True)
    (task_dir / "tests").mkdir(exist_ok=True)
    (task_dir / "environment").mkdir(exist_ok=True)

    # task.toml
    (task_dir / "task.toml").write_text(f"""[task]
name = "{task_name}"
description = "Handle production failure pattern: {pattern[:60]}"
timeout_seconds = 300
max_attempts = 1

[task.metadata]
difficulty = "hard"
category = "production-failure"
source = "feedback-loop"
pattern_count = {count}
""")

    # instruction.md
    (task_dir / "instruction.md").write_text(f"""# Task: Handle Production Failure

A production system encountered this error pattern:

```
{pattern}
```

This error occurred {count} times in the last 7 days.

Your job:
1. Reproduce the error in the test environment
2. Diagnose the root cause
3. Implement a fix
4. Write a verification script at `/app/verify.sh` that proves the fix works
5. Write a prevention script at `/app/prevent.sh` that would catch this before production

Save your analysis to `/app/analysis.md`.
""")

    # Basic test.sh
    (task_dir / "tests" / "test.sh").write_text(f"""#!/bin/bash
SCORE=0
TOTAL=4

# Test 1: Analysis exists
[ -f /app/analysis.md ] && SCORE=$((SCORE+1)) && echo "PASS: analysis.md" || echo "FAIL: no analysis"

# Test 2: Analysis has content
[ $(wc -w < /app/analysis.md 2>/dev/null || echo 0) -gt 20 ] && SCORE=$((SCORE+1)) && echo "PASS: analysis has content" || echo "FAIL: analysis empty"

# Test 3: Verify script exists and runs
if [ -f /app/verify.sh ]; then
    chmod +x /app/verify.sh
    bash /app/verify.sh >/dev/null 2>&1 && SCORE=$((SCORE+1)) && echo "PASS: verify.sh passes" || echo "FAIL: verify.sh fails"
else
    echo "FAIL: no verify.sh"
fi

# Test 4: Prevention script exists
[ -f /app/prevent.sh ] && SCORE=$((SCORE+1)) && echo "PASS: prevent.sh" || echo "FAIL: no prevent.sh"

echo "$(python3 -c "print(round($SCORE/$TOTAL,4))")" > /logs/reward.txt
echo "Score: $SCORE/$TOTAL"
""")

    # Dockerfile
    (task_dir / "environment" / "Dockerfile").write_text("""FROM autoagent-base
RUN mkdir -p /app /logs
WORKDIR /app
""")

    generated += 1
    print(f"  Generated task: {task_name}")

print(f"Generated {generated} new benchmark tasks from production failures")
PYEOF

log "Feedback loop complete."
log "New tasks in: $TASKS_DIR"
