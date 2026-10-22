#!/usr/bin/env python3
"""Metadata-only OMP 18.7.0 smoke; fresh profile, no credentials, no model turn."""
import hashlib
import json
import os
import pathlib
import selectors
import subprocess
import sys
import tempfile

assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == "1715813a16ad2925a915ef4f8a55a5b82b61759ebcb3768295e8ab26d549d834", "OMP 18.7.0 arm64 checksum mismatch"

with tempfile.TemporaryDirectory(prefix="knarr-high-smoke-") as directory:
    root = pathlib.Path(directory)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": directory,
           "PI_CODING_AGENT_DIR": str(root / "agent"), "XDG_CONFIG_HOME": str(root / "config"),
           "PI_CONFIG_DIR": str(root / "config"), "TERM": "dumb"}
    config = root / "runtime.yml"
    config.write_text("disabledProviders: [native, native-managed-skills, agent-plugins, agents, agents-md, claude, claude-md, claude-plugins, cline, codex, cursor, gemini, github, mcp-json, omp-plugins, opencode, skillshare, ssh, vscode, windsurf]\nretry:\n  modelFallback: false\n  usageAwareFallback: false\n")
    process = subprocess.Popen([sys.argv[1], "--mode", "rpc", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-pty", "--no-title", "--no-ui", "--thinking", "high", "--config", str(config)], cwd=directory, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b""
    def receive():
        global buffer
        while b"\n" not in buffer:
            if not selector.select(30):
                raise RuntimeError("OMP response timeout")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("OMP exited before response")
            buffer += chunk
        line, buffer = buffer.split(b"\n", 1)
        return json.loads(line)
    sequence = 0
    def request(command, **fields):
        global sequence
        sequence += 1
        identity = str(sequence)
        process.stdin.write((json.dumps(dict(type=command, id=identity, **fields)) + "\n").encode())
        process.stdin.flush()
        while True:
            frame = receive()
            if frame.get("type") == "response" and frame.get("id") == identity:
                if not frame.get("success"):
                    raise RuntimeError("RPC rejected " + command)
                return frame.get("data", {})
    try:
        while receive().get("type") != "ready":
            pass
        if len(sys.argv) > 2:
            provider, model_id = sys.argv[2].split("/", 1)
            request("set_model", provider=provider, modelId=model_id)
        levels = request("get_available_thinking_levels")["levels"]
        assert "high" in levels, levels
        request("set_thinking_level", level="high")
        state = request("get_state")
        assert state["thinkingLevel"] in ("high", "xhigh", "max"), state["thinkingLevel"]
        model = state.get("model") or {}
        print(json.dumps({"version": "18.7.0", "provider": model.get("provider"), "model": model.get("id"), "thinkingLevel": state["thinkingLevel"], "supportedLevels": levels, "profile": "temporary-empty", "modelPrompt": False}, ensure_ascii=False))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)
        selector.close()
        print("owned_process_exit=" + str(process.returncode))
