"""
MCP server: lets an AI agent (Retool Agents, Claude, Cursor) answer questions about jobs
with exactly the same row rules as the Retool app.

The agent never gets SQL access. It gets three tools, and every tool calls the api.* functions
as the signed-in user's email, so an estimator's agent can't see another region either.

Run:  ROOFING_DSN="host=... dbname=roofing user=retool_app" python agent/server.py
The caller's email comes from the authenticated session (here: the MCP_USER_EMAIL env var,
set by the host that authenticated the user). It is never taken from the model's own arguments.
"""
import os, psycopg
from mcp.server.mcpserver import MCPServer

DSN = os.environ.get("ROOFING_DSN", "host=/tmp/pg port=5433 dbname=roofing user=retool_app")
mcp = MCPServer("roofing-ops")

def _viewer() -> str:
    email = os.environ.get("MCP_USER_EMAIL", "").strip().lower()
    if not email:
        raise PermissionError("no authenticated user for this session")
    return email

def _rows(sql, *args):
    with psycopg.connect(DSN) as c:
        cur = c.execute(sql, args)
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

@mcp.tool()
def find_jobs(status: str | None = None, search: str | None = None, limit: int = 20) -> list[dict]:
    """Find roofing jobs the current user is allowed to see. status: lead, inspected, estimated, sold,
    scheduled, in_progress, complete, lost. search matches customer name or address."""
    rows = _rows("select id, status, region, crew, customer, address, roof_type, squares, contract_usd, insurance_job "
                 "from api.jobs_list(%s, %s, %s, null, null, %s)", _viewer(), status, search, min(limit, 50))
    for r in rows:
        r["status"] = str(r["status"]); r["squares"] = float(r["squares"] or 0)
        r["contract_usd"] = None if r["contract_usd"] is None else float(r["contract_usd"])
    return rows

@mcp.tool()
def pipeline(since: str = "2026-01-01") -> list[dict]:
    """Leads, sold jobs, close rate and sold value per region, for regions the user can see."""
    rows = _rows("select * from api.pipeline_by_region(%s, %s::date)", _viewer(), since)
    return [{k: (float(v) if hasattr(v, "as_tuple") else v) for k, v in r.items()} for r in rows]

@mcp.tool()
def claim_status(job_id: int) -> dict:
    """Insurance claim details for one job. Claim and policy numbers are restricted by role; each read is audited."""
    rows = _rows("select * from api.claim_detail(%s, %s)", _viewer(), job_id)
    if not rows:
        return {"found": False, "message": "No claim you can see for that job."}
    r = rows[0]; r["storm_date"] = str(r["storm_date"]); r["found"] = True
    return r

if __name__ == "__main__":
    mcp.run()
