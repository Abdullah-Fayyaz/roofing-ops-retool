import os, importlib, sys
sys.path.insert(0, os.path.dirname(__file__))
import pytest

def load(email):
    if email is None: os.environ.pop("MCP_USER_EMAIL", None)
    else: os.environ["MCP_USER_EMAIL"] = email
    import server; return importlib.reload(server)

def test_agent_inherits_region_rule():
    s = load("ops.north@roofco.test")
    assert {j["region"] for j in s.find_jobs(limit=50)} == {"North Dallas"}

def test_agent_cannot_widen_access_through_arguments():
    s = load("lead.a@roofco.test")
    rows = s.find_jobs(search="%", limit=50)
    assert rows and {j["crew"] for j in rows} == {"Crew A"} and all(j["contract_usd"] is None for j in rows)

def test_agent_without_a_session_gets_nothing():
    s = load(None)
    with pytest.raises(PermissionError): s.find_jobs()

def test_claim_numbers_restricted_for_agent_too():
    s = load("ops.north@roofco.test")
    job = next(j["id"] for j in s.find_jobs(limit=50) if j["insurance_job"])
    assert s.claim_status(job)["claim_number"] == "restricted"
    s = load("claims@roofco.test")
    assert s.claim_status(job)["claim_number"].startswith("CLM-")

def test_pipeline_tool_returns_plain_numbers():
    s = load("owner@roofco.test")
    rows = s.pipeline()
    assert len(rows) == 3 and isinstance(rows[0]["sold_usd"], float)

def test_tools_are_registered():
    import asyncio
    s = load("owner@roofco.test")
    names = {t.name for t in asyncio.run(s.mcp.list_tools())}
    assert names == {"find_jobs", "pipeline", "claim_status"}
