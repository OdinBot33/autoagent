#!/bin/bash
# Cathedral AutoAgent Runner
# Usage: ./run-autoagent.sh [meta-agent|race] [task-branch]
#   meta-agent: claude | codex | hermes | odin | race (default: claude)
#   task-branch: git branch with tasks/ populated (default: current)
#
# "race" mode runs ALL meta-agents in parallel on the same benchmark,
# each in its own git worktree. Compare results.tsv across all four.
#
# Examples:
#   ./run-autoagent.sh              # Claude Code as meta-agent
#   ./run-autoagent.sh odin         # Odin (OpenClaw) as meta-agent
#   ./run-autoagent.sh race         # All 4 meta-agents compete in parallel
#   ./run-autoagent.sh claude spreadsheetbench

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

META_AGENT="${1:-claude}"
TASK_BRANCH="${2:-}"
AUTOAGENT_PROMPT="Read program.md and let's kick off a new experiment! You are running on $(hostname). Work autonomously — never stop iterating."

# Load env
if [ -f .env ]; then
    set -a; source .env; set +a
fi

# Switch branch if specified
if [ -n "$TASK_BRANCH" ] && [ "$META_AGENT" != "race" ]; then
    echo "Switching to branch: $TASK_BRANCH"
    git checkout "$TASK_BRANCH" 2>/dev/null || git checkout -b "$TASK_BRANCH"
fi

# Ensure Docker image is built
echo "Ensuring autoagent-base Docker image..."
docker build -f Dockerfile.base -t autoagent-base . -q 2>/dev/null

# Ensure deps
uv sync --quiet 2>/dev/null

banner() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║       AUTOAGENT — Cathedral Edition          ║"
    printf "║  Node: %-37s ║\n" "$(hostname | cut -c1-37)"
    printf "║  Meta-Agent: %-32s ║\n" "$1"
    printf "║  Branch: %-36s ║\n" "$(git branch --show-current)"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

launch_agent() {
    local agent="$1"
    local workdir="$2"
    local prompt="$3"

    cd "$workdir"

    case "$agent" in
        claude)
            claude --dangerously-skip-permissions -p "$prompt"
            ;;
        codex)
            codex -p "$prompt"
            ;;
        hermes)
            ~/.local/bin/hermes -p "$prompt"
            ;;
        odin|openclaw)
            if openclaw health >/dev/null 2>&1; then
                openclaw tui --message "$prompt"
            else
                openclaw agent --local --message "$prompt" --timeout 86400
            fi
            ;;
    esac
}

# ── RACE MODE: all 4 meta-agents compete in parallel ─────────
if [ "$META_AGENT" = "race" ]; then
    RACE_DIR="$REPO_DIR/.race-$(date +%Y%m%d-%H%M)"
    mkdir -p "$RACE_DIR"
    BRANCH="${TASK_BRANCH:-$(git branch --show-current)}"

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║       AUTOAGENT RACE — Cathedral Edition     ║"
    echo "║       4 meta-agents. 1 benchmark. Fight.     ║"
    printf "║  Node: %-37s ║\n" "$(hostname)"
    printf "║  Branch: %-36s ║\n" "$BRANCH"
    printf "║  Race dir: %-34s ║\n" "$(basename $RACE_DIR)"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    AGENTS=(claude codex hermes odin)
    PIDS=()
    LOGS=()

    for agent in "${AGENTS[@]}"; do
        WORKTREE="$RACE_DIR/$agent"
        LOG="$RACE_DIR/$agent.log"

        # Create isolated worktree for each agent
        git worktree add "$WORKTREE" "$BRANCH" --detach 2>/dev/null || {
            # If worktree fails, copy instead
            cp -r "$REPO_DIR" "$WORKTREE"
        }
        cp "$REPO_DIR/.env" "$WORKTREE/.env" 2>/dev/null || true

        echo "  Launching $agent → $LOG"

        # Launch each meta-agent in background with its own tmux session
        tmux new-session -d -s "autoagent-$agent" \
            "cd $WORKTREE && source .env 2>/dev/null; $(
                case $agent in
                    claude) echo "claude --dangerously-skip-permissions -p \"$AUTOAGENT_PROMPT\"";;
                    codex) echo "codex -p \"$AUTOAGENT_PROMPT\"";;
                    hermes) echo "~/.local/bin/hermes -p \"$AUTOAGENT_PROMPT\"";;
                    odin) echo "openclaw agent --local --message \"$AUTOAGENT_PROMPT\" --timeout 86400";;
                esac
            ) 2>&1 | tee $LOG" 2>/dev/null && \
            PIDS+=("tmux:autoagent-$agent") || echo "  WARNING: failed to launch $agent"

        LOGS+=("$LOG")
    done

    echo ""
    echo "All agents launched in tmux sessions."
    echo ""
    echo "Monitor:"
    echo "  tmux attach -t autoagent-claude   # Watch Claude"
    echo "  tmux attach -t autoagent-codex    # Watch Codex"
    echo "  tmux attach -t autoagent-hermes   # Watch Hermes"
    echo "  tmux attach -t autoagent-odin     # Watch Odin"
    echo ""
    echo "Compare results:"
    echo "  diff $RACE_DIR/claude/results.tsv $RACE_DIR/codex/results.tsv"
    echo "  cat $RACE_DIR/*/results.tsv | sort -t'\t' -k2 -rn"
    echo ""
    echo "Kill all:"
    echo "  tmux kill-session -t autoagent-claude"
    echo "  tmux kill-session -t autoagent-codex"
    echo "  tmux kill-session -t autoagent-hermes"
    echo "  tmux kill-session -t autoagent-odin"
    echo ""
    echo "Clean up worktrees after:"
    echo "  cd $REPO_DIR && git worktree prune"
    exit 0
fi

# ── SINGLE AGENT MODE ────────────────────────────────────────
banner "$META_AGENT"
echo "Launching meta-agent..."
echo "The meta-agent will read program.md and begin the experiment loop."
echo ""
launch_agent "$META_AGENT" "$REPO_DIR" "$AUTOAGENT_PROMPT"
