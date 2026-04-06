#!/usr/bin/env python3
"""
Cathedral Lab — Harness Distiller

Reads AutoAgent results and winning agent.py harnesses.
Extracts reusable patterns and converts them to Hermes-compatible
skill files and system prompt fragments for Merlin.

Usage:
    python3 distill.py <race-dir-or-agent-workdir>
    python3 distill.py ../  # single agent run in repo root
"""

import json
import os
import re
import sys
from pathlib import Path
from datetime import datetime

DISTILL_DIR = Path(__file__).parent / "distilled"
DISTILL_DIR.mkdir(exist_ok=True)


def parse_results_tsv(path: Path) -> list[dict]:
    """Parse results.tsv into structured records."""
    records = []
    if not path.exists():
        return records
    with open(path) as f:
        header = f.readline().strip().split("\t")
        for line in f:
            vals = line.strip().split("\t")
            if len(vals) >= len(header):
                records.append(dict(zip(header, vals)))
    return records


def extract_harness_patterns(agent_py: Path) -> dict:
    """Extract key patterns from a winning agent.py."""
    if not agent_py.exists():
        return {}

    code = agent_py.read_text()
    patterns = {
        "system_prompt": "",
        "model": "",
        "max_turns": 0,
        "tools": [],
        "tool_count": 0,
        "has_sub_agents": False,
        "has_verification": False,
        "has_retry_logic": False,
        "has_error_handling": False,
        "orchestration_style": "simple",
    }

    # Extract system prompt
    prompt_match = re.search(
        r'SYSTEM_PROMPT\s*=\s*(?:"""(.*?)"""|"(.*?)")',
        code,
        re.DOTALL,
    )
    if prompt_match:
        patterns["system_prompt"] = (prompt_match.group(1) or prompt_match.group(2)).strip()

    # Extract model
    model_match = re.search(r'MODEL\s*=\s*["\'](.+?)["\']', code)
    if model_match:
        patterns["model"] = model_match.group(1)

    # Extract max turns
    turns_match = re.search(r'MAX_TURNS\s*=\s*(\d+)', code)
    if turns_match:
        patterns["max_turns"] = int(turns_match.group(1))

    # Extract tool definitions
    tool_defs = re.findall(r'@function_tool\s*\nasync def (\w+)\(', code)
    patterns["tools"] = tool_defs
    patterns["tool_count"] = len(tool_defs)

    # Detect patterns
    patterns["has_sub_agents"] = "as_tool()" in code or "handoff" in code.lower()
    patterns["has_verification"] = "verif" in code.lower() or "check_result" in code.lower()
    patterns["has_retry_logic"] = "retry" in code.lower() or "attempt" in code.lower()
    patterns["has_error_handling"] = "try:" in code and "except" in code
    
    if patterns["has_sub_agents"]:
        patterns["orchestration_style"] = "multi-agent"
    elif patterns["tool_count"] > 5:
        patterns["orchestration_style"] = "tool-rich"
    elif patterns["has_verification"]:
        patterns["orchestration_style"] = "verify-loop"

    return patterns


def generate_hermes_skill(patterns: dict, score: float, source: str) -> str:
    """Convert winning patterns into a Hermes skill file."""
    tools_list = "\n".join(f"  - {t}" for t in patterns.get("tools", []))
    
    skill = f"""---
name: autoagent-distilled-{datetime.now().strftime('%Y%m%d')}
description: >
  Auto-discovered agent patterns from AutoAgent lab.
  Score: {score} | Source: {source}
  Orchestration: {patterns.get('orchestration_style', 'simple')}
tags:
  - autoagent
  - distilled
  - cathedral-lab
version: 1
---

# AutoAgent Distilled Patterns

**Score:** {score}
**Source:** {source}
**Orchestration Style:** {patterns.get('orchestration_style', 'simple')}
**Tool Count:** {patterns.get('tool_count', 0)}

## System Prompt (winning)

```
{patterns.get('system_prompt', 'N/A')}
```

## Discovered Tools

{tools_list or '  (baseline only — single shell tool)'}

## Key Patterns

- Sub-agents: {'YES' if patterns.get('has_sub_agents') else 'no'}
- Verification loops: {'YES' if patterns.get('has_verification') else 'no'}
- Retry logic: {'YES' if patterns.get('has_retry_logic') else 'no'}
- Error handling: {'YES' if patterns.get('has_error_handling') else 'no'}

## How to Apply

1. Incorporate the system prompt patterns into your agent's instructions
2. Add any discovered tools that are domain-relevant
3. If verification loops were discovered, add output checking before final answers
4. If sub-agents were used, consider task decomposition for complex requests

## Raw Config

```json
{json.dumps(patterns, indent=2, default=str)}
```
"""
    return skill


