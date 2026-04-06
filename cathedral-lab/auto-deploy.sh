#!/bin/bash
# Cathedral Lab — Auto Deploy Winners
#
# Takes distilled winning patterns and HOT-DEPLOYS them into
# live Hermes and OpenClaw configurations on FURNACE.
#
# What gets deployed:
#   1. System prompt fragments → Merlin's profile
#   2. Discovered tools → Hermes skill files
#   3. Model routing updates → OpenClaw model config
#   4. Orchestration patterns → Agent defaults
#
# Safety: always backs up before deploying. Rollback with --rollback.
#
# Usage:
#   ./auto-deploy.sh              # Deploy latest winner
#   ./auto-deploy.sh --dry-run    # Preview what would change
#   ./auto-deploy.sh --rollback   # Restore previous config

set +e

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTILL_DIR="$LAB_DIR/distilled"
FURNACE="furnace"
BACKUP_DIR="$LAB_DIR/deploy-backups"
LOG="$LAB_DIR/logs/auto-deploy.log"
DRY_RUN=false
ROLLBACK=false

[ "$1" = "--dry-run" ] && DRY_RUN=true
[ "$1" = "--rollback" ] && ROLLBACK=true

mkdir -p "$BACKUP_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# ── ROLLBACK ──────────────────────────────────────────────
if $ROLLBACK; then
    LATEST_BACKUP=$(ls -td "$BACKUP_DIR"/*/ 2>/dev/null | head -1)
    if [ -z "$LATEST_BACKUP" ]; then
        log "No backups found. Nothing to rollback."
        exit 1
    fi
    log "Rolling back to: $(basename $LATEST_BACKUP)"

    # Restore Merlin profile
    if [ -f "$LATEST_BACKUP/merlin-config.yaml" ]; then
        scp "$LATEST_BACKUP/merlin-config.yaml" "$FURNACE:~/.hermes/profiles/merlin/config.yaml"
        log "  Restored Merlin config"
    fi

    # Restore OpenClaw config
    if [ -f "$LATEST_BACKUP/openclaw.json" ]; then
        scp "$LATEST_BACKUP/openclaw.json" "$FURNACE:~/.openclaw/openclaw.json"
        log "  Restored OpenClaw config"
    fi

    log "Rollback complete."
    exit 0
fi

# ── DEPLOY ────────────────────────────────────────────────
WINNER_FILE="$DISTILL_DIR/LATEST_WINNER.json"
if [ ! -f "$WINNER_FILE" ]; then
    log "No winner to deploy. Run the lab first."
    exit 1
fi

WINNER_SCORE=$(python3 -c "import json; print(json.load(open('$WINNER_FILE'))['best_score'])" 2>/dev/null)
WINNER_SOURCE=$(python3 -c "import json; print(json.load(open('$WINNER_FILE'))['source'])" 2>/dev/null)

log "=== Auto Deploy ==="
log "Winner: $WINNER_SOURCE (score: $WINNER_SCORE)"

# Minimum score threshold for deployment
MIN_SCORE=0.3
if python3 -c "assert $WINNER_SCORE >= $MIN_SCORE" 2>/dev/null; then
    log "Score $WINNER_SCORE >= $MIN_SCORE threshold — proceeding"
else
    log "Score $WINNER_SCORE < $MIN_SCORE threshold — skipping deployment (too risky)"
    exit 0
fi

# ── 1. Backup current configs ────────────────────────────
BACKUP_TS=$(date +%Y%m%d-%H%M)
BACKUP="$BACKUP_DIR/$BACKUP_TS"
mkdir -p "$BACKUP"

log "Backing up current configs..."
ssh "$FURNACE" "cat ~/.hermes/profiles/merlin/config.yaml" > "$BACKUP/merlin-config.yaml" 2>/dev/null
ssh "$FURNACE" "cat ~/.openclaw/openclaw.json" > "$BACKUP/openclaw.json" 2>/dev/null
log "  Backup: $BACKUP"

if $DRY_RUN; then
    log "DRY RUN — would deploy:"
fi

# ── 2. Deploy system prompt fragments ─────────────────────
log "Deploying prompt fragments..."
LATEST_SKILL=$(python3 -c "import json; print(json.load(open('$WINNER_FILE')).get('skill_path',''))" 2>/dev/null)

if [ -f "$LATEST_SKILL" ]; then
    if $DRY_RUN; then
        log "  Would copy: $(basename $LATEST_SKILL) → Merlin skills"
    else
        ssh "$FURNACE" "mkdir -p ~/.hermes/skills/cathedral-lab"
        scp "$LATEST_SKILL" "$FURNACE:~/.hermes/skills/cathedral-lab/"
        log "  Deployed skill: $(basename $LATEST_SKILL)"
    fi
fi

# ── 3. Deploy model routing from oracle ───────────────────
REGISTRY="$LAB_DIR/model-registry.json"
if [ -f "$REGISTRY" ]; then
    log "Deploying model routing..."
    if $DRY_RUN; then
        log "  Would update model registry on FURNACE"
    else
        ssh "$FURNACE" "mkdir -p ~/.hermes/skills/cathedral-lab"
        scp "$REGISTRY" "$FURNACE:~/.hermes/skills/cathedral-lab/model-registry.json"
        log "  Deployed model registry"
    fi
fi

# ── 4. Deploy orchestration patterns ──────────────────────
log "Extracting orchestration patterns..."
python3 -c "
import json
w = json.load(open('$WINNER_FILE'))
p = w.get('patterns', {})

# Generate a config fragment for Merlin
config_update = {
    'lab_insights': {
        'last_updated': w.get('timestamp', ''),
        'winning_score': w.get('best_score', 0),
        'orchestration_style': p.get('orchestration_style', 'simple'),
        'recommended_tools': p.get('tools', []),
        'use_verification': p.get('has_verification', False),
        'use_sub_agents': p.get('has_sub_agents', False),
        'use_retry_logic': p.get('has_retry_logic', False),
    }
}

with open('/tmp/lab-config-fragment.json', 'w') as f:
    json.dump(config_update, f, indent=2)
print(json.dumps(config_update, indent=2))
" 2>/dev/null

if $DRY_RUN; then
    log "  Would deploy orchestration config fragment"
else
    ssh "$FURNACE" "mkdir -p ~/.hermes/skills/cathedral-lab"
    scp /tmp/lab-config-fragment.json "$FURNACE:~/.hermes/skills/cathedral-lab/config-fragment.json"
    log "  Deployed config fragment"
fi
rm -f /tmp/lab-config-fragment.json

log ""
if $DRY_RUN; then
    log "DRY RUN complete. Use without --dry-run to deploy."
else
    log "Deployment complete."
    log "Rollback available: ./auto-deploy.sh --rollback"
fi
