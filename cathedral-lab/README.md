# Cathedral Lab — Continuous Harness Evolution

ATHAME is the 24/7 research lab. FURNACE is production.

## How It Works

1. **ATHAME Lab Loop** (runs continuously)
   - AutoAgent meta-agent (Claude/Codex) optimizes task agent harnesses
   - Task agents use LOCAL models (Qwen 3.5, Gemma 4, Odin models)
   - Zero API cost for task agent inference
   - Meta-agent hill-climbs on benchmark scores overnight

2. **Distillation** (runs after each improvement cycle)
   - Extracts winning patterns from agent.py: prompts, tools, orchestration
   - Converts to Hermes-compatible skill files and system prompts
   - Scores and ranks discoveries

3. **Sync to FURNACE** (automatic)
   - Ships distilled skills, prompts, and configs to Merlin
   - Merlin operates with battle-tested patterns
   - Production never runs untested configs

4. **Feedback Loop**
   - Merlin logs failures and edge cases
   - Those become new eval tasks for ATHAME
   - The lab improves on real production failures

## Files

- `lab-loop.sh` — Main 24/7 loop controller
- `distill.py` — Extracts patterns from winning harnesses
- `sync-to-furnace.sh` — Ships distilled configs to Merlin
- `evals/` — Benchmark tasks (Harbor format)
