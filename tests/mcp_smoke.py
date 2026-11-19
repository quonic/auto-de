#!/usr/bin/env python3
"""MCP smoke test: drive `autode mcp` over stdio like an agent would."""
import base64, json, subprocess, sys

proc = subprocess.Popen(["./build/autode", "mcp", "--size", "1024x768", "--clock", "12:00"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
next_id = 0

def rpc(method, params=None, notify=False):
    global next_id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        next_id += 1
        msg["id"] = next_id
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if notify:
        return None
    resp = json.loads(proc.stdout.readline())
    assert resp.get("id") == next_id, resp
    if "error" in resp:
        raise SystemExit(f"FAIL {method}: {resp['error']}")
    return resp["result"]

def tool(name, **args):
    res = rpc("tools/call", {"name": name, "arguments": args})
    if res.get("isError"):
        raise SystemExit(f"FAIL tool {name}: {res['content'][0]['text']}")
    return res

def text(res):
    return json.loads(res["content"][0]["text"])

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
assert init["serverInfo"]["name"] == "autode" and "tools" in init["capabilities"], init
rpc("notifications/initialized", notify=True)
tools = {t["name"] for t in rpc("tools/list")["tools"]}
for t in ("screenshot", "get_state", "click", "type_text", "press_key", "launch_app", "wait_for_window"):
    assert t in tools, f"missing tool {t}"
print(f"ok: initialize + tools/list ({len(tools)} tools)")

pid = text(tool("launch_app", command="./build/test_client --title 'MCP Window'"))["pid"]
win = text(tool("wait_for_window", title="MCP Window", timeout_ms=5000))
print("ok: launched pid", pid, "window", win["id"], "at", win["x"], win["y"])

tool("click", target=f"window.{win['id']}")
tool("type_text", text="hi")
tool("press_key", combo="ctrl+s")
out = text(tool("app_output", pid=pid))["stdout"]
for expect in ("button 272 pressed", "key 35 pressed", "key 31 pressed"):
    assert expect in out, f"client did not get {expect!r}"
print("ok: click/type/key delivered")

shot = tool("screenshot", scale=0.5)
img = shot["content"][0]
assert img["type"] == "image" and img["mimeType"] == "image/png"
png = base64.b64decode(img["data"])
assert png[:8] == b"\x89PNG\r\n\x1a\n"
meta = shot["content"][1]["text"]
assert '"width":512' in meta.replace(" ", ""), meta
print("ok: screenshot", len(png), "bytes;", meta[:60], "...")

state = text(tool("get_state"))
assert any(e["id"] == "taskbar.start" for e in state["elements"])
err = rpc("tools/call", {"name": "click", "arguments": {"target": "nope"}})
assert err["isError"] and "unknown target" in err["content"][0]["text"]
print("ok: get_state + error reporting")

proc.stdin.close()
proc.wait(timeout=5)
print("mcp smoke test passed")
