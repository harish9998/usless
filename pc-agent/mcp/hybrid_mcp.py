"""
hybrid_mcp.py - OpenCode MCP bridge for the hybrid workstation (Phase 7).
Exposes ONLY approved read/report operations via stdio MCP. No credentials,
no arbitrary shell, no destructive ops. Calls the repo's PowerShell scripts.

Tools: remote_status, remote_resources, remote_worker_list, remote_list_jobs,
       remote_job_logs, remote_drive_status, remote_schedule
"""

import json, subprocess, sys, os

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(REPO, "scripts")

ALLOWED = {
    "remote_status": ("remote-connect.ps1", ["-Action", "check"]),
    "remote_resources": ("remote-monitor.ps1", []),
    "remote_worker_list": ("remote-jobs.ps1", ["-Action", "list"]),
    "remote_list_jobs": ("remote-jobs.ps1", ["-Action", "list"]),
    "remote_drive_status": ("remote-drive.ps1", ["-Action", "status"]),
}
SCHEDULER = "scheduler.ps1"


def run_ps(script, args):
    path = os.path.join(SCRIPTS, script)
    if not os.path.isfile(path):
        return "ERR: script missing: " + script
    try:
        p = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path]
            + args,
            capture_output=True,
            text=True,
            timeout=90,
        )
        return (p.stdout or "") + (("\nSTDERR:" + p.stderr) if p.stderr else "")
    except Exception as e:
        return "ERR: " + str(e)


TOOLS = [
    {
        "name": n,
        "description": "Hybrid remote workstation: " + n.replace("_", " "),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    }
    for n in ALLOWED
] + [
    {
        "name": "remote_schedule",
        "description": "Conservative local-vs-remote placement decision. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_type": {"type": "string"},
                "input_size_gb": {"type": "number"},
                "local_cpu_pct": {"type": "number"},
                "remote_ram_gb": {"type": "number"},
            },
            "additionalProperties": False,
        },
    }
]


def handle(name, arguments):
    if name not in ALLOWED and name != "remote_schedule":
        return "DENY: tool not in allowlist"
    if name == "remote_schedule":
        a = arguments or {}
        args = [
            "-JobType",
            str(a.get("job_type", "ffmpeg")),
            "-InputSizeGB",
            str(a.get("input_size_gb", 0.5)),
            "-LocalCpuPct",
            str(a.get("local_cpu_pct", 50)),
            "-RemoteRamFreeGB",
            str(a.get("remote_ram_gb", 12)),
        ]
        return run_ps(SCHEDULER, args)
    script, fixed = ALLOWED[name]
    return run_ps(script, fixed)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": "parse error"},
                    }
                ),
                flush=True,
            )
            continue
        mid = msg.get("id")
        method = msg.get("method", "")
        if method == "initialize":
            res = {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "hybrid", "version": "0.1"},
            }
        elif method == "tools/list":
            res = {"tools": TOOLS}
        elif method == "tools/call":
            p = msg.get("params", {})
            name = p.get("name", "")
            res = {
                "content": [{"type": "text", "text": handle(name, p.get("arguments"))}]
            }
        else:
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": mid,
                        "error": {"code": -32601, "message": "method not found"},
                    }
                ),
                flush=True,
            )
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": res}), flush=True)


if __name__ == "__main__":
    main()