def distill(workdir: Path):
    """Main distillation from a single workdir."""
    results = parse_results_tsv(workdir / "results.tsv")
    patterns = extract_harness_patterns(workdir / "agent.py")

    if not results and not patterns:
        print(f"  No results or harness found in {workdir}")
        return None

    # Find best score
    best_score = 0.0
    best_record = {}
    for r in results:
        try:
            score = float(r.get("avg_score", 0))
            if score > best_score:
                best_score = score
                best_record = r
        except (ValueError, TypeError):
            continue

    source = workdir.name
    print(f"  Best score: {best_score}")
    print(f"  Tools discovered: {patterns.get('tool_count', 0)}")
    print(f"  Orchestration: {patterns.get('orchestration_style', 'unknown')}")

    # Generate Hermes skill
    skill_content = generate_hermes_skill(patterns, best_score, source)
    skill_path = DISTILL_DIR / f"skill-{source}-{datetime.now().strftime('%Y%m%d-%H%M')}.md"
    skill_path.write_text(skill_content)
    print(f"  Skill written: {skill_path}")

    # Generate summary JSON for sync
    summary = {
        "timestamp": datetime.now().isoformat(),
        "source": source,
        "best_score": best_score,
        "patterns": patterns,
        "results_count": len(results),
        "skill_path": str(skill_path),
    }
    summary_path = DISTILL_DIR / f"summary-{source}-{datetime.now().strftime('%Y%m%d-%H%M')}.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2, default=str)

    return summary


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 distill.py <workdir-or-race-dir>")
        sys.exit(1)

    target = Path(sys.argv[1]).resolve()

    # Check if it's a race dir (has subdirs for each agent)
    agent_dirs = [d for d in target.iterdir() if d.is_dir() and d.name in ("claude", "codex", "hermes", "odin")]

    if agent_dirs:
        print(f"Race directory detected: {target}")
        print(f"Found {len(agent_dirs)} agent runs")
        print()

        all_summaries = []
        for agent_dir in sorted(agent_dirs):
            print(f"--- {agent_dir.name} ---")
            summary = distill(agent_dir)
            if summary:
                all_summaries.append(summary)
            print()

        if all_summaries:
            # Rank by score
            all_summaries.sort(key=lambda s: s["best_score"], reverse=True)
            print("=== RACE RESULTS ===")
            for i, s in enumerate(all_summaries):
                medal = ["🥇", "🥈", "🥉", "  "][min(i, 3)]
                print(f"  {medal} {s['source']}: {s['best_score']:.3f} "
                      f"({s['patterns'].get('orchestration_style', '?')}, "
                      f"{s['patterns'].get('tool_count', 0)} tools)")

            winner = all_summaries[0]
            print(f"\nWinner: {winner['source']} with score {winner['best_score']:.3f}")
            print(f"Skill: {winner['skill_path']}")

            # Write winner marker
            (DISTILL_DIR / "LATEST_WINNER.json").write_text(
                json.dumps(winner, indent=2, default=str)
            )
    else:
        print(f"Single agent run: {target}")
        distill(target)

    print(f"\nDistilled artifacts in: {DISTILL_DIR}")


if __name__ == "__main__":
    main()
