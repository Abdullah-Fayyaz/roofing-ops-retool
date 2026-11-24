"""Runs against a real PostgreSQL 16, connected as the same role Retool uses (retool_app)."""
import os, time, psycopg, pytest
DSN = os.environ.get("RT_DSN", "host=/tmp/pg port=5433 dbname=roofing user=retool_app")
ADMIN = os.environ.get("RT_ADMIN_DSN", "host=/tmp/pg port=5433 dbname=roofing user=postgres")

@pytest.fixture(scope="module")
def db():
    with psycopg.connect(DSN, autocommit=True) as c: yield c

def q(db, sql, *a):
    return db.execute(sql, a).fetchall()

def jobs(db, who, **kw):
    return q(db, "select * from api.jobs_list(%s, %s, %s, %s, %s, %s)", who, kw.get("status"), kw.get("search"),
             kw.get("after_created"), kw.get("after_id"), kw.get("limit", 200))

def test_retool_role_cannot_read_tables_directly(db):
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        q(db, "select * from core.claims limit 1")

def test_unknown_and_inactive_users_see_nothing(db):
    assert jobs(db, "stranger@evil.test") == []
    assert jobs(db, "former@roofco.test") == []

def test_ops_manager_sees_only_own_region(db):
    rows = jobs(db, "ops.north@roofco.test")
    assert rows and {r[2] for r in rows} == {"North Dallas"}

def test_crew_lead_sees_only_own_crew_scheduled_work_and_no_prices(db):
    rows = jobs(db, "lead.a@roofco.test")
    assert rows and {r[3] for r in rows} == {"Crew A"}
    assert {r[1] for r in rows} <= {"scheduled", "in_progress", "complete"}
    assert all(r[9] is None for r in rows)                 # contract value hidden
    assert all(r[5].startswith("***-***-") for r in rows)   # phone masked

def test_claims_role_sees_only_insurance_jobs(db):
    rows = jobs(db, "claims@roofco.test")
    assert rows and all(r[10] for r in rows)

def test_email_is_case_insensitive(db):
    assert jobs(db, "OPS.North@RoofCo.test", limit=5) == jobs(db, "ops.north@roofco.test", limit=5)

def test_injection_in_search_is_just_text(db):
    assert jobs(db, "owner@roofco.test", search="x' or '1'='1") == []

def test_keyset_pagination_has_no_gaps_or_duplicates(db):
    seen, after = [], (None, None)
    while True:
        page = jobs(db, "owner@roofco.test", after_created=after[0], after_id=after[1], limit=97)
        if not page: break
        seen += [r[0] for r in page]; after = (page[-1][11], page[-1][0])
    assert len(seen) == len(set(seen)) == 1200

def test_page_size_is_capped(db):
    assert len(jobs(db, "owner@roofco.test", limit=10000)) == 200

def test_claim_numbers_restricted_and_reads_audited(db):
    job = q(db, "select id from api.jobs_list('ops.north@roofco.test', null, null, null, null, 200) where insurance_job limit 1")[0][0]
    ops = q(db, "select claim_number, policy_number from api.claim_detail(%s, %s)", "ops.north@roofco.test", job)[0]
    full = q(db, "select claim_number from api.claim_detail(%s, %s)", "claims@roofco.test", job)[0]
    assert ops == ("restricted", "restricted") and full[0].startswith("CLM-")
    with psycopg.connect(ADMIN) as a:
        n = a.execute("select count(*) from core.audit_log where action='claim_detail.read' and job_id=%s", (job,)).fetchone()[0]
    assert n >= 2

def test_other_region_claim_returns_nothing(db):
    job = q(db, "select id from api.jobs_list('ops.fw@roofco.test', null, null, null, null, 200) where insurance_job limit 1")[0][0]
    assert q(db, "select * from api.claim_detail(%s, %s)", "ops.north@roofco.test", job) == []

def test_hidden_job_update_looks_like_not_found(db):
    job = jobs(db, "ops.fw@roofco.test", limit=1)[0][0]
    with pytest.raises(psycopg.errors.NoDataFound):
        q(db, "select api.set_job_status(%s, %s, 'lost')", "ops.north@roofco.test", job)

def test_crew_lead_cannot_mark_a_job_sold(db):
    job = jobs(db, "lead.a@roofco.test", status="scheduled", limit=1)[0][0]
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        q(db, "select api.set_job_status(%s, %s, 'sold')", "lead.a@roofco.test", job)

def test_status_change_is_audited(db):
    job = jobs(db, "lead.a@roofco.test", status="scheduled", limit=1)[0][0]
    assert q(db, "select api.set_job_status(%s, %s, 'in_progress')", "lead.a@roofco.test", job)[0][0] == "in_progress"
    with psycopg.connect(ADMIN) as a:
        d = a.execute("select detail from core.audit_log where action='job.status' and job_id=%s order by id desc limit 1", (job,)).fetchone()[0]
    assert d == {"from": "scheduled", "to": "in_progress"}

def test_bad_status_is_a_clear_error(db):
    job = jobs(db, "owner@roofco.test", limit=1)[0][0]
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="unknown status"):
        q(db, "select api.set_job_status(%s, %s, 'done')", "owner@roofco.test", job)

def test_kpis_respect_row_rules(db):
    north = q(db, "select region from api.pipeline_by_region('ops.north@roofco.test', '2026-01-01')")
    assert [r[0] for r in north] == ["North Dallas"]
    assert q(db, "select * from api.pipeline_by_region('lead.a@roofco.test')") == []

def test_list_query_is_fast_on_1200_jobs(db):
    t = time.perf_counter()
    for _ in range(20): jobs(db, "ops.north@roofco.test", limit=50)
    assert (time.perf_counter() - t) / 20 < 0.05
