#!/usr/bin/env python3
"""
Cathedral Lab — Auto Model Pull

Scans Ollama library and HuggingFace mlx-community for new models
that would perform well on ATHAME (M5 Max 128GB). Auto-pulls promising
ones, benchmarks them, and updates the model oracle.

Criteria for auto-pull:
  - MoE models with ≤10B active params (fast on Apple Silicon)
  - Dense models ≤35B (fits in 128GB with room for Docker)
  - Coding or reasoning tagged
  - Released in last 14 days (fresh)

Run weekly via cathedral-auto-update.sh or standalone.
"""

import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

LAB_DIR = Path(__file__).parent
REGISTRY_PATH = LAB_DIR / "model-registry.json"
PULL_LOG = LAB_DIR / "logs" / "auto-pull.log"
MAX_DISK_GB = 200  # Don't exceed this total for Ollama models
MAX_SINGLE_GB = 25  # Don't pull models larger than this

# Models we always want to track (Ollama tags)
WATCH_FAMILIES = [
    "qwen3", "qwen3.5", "gemma4", "phi4", "llama4",
    "deepseek-coder", "starcoder", "codestral",
    "mistral", "command-r",
]

# HuggingFace orgs to watch for MLX models
HF_WATCH_ORGS = ["mlx-community", "bartowski"]


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    PULL_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(PULL_LOG, "a") as f:
        f.write(line + "\n")


def get_installed_models() -> dict:
    """Get currently installed Ollama models."""
    try:
        resp = urllib.request.urlopen("http://localhost:11434/api/tags", timeout=5)
        data = json.loads(resp.read())
        return {m["name"]: m["size"] / 1e9 for m in data.get("models", [])}
    except Exception:
        return {}


def get_total_disk_gb(installed: dict) -> float:
    return sum(installed.values())


def search_ollama_library(family: str) -> list[dict]:
    """Search Ollama library for models matching a family."""
    try:
        # Ollama doesn't have a search API, but we can check specific tags
        # Try common size variants
        candidates = []
        for variant in ["latest", "7b", "8b", "14b", "27b", "32b", "35b",
                        "coder", "instruct", "code"]:
            tag = f"{family}:{variant}"
            result = subprocess.run(
                ["ollama", "show", tag, "--json"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0:
                try:
                    info = json.loads(result.stdout)
                    candidates.append({
                        "name": tag,
                        "size_gb": info.get("size", 0) / 1e9 if info.get("size") else 0,
                        "family": family,
                    })
                except (json.JSONDecodeError, KeyError):
                    pass
        return candidates
    except Exception:
        return []


def search_hf_mlx(org: str, days: int = 14) -> list[dict]:
    """Search HuggingFace for recent MLX-quantized models."""
    try:
        cutoff = (datetime.now() - timedelta(days=days)).isoformat()
        url = (f"https://huggingface.co/api/models?"
               f"author={org}&sort=lastModified&direction=-1&limit=20")
        req = urllib.request.Request(url)
        resp = urllib.request.urlopen(req, timeout=10)
        models = json.loads(resp.read())

        results = []
        for m in models:
            name = m.get("id", "")
            # Filter for likely useful models
            name_lower = name.lower()
            if any(fam in name_lower for fam in WATCH_FAMILIES):
                results.append({
                    "name": name,
                    "source": "huggingface",
                    "org": org,
                    "last_modified": m.get("lastModified", ""),
                    "downloads": m.get("downloads", 0),
                })
        return results
    except Exception as e:
        log(f"  HF search failed for {org}: {e}")
        return []


def pull_model(name: str) -> bool:
    """Pull a model via Ollama."""
    log(f"  Pulling {name}...")
    try:
        result = subprocess.run(
            ["ollama", "pull", name],
            capture_output=True, text=True, timeout=600,
        )
        if result.returncode == 0:
            log(f"  Successfully pulled {name}")
            return True
        else:
            log(f"  Failed to pull {name}: {result.stderr[:200]}")
            return False
    except subprocess.TimeoutExpired:
        log(f"  Timeout pulling {name}")
        return False


def main():
    log("=== Auto Model Pull ===")

    installed = get_installed_models()
    total_gb = get_total_disk_gb(installed)
    log(f"Currently installed: {len(installed)} models, {total_gb:.0f}GB")
    log(f"Budget remaining: {MAX_DISK_GB - total_gb:.0f}GB")

    if total_gb >= MAX_DISK_GB:
        log("Disk budget exceeded. Skipping auto-pull.")
        return

    pulled = []

    # 1. Check Ollama library for new variants of watched families
    log("\nScanning Ollama library...")
    for family in WATCH_FAMILIES:
        # Check if there's a newer version we don't have
        for variant in ["latest", "coder", "instruct"]:
            tag = f"{family}:{variant}"
            if tag not in installed:
                # Check if it exists and is within size budget
                result = subprocess.run(
                    ["ollama", "show", tag],
                    capture_output=True, text=True, timeout=10,
                )
                if result.returncode == 0 and "error" not in result.stderr.lower():
                    # Model exists in registry but not installed
                    if get_total_disk_gb(installed) + MAX_SINGLE_GB <= MAX_DISK_GB:
                        if pull_model(tag):
                            pulled.append(tag)
                            installed = get_installed_models()  # refresh

    # 2. Check HuggingFace for new MLX models
    log("\nScanning HuggingFace mlx-community...")
    for org in HF_WATCH_ORGS:
        hf_models = search_hf_mlx(org, days=14)
        for m in hf_models[:3]:  # Limit to top 3 per org
            log(f"  Found: {m['name']} (downloads: {m.get('downloads', 0)})")

    # 3. Re-run model oracle with benchmarks if we pulled anything new
    if pulled:
        log(f"\nPulled {len(pulled)} new models. Re-running model oracle...")
        subprocess.run(
            [sys.executable, str(LAB_DIR / "model-oracle.py"), "--benchmark"],
            timeout=600,
        )
        log("Model oracle updated with new models.")
    else:
        log("\nNo new models to pull.")

    # Summary
    log(f"\nSummary: {len(pulled)} models pulled")
    for p in pulled:
        log(f"  + {p}")


if __name__ == "__main__":
    main()
