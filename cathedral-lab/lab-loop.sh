#!/bin/bash
# Cathedral Lab 2.0 — 24/7 Continuous Harness Evolution
#
# Modes:
#   ./lab-loop.sh              Default: Claude meta-agent, 6hr cycles
#   ./lab-loop.sh 100x         All models compete, genetic evolution, model oracle
#   ./lab-loop.sh race [N]     N parallel variants (default 4)
#   ./lab-loop.sh [agent] [hrs] Single agent, custom cycle length
#
# Run in tmux:
#   tmux new -s cathedral-lab './lab-loop.sh 100x'

set +e

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$LAB_DIR")"
LOG_DIR="$LAB_DIR/logs"
TASKS_DIR="$LAB_DIR/tasks"
mkdir -p "$LOG_DIR"

MODE="${1:-claude}"
CYCLE_HOURS="${2:-6}"
CYCLE_SECONDS=$((CYCLE_HOURS * 3600))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/lab-loop.log"; }

# Load env
cd "$REPO_DIR"
if [ -f .env ]; then
    set -a; source .env 2>/dev/null; set +a
fi

# ── MODEL ORACLE: refresh model registry every cycle ──────
refresh_models() {
    log "Refreshing model oracle..."
    python3 "$LAB_DIR/model-oracle.py" >> "$LOG_DIR/model-oracle.log" 2>&1 || true

    # Get recommended models from registry
    if [ -f "$LAB_DIR/model-registry.json" ]; then
        CODING_MODEL=$(python3 -c "import json; r=json.load(open('$LAB_DIR/model-registry.json')); print(r.get('routing',{}).get('coding','qwen3-coder:latest'))" 2>/dev/null)
        REASONING_MODEL=$(python3 -c "import json; r=json.load(open('$LAB_DIR/model-registry.json')); print(r.get('routing',{}).get('reasoning','qwen3.5:35b-a3b'))" 2>/dev/null)
        FAST_MODEL=$(python3 -c "import json; r=json.load(open('$LAB_DIR/model-registry.json')); print(r.get('routing',{}).get('fast','gemma4:e4b'))" 2>/dev/null)
    else
        CODING_MODEL="qwen3-coder:latest"
        REASONING_MODEL="qwen3.5:35b-a3b"
        FAST_MODEL="gemma4:e4b"
    fi
    log "  Coding: $CODING_MODEL | Reasoning: $REASONING_MODEL | Fast: $FAST_MODEL"
}

# ── PREPARE HARNESS VARIANT ───────────────────────────────
# Creates agent.py variant with a specific local model
prepare_variant() {
    local workdir="$1"
    local model="$2"
    local variant_name="$3"

    cp "$REPO_DIR/agent.py" "$workdir/agent.py"
    cp "$REPO_DIR/agent-claude.py" "$workdir/agent-claude.py" 2>/dev/null || true
    cp "$REPO_DIR/program.md" "$workdir/program.md"
    cp "$REPO_DIR/pyproject.toml" "$workdir/pyproject.toml"
    cp "$REPO_DIR/uv.lock" "$workdir/uv.lock" 2>/dev/null || true
    cp "$REPO_DIR/Dockerfile.base" "$workdir/Dockerfile.base"
    cp "$REPO_DIR/.env" "$workdir/.env" 2>/dev/null || true
    cp -r "$TASKS_DIR" "$workdir/tasks" 2>/dev/null || true

    # Patch the model in agent.py
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|MODEL = \"gpt-5\"|MODEL = \"$model\"|g" "$workdir/agent.py"
    else
        sed -i "s|MODEL = \"gpt-5\"|MODEL = \"$model\"|g" "$workdir/agent.py"
    fi

    # Patch to use local Ollama endpoint (for OpenAI Agents SDK)
    # Add OPENAI_BASE_URL override for local inference
    cat >> "$workdir/.env" << EOF
OPENAI_BASE_URL=http://host.docker.internal:11434/v1
OPENAI_API_KEY=ollama
EOF

    log "  Variant '$variant_name' prepared with model: $model"
}

# ── GENETIC CROSSOVER ─────────────────────────────────────
# Takes two winning agent.py files and produces a child
crossover() {
    local parent1="$1"
    local parent2="$2"
    local child="$3"

    python3 << PYEOF
import re

with open("$parent1") as f:
    p1 = f.read()
with open("$parent2") as f:
    p2 = f.read()

# Extract system prompts
sp1 = re.search(r'SYSTEM_PROMPT\s*=\s*"""(.*?)"""', p1, re.DOTALL)
sp2 = re.search(r'SYSTEM_PROMPT\s*=\s*"""(.*?)"""', p2, re.DOTALL)

# Extract tool sections
tools1 = re.findall(r'(@function_tool.*?(?=@function_tool|def create_))', p1, re.DOTALL)
tools2 = re.findall(r'(@function_tool.*?(?=@function_tool|def create_))', p2, re.DOTALL)

# Crossover: take prompt from parent1, tools from parent2
child_code = p1
if sp1 and sp2:
    # Merge prompts (take longer one which usually has more instructions)
    if len(sp2.group(1)) > len(sp1.group(1)):
        child_code = child_code.replace(sp1.group(1), sp2.group(1))

# Merge tools: combine unique tools from both parents
all_tool_names = set()
merged_tools = []
for t in tools1 + tools2:
    name_match = re.search(r'async def (\w+)\(', t)
    if name_match and name_match.group(1) not in all_tool_names:
        all_tool_names.add(name_match.group(1))
        merged_tools.append(t)

with open("$child", 'w') as f:
    f.write(child_code)

print(f"Crossover: {len(merged_tools)} unique tools from {len(tools1)}+{len(tools2)} parents")
PYEOF
}

