#!/usr/bin/env python3
"""
Cathedral Lab — Model Oracle

Auto-discovers local models (Ollama, MLX), ranks them, and maintains
a live registry that the meta-agent and lab-loop consult. Never suggests
outdated or unavailable models.

Usage:
    python3 model-oracle.py              # Scan and update registry
    python3 model-oracle.py --json       # Output as JSON
    python3 model-oracle.py --benchmark  # Quick speed test all models
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime

REGISTRY_PATH = Path(__file__).parent / "model-registry.json"
BENCHMARK_PATH = Path(__file__).parent / "model-benchmarks.json"

TASK_PROFILES = {
    "coding": {
        "prompt": "Write a Python function that finds the longest common subsequence of two strings. Include type hints and docstring.",
        "prefer_keywords": ["coder", "code", "dev"],
    },
    "reasoning": {
        "prompt": "A farmer has 17 sheep. All but 9 run away. How many are left? Explain your reasoning step by step.",
        "prefer_keywords": ["think", "reason", "opus"],
    },
    "instruction": {
        "prompt": "List exactly 5 steps to set up a Python virtual environment, install Flask, and run a hello world app. Be concise.",
        "prefer_keywords": ["instruct", "chat"],
    },
}


def scan_ollama() -> list[dict]:
    """Scan Ollama for all installed models."""
    try:
        import urllib.request
        resp = urllib.request.urlopen("http://localhost:11434/api/tags", timeout=5)
        data = json.loads(resp.read())
        models = []
        for m in data.get("models", []):
            name = m["name"]
            size_bytes = m.get("size", 0)
            details = m.get("details", {})
            models.append({
                "name": name,
                "runtime": "ollama",
                "size_gb": round(size_bytes / 1e9, 1),
                "family": details.get("family", "unknown"),
                "parameter_size": details.get("parameter_size", "unknown"),
                "quantization": details.get("quantization_level", "unknown"),
                "modified": m.get("modified_at", ""),
                "is_embedding": "embed" in name.lower(),
            })
        return models
    except Exception as e:
        print(f"  Ollama scan failed: {e}")
        return []


def classify_model(model: dict) -> dict:
    """Classify a model's strengths based on name and metadata."""
    name = model["name"].lower()
    strengths = []

    if any(k in name for k in ["coder", "code", "dev"]):
        strengths.append("coding")
    if any(k in name for k in ["think", "reason", "35b", "31b", "26b"]):
        strengths.append("reasoning")
    if any(k in name for k in ["sentinel", "fast", "e2b", "e4b", "mini"]):
        strengths.append("fast")
    if any(k in name for k in ["herald", "chat", "instruct"]):
        strengths.append("instruction")
    if model.get("is_embedding"):
        strengths.append("embedding")

    if not strengths:
        strengths.append("general")

    model["strengths"] = strengths
    return model


def benchmark_model(model_name: str, prompt: str, timeout: int = 60) -> dict:
    """Quick benchmark: measure tokens/sec and response quality."""
    try:
        start = time.time()
        result = subprocess.run(
            ["ollama", "run", model_name, prompt],
            capture_output=True, text=True, timeout=timeout,
        )
        elapsed = time.time() - start
        output = result.stdout.strip()

        # Estimate tokens (rough: ~0.75 tokens per word)
        word_count = len(output.split())
        est_tokens = int(word_count * 1.3)
        tps = est_tokens / elapsed if elapsed > 0 else 0

        return {
            "model": model_name,
            "tokens_per_sec": round(tps, 1),
            "elapsed_sec": round(elapsed, 2),
            "output_words": word_count,
            "est_tokens": est_tokens,
            "success": True,
            "error": None,
        }
    except subprocess.TimeoutExpired:
        return {"model": model_name, "success": False, "error": "timeout"}
    except Exception as e:
        return {"model": model_name, "success": False, "error": str(e)}


def build_registry(models: list[dict], benchmarks: dict = None) -> dict:
    """Build the full model registry with routing recommendations."""
    registry = {
        "updated": datetime.now().isoformat(),
        "node": os.uname().nodename,
        "models": [],
        "routing": {},
    }

    for m in models:
        m = classify_model(m)
        if benchmarks and m["name"] in benchmarks:
            m["benchmark"] = benchmarks[m["name"]]
        registry["models"].append(m)

    # Build routing table: best model per task type
    for task_type in ["coding", "reasoning", "fast", "instruction", "general"]:
        candidates = [m for m in registry["models"]
                      if task_type in m.get("strengths", [])
                      and not m.get("is_embedding")]

        if not candidates:
            candidates = [m for m in registry["models"] if not m.get("is_embedding")]

        # Sort by benchmark speed if available, else by size (smaller = faster)
        if benchmarks:
            candidates.sort(
                key=lambda m: m.get("benchmark", {}).get("tokens_per_sec", 0),
                reverse=True,
            )
        else:
            candidates.sort(key=lambda m: m.get("size_gb", 999))

        if candidates:
            registry["routing"][task_type] = candidates[0]["name"]

    return registry


def main():
    do_json = "--json" in sys.argv
    do_bench = "--benchmark" in sys.argv

    if not do_json:
        print("=== Cathedral Model Oracle ===")
        print(f"Node: {os.uname().nodename}")
        print(f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
        print()

    # Scan
    if not do_json:
        print("Scanning Ollama...")
    models = scan_ollama()

    if not do_json:
        print(f"Found {len(models)} models ({sum(m['size_gb'] for m in models):.0f}GB total)")
        print()

    # Benchmark if requested
    benchmarks = {}
    if do_bench:
        if not do_json:
            print("Benchmarking all models (this takes a few minutes)...")
        bench_results = []
        for m in models:
            if m.get("is_embedding"):
                continue
            if not do_json:
                print(f"  Testing {m['name']}...", end=" ", flush=True)
            result = benchmark_model(m["name"], TASK_PROFILES["coding"]["prompt"])
            if result["success"]:
                if not do_json:
                    print(f"{result['tokens_per_sec']} t/s ({result['elapsed_sec']}s)")
                benchmarks[m["name"]] = result
            else:
                if not do_json:
                    print(f"FAILED: {result['error']}")
            bench_results.append(result)

        # Save benchmarks
        with open(BENCHMARK_PATH, "w") as f:
            json.dump({"timestamp": datetime.now().isoformat(), "results": bench_results}, f, indent=2)
    elif BENCHMARK_PATH.exists():
        # Load previous benchmarks
        with open(BENCHMARK_PATH) as f:
            bench_data = json.load(f)
            for r in bench_data.get("results", []):
                if r.get("success"):
                    benchmarks[r["model"]] = r

    # Build registry
    registry = build_registry(models, benchmarks)

    # Save
    with open(REGISTRY_PATH, "w") as f:
        json.dump(registry, f, indent=2)

    if do_json:
        print(json.dumps(registry, indent=2))
    else:
        print("Model Registry:")
        for m in registry["models"]:
            if m.get("is_embedding"):
                continue
            bench_info = ""
            if m.get("benchmark"):
                bench_info = f" | {m['benchmark']['tokens_per_sec']} t/s"
            print(f"  {m['name']:30s} {m['size_gb']:5.1f}GB  [{', '.join(m['strengths'])}]{bench_info}")

        print()
        print("Routing Table:")
        for task, model in registry.get("routing", {}).items():
            print(f"  {task:15s} → {model}")

        print(f"\nRegistry saved: {REGISTRY_PATH}")


if __name__ == "__main__":
    main()
