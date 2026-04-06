#!/bin/bash
# Cathedral Lab — Sync distilled patterns to Merlin on FURNACE
#
# Reads the latest distilled skill and pushes it to Merlin's
# Hermes skills directory. Also updates Merlin's system prompt
# fragments if new patterns were discovered.
#
# Usage: ./sync-to-furnace.sh [--dry-run]

set -e

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTILL_DIR="$LAB_DIR/distilled"
FURNACE="furnace"  # SSH alias
MERLIN_SKILLS="~/.hermes/skills/cathedral-lab"
MERLIN_PROMPTS="~/.hermes/profiles/merlin/fragments"
DRY_RUN="${1:-}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ ! -d "$DISTILL_DIR" ]; then
    log "No distilled directory found. Run distill.py first."
    exit 1
fi

# Find latest winner
WINNER_FILE="$DISTILL_DIR/LATEST_WINNER.json"
if [ ! -f "$WINNER_FILE" ]; then
    log "No winner found. Run distill.py on a completed race first."
    # Fall back to latest skill file
    LATEST_SKILL=$(ls -t "$DISTILL_DIR"/skill-*.md 2>/dev/null | head -1)
    if [ -z "$LATEST_SKILL" ]; then
        log "No skill files found at all. Nothing to sync."
        exit 1
    fi
    log "Using latest skill: $(basename $LATEST_SKILL)"
else
    WINNER_SOURCE=$(python3 -c "import json; print(json.load(open('$WINNER_FILE'))['source'])" 2>/dev/null)
    WINNER_SCORE=$(python3 -c "import json; print(json.load(open('$WINNER_FILE'))['best_score'])" 2>/dev/null)
    LATEST_SKILL=$(python3 -c "import json; print(json.load(open('$WINNER_FILE'))['skill_path'])" 2>/dev/null)
    log "Winner: $WINNER_SOURCE (score: $WINNER_SCORE)"
    log "Skill: $(basename $LATEST_SKILL)"
fi

if [ "$DRY_RUN" = "--dry-run" ]; then
    log "DRY RUN — would sync:"
    log "  Skill: $(basename $LATEST_SKILL) → $FURNACE:$MERLIN_SKILLS/"
    log "  All summaries → $FURNACE:$MERLIN_SKILLS/summaries/"
    exit 0
fi

# Create directories on FURNACE
log "Creating directories on FURNACE..."
ssh "$FURNACE" "mkdir -p $MERLIN_SKILLS/summaries $MERLIN_PROMPTS" 2>/dev/null

# Sync the winning skill
log "Syncing winning skill..."
scp "$LATEST_SKILL" "$FURNACE:$MERLIN_SKILLS/$(basename $LATEST_SKILL)"

# Sync all summary JSONs for historical tracking
log "Syncing experiment summaries..."
scp "$DISTILL_DIR"/summary-*.json "$FURNACE:$MERLIN_SKILLS/summaries/" 2>/dev/null || true

# Sync the winner marker
if [ -f "$WINNER_FILE" ]; then
    scp "$WINNER_FILE" "$FURNACE:$MERLIN_SKILLS/LATEST_WINNER.json"
fi

# Extract and sync system prompt fragment from the winning patterns
if [ -f "$WINNER_FILE" ]; then
    log "Generating system prompt fragment..."
    python3 -c "
import json
w = json.load(open('$WINNER_FILE'))
p = w['patterns']
fragment = '''# AutoAgent Lab Discoveries (auto-generated)
# Score: {score} | Source: {source} | Date: $(date +%Y-%m-%d)

## Discovered Patterns
- Orchestration: {orch}
- Tools: {tools}
- Verification: {verif}
- Sub-agents: {sub}

## Winning System Prompt Fragment
{prompt}
'''.format(
    score=w['best_score'],
    source=w['source'],
    orch=p.get('orchestration_style', 'simple'),
    tools=', '.join(p.get('tools', [])) or 'baseline',
    verif='enabled' if p.get('has_verification') else 'disabled',
    sub='enabled' if p.get('has_sub_agents') else 'disabled',
    prompt=p.get('system_prompt', 'N/A')[:500]
)
print(fragment)
" > /tmp/lab-prompt-fragment.md 2>/dev/null

    scp /tmp/lab-prompt-fragment.md "$FURNACE:$MERLIN_PROMPTS/autoagent-latest.md" 2>/dev/null
    rm -f /tmp/lab-prompt-fragment.md
fi

log "Sync complete."
log ""
log "On FURNACE, Merlin now has:"
log "  Skills:   $MERLIN_SKILLS/"
log "  Prompts:  $MERLIN_PROMPTS/autoagent-latest.md"
log "  History:  $MERLIN_SKILLS/summaries/"