# ── RUN EXPERIMENT ────────────────────────────────────────
run_experiment() {
    local workdir="$1"
    local meta_agent="$2"
    local timeout_sec="$3"
    local logfile="$4"

    local prompt="Read program.md and kick off a new experiment. You are running on $(hostname) in directory $workdir. The task agent uses a LOCAL Ollama model — do NOT change it to a cloud model. Work autonomously, never stop iterating. Focus on improving tools and orchestration, not the model."

    cd "$workdir"

    case "$meta_agent" in
        claude)
            timeout "${timeout_sec}s" claude --dangerously-skip-permissions \
                -p "$prompt" >> "$logfile" 2>&1 || true
            ;;
        codex)
            timeout "${timeout_sec}s" codex \
                -p "$prompt" >> "$logfile" 2>&1 || true
            ;;
        hermes)
            timeout "${timeout_sec}s" ~/.local/bin/hermes \
                -p "$prompt" >> "$logfile" 2>&1 || true
            ;;
        odin)
            timeout "${timeout_sec}s" openclaw agent --local \
                --message "$prompt" --timeout "$timeout_sec" >> "$logfile" 2>&1 || true
            ;;
    esac
}

# ══════════════════════════════════════════════════════════
# ── 100x MODE: genetic evolution + parallel + model oracle
# ══════════════════════════════════════════════════════════
run_100x() {
    log "=== CATHEDRAL LAB 2.0 — 100x MODE ==="
    log "Parallel variants with genetic evolution"
    log "All task agents local ($0 API cost)"
    log ""

    GENERATION=0

    while true; do
        GENERATION=$((GENERATION + 1))
        GEN_START=$(date +%s)
        GEN_DIR="$LAB_DIR/generations/gen-${GENERATION}-$(date +%Y%m%d-%H%M)"
        mkdir -p "$GEN_DIR"

        log "--- GENERATION $GENERATION ---"

        # Refresh model oracle
        refresh_models

        # Define variants: each gets a different model + meta-agent combo
        declare -a VARIANTS=(
            "claude:${CODING_MODEL}:coding-claude"
            "codex:${CODING_MODEL}:coding-codex"
            "claude:${REASONING_MODEL}:reasoning-claude"
            "claude:${FAST_MODEL}:fast-claude"
        )

        # If we have previous winners, add crossover variants
        PREV_WINNER="$LAB_DIR/distilled/LATEST_WINNER.json"
        if [ -f "$PREV_WINNER" ] && [ "$GENERATION" -gt 1 ]; then
            VARIANTS+=("claude:${CODING_MODEL}:crossover-coding")
            log "  Added crossover variant from previous winner"
        fi

        VARIANT_COUNT=${#VARIANTS[@]}
        log "  Launching $VARIANT_COUNT variants..."

        # Launch all variants in parallel tmux sessions
        PIDS=()
        for variant_spec in "${VARIANTS[@]}"; do
            IFS=':' read -r meta_agent task_model variant_name <<< "$variant_spec"
            VDIR="$GEN_DIR/$variant_name"
            mkdir -p "$VDIR"
            VLOG="$GEN_DIR/${variant_name}.log"

            prepare_variant "$VDIR" "$task_model" "$variant_name"

            # Launch in tmux
            tmux new-session -d -s "lab-${variant_name}" \
                "cd $VDIR && source .env 2>/dev/null; $(
                    case $meta_agent in
                        claude) echo "claude --dangerously-skip-permissions -p 'Read program.md and kick off a new experiment. Task agent uses LOCAL model $task_model. Improve tools and orchestration, not the model. Never stop.'";;
                        codex) echo "codex -p 'Read program.md and kick off a new experiment. Task agent uses LOCAL model $task_model. Improve tools and orchestration. Never stop.'";;
                        hermes) echo "~/.local/bin/hermes -p 'Read program.md and kick off. Task agent uses LOCAL model $task_model. Never stop.'";;
                        odin) echo "openclaw agent --local --message 'Read program.md and kick off. Task agent uses LOCAL model $task_model. Never stop.' --timeout 86400";;
                    esac
                ) 2>&1 | tee $VLOG" 2>/dev/null

            log "  Started: $variant_name ($meta_agent + $task_model)"
        done

        # Wait for cycle duration
        log "  All variants running. Waiting ${CYCLE_HOURS}h..."
        sleep "$CYCLE_SECONDS"

        # Kill all variant sessions
        log "  Stopping all variants..."
        for variant_spec in "${VARIANTS[@]}"; do
            IFS=':' read -r _ _ variant_name <<< "$variant_spec"
            tmux kill-session -t "lab-${variant_name}" 2>/dev/null || true
        done

        # Distill results from this generation
        log "  Distilling generation $GENERATION..."
        python3 "$LAB_DIR/distill.py" "$GEN_DIR" >> "$LOG_DIR/distill.log" 2>&1 || true

        # Sync winners to FURNACE
        log "  Syncing to Merlin..."
        bash "$LAB_DIR/sync-to-furnace.sh" >> "$LOG_DIR/sync.log" 2>&1 || {
            log "  WARNING: sync to FURNACE failed"
        }

        # Auto-deploy if score is good enough
        log "  Auto-deploying winners..."
        bash "$LAB_DIR/auto-deploy.sh" >> "$LOG_DIR/deploy.log" 2>&1 || true

        # Pull production failures as new benchmarks
        log "  Running feedback loop..."
        bash "$LAB_DIR/feedback-loop.sh" >> "$LOG_DIR/feedback.log" 2>&1 || true

        # Update leaderboard
        bash "$LAB_DIR/leaderboard.sh" --obsidian >> "$LOG_DIR/leaderboard.log" 2>&1 || true

        # Auto-pull new models (every 4th generation)
        if [ $((GENERATION % 4)) -eq 0 ]; then
            log "  Checking for new models..."
            python3 "$LAB_DIR/auto-model-pull.py" >> "$LOG_DIR/model-pull.log" 2>&1 || true
        fi

        # Docker cleanup
        docker container prune -f >/dev/null 2>&1 || true
        docker image prune -f >/dev/null 2>&1 || true

        # Generation summary
        GEN_END=$(date +%s)
        GEN_DURATION=$(( (GEN_END - GEN_START) / 60 ))

        WINNER_INFO="none"
        if [ -f "$LAB_DIR/distilled/LATEST_WINNER.json" ]; then
            WINNER_INFO=$(python3 -c "
import json
w = json.load(open('$LAB_DIR/distilled/LATEST_WINNER.json'))
print(f\"{w['source']}: {w['best_score']:.3f}\")
" 2>/dev/null || echo "unknown")
        fi

        log "  Generation $GENERATION: ${GEN_DURATION}min | ${VARIANT_COUNT} variants | Winner: $WINNER_INFO"
        log "--- GENERATION $GENERATION END ---"
        log ""

        # Brief cooldown
        sleep 300
    done
}

# ══════════════════════════════════════════════════════════
# ── MAIN DISPATCH ─────────────────────────────────────────
# ══════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       CATHEDRAL LAB 2.0 — Self-Improving Factory    ║"
printf "║  Node: %-46s ║\n" "$(hostname)"
printf "║  Mode: %-46s ║\n" "$MODE"
printf "║  Tasks: %-45s ║\n" "$(ls -d $TASKS_DIR/*/ 2>/dev/null | wc -l | tr -d ' ') benchmarks"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

case "$MODE" in
    100x)
        run_100x
        ;;
    race)
        CYCLE_HOURS="${2:-6}"
        CYCLE_SECONDS=$((CYCLE_HOURS * 3600))
        # Race is just 100x with a fixed cycle
        run_100x
        ;;
    claude|codex|hermes|odin)
        # Single agent mode
        refresh_models
        CYCLE=0
        while true; do
            CYCLE=$((CYCLE + 1))
            log "--- CYCLE $CYCLE ($MODE) ---"
            CYCLE_LOG="$LOG_DIR/cycle-${CYCLE}-$(date +%Y%m%d-%H%M).log"
            run_experiment "$REPO_DIR" "$MODE" "$CYCLE_SECONDS" "$CYCLE_LOG"
            python3 "$LAB_DIR/distill.py" "$REPO_DIR" >> "$LOG_DIR/distill.log" 2>&1 || true
            bash "$LAB_DIR/sync-to-furnace.sh" >> "$LOG_DIR/sync.log" 2>&1 || true
            docker container prune -f >/dev/null 2>&1 || true
            log "--- CYCLE $CYCLE END ---"
            sleep 300
        done
        ;;
    *)
        echo "Usage: $0 [100x|race|claude|codex|hermes|odin] [cycle_hours]"
        echo ""
        echo "  100x          Genetic evolution, all models compete (recommended)"
        echo "  race [N]      N-hour cycles, all 4 meta-agents"
        echo "  claude [N]    Claude Code only, N-hour cycles"
        echo "  codex [N]     Codex only"
        echo "  hermes [N]    Hermes only"
        echo "  odin [N]      OpenClaw only"
        exit 1
        ;;
esac
