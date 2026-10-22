#!/usr/bin/env python3
"""Optional integration client: official mcp 1.26.0; invoked by MCPSDKPresentationTests.
Only the supplied fixture socket is used. No user configuration or live app data is touched.
"""
import asyncio
import hashlib
import json
import os
import socket
import sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

phase, bridge, socket_path, *options = sys.argv[1:]
project = options[0] if options else "p"
request = dict(projectID=project, idempotencyKey="sdk-ui", title="MCP 화면 연결 확인",
               criteria=["같은 이슈와 버전이 화면에 표시된다", "기록을 보존하고 닫힌다"],
               instruction="처음 저장한 실행 제안", handoffSummary="외부 요청으로 만든 문맥")

def identity(key):
    return "mcp-" + hashlib.sha256((project + "\0" + key).encode()).hexdigest()[:24]

async def run():
    env = dict(os.environ, KNARR_MCP_SOCKET=socket_path)
    async with stdio_client(StdioServerParameters(command=bridge, args=[], env=env)) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert {t.name for t in tools.tools} == {"list_projects", "list_issues", "get_issue", "create_issue", "update_issue_proposal", "close_issue"}
            async def call(name, args, error=None):
                deadline = asyncio.get_running_loop().time() + 20
                while True:
                    value = await session.call_tool(name, args)
                    data = value.structuredContent
                    if not (value.isError and isinstance(data, dict) and data.get("error", {}).get("code") == "unavailable"
                            and asyncio.get_running_loop().time() < deadline): break
                    await asyncio.sleep(.2)
                assert isinstance(data, dict), value
                if error:
                    assert value.isError and data["error"]["code"] == error, value
                else:
                    assert not value.isError, value
                return data
            iid = identity("sdk-ui")
            target = dict(projectID=project, issueID=iid)
            if phase == "create":
                created = await call("create_issue", request)
                assert created["issueID"] == iid and created["duplicate"] is False
                assert (await call("create_issue", request))["duplicate"] is True
                await call("create_issue", dict(request, handoffSummary="바뀐 문맥"), "conflict")
                await call("create_issue", dict(request, criteria=request["criteria"][:1]), "conflict")
                assert (await call("get_issue", target))["proposal"]["version"] == 1
            elif phase == "update":
                update = dict(target, expectedVersion=1, instruction="수정한 실행 제안")
                assert (await call("update_issue_proposal", update))["version"] == 2
                assert (await call("update_issue_proposal", update))["duplicate"] is True
                await call("update_issue_proposal", dict(update, instruction="다른 오래된 제안"), "conflict")
                assert (await call("get_issue", target))["proposal"]["version"] == 2
            elif phase == "close":
                close = dict(target, expectedVersion=2, reason="cancelled", note="검증 후 기록 보관")
                await call("close_issue", dict(close, expectedVersion=1), "conflict")
                await call("close_issue", close)
                assert (await call("close_issue", close))["duplicate"] is True
                assert iid not in {x["issueID"] for x in (await call("list_issues", {"projectID":project}))["issues"]}
                assert iid in {x["issueID"] for x in (await call("list_issues", {"projectID":project, "includeArchived":True}))["issues"]}
                saved = await call("get_issue", target)
                assert saved["archived"]["note"] == close["note"] and saved["proposal"]["version"] == 2
            elif phase == "lost":
                lost = dict(request, idempotencyKey="sdk-lost", title="응답 유실 복구 확인")
                def drop_reply():
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                        client.connect(socket_path)
                        client.sendall((json.dumps(dict(jsonrpc="2.0", id=1, method="initialize", params={"protocolVersion":"2025-06-18"}))+"\n").encode())
                        assert client.recv(65536)
                        client.sendall((json.dumps(dict(jsonrpc="2.0", id=2, method="tools/call", params={"name":"create_issue", "arguments":lost}))+"\n").encode())
                await asyncio.to_thread(drop_reply)
                # Wait until the discarded response's transaction committed, through read-only API.
                for _ in range(100):
                    rows = (await call("list_issues", {"projectID":project}))["issues"]
                    if any(x["issueID"] == identity("sdk-lost") for x in rows): break
                    await asyncio.sleep(.02)
                else: raise AssertionError("lost request never committed")
                assert (await call("create_issue", lost))["duplicate"] is True
            elif phase == "reopen":
                saved = await call("create_issue", request)
                assert saved["issueID"] == iid and saved["version"] == 2 and saved["duplicate"] is True
                assert (await call("get_issue", target))["archived"]["note"] == "검증 후 기록 보관"
                lost = dict(request, idempotencyKey="sdk-lost", title="응답 유실 복구 확인")
                assert (await call("create_issue", lost))["duplicate"] is True
            else: raise AssertionError(phase)
            print(json.dumps({"phase":phase, "passed":True, "issueID":iid}, ensure_ascii=False))

asyncio.run(asyncio.wait_for(run(), timeout=30))
