-- Access control lives here, in the database, not in the Retool UI.
-- Retool passes {{ current_user.email }} as a plain parameter (covered by Retool's
-- query-spoofing protection). Role, region and crew are looked up from core.app_users.

CREATE OR REPLACE FUNCTION api._viewer(p_email text)
RETURNS core.app_users LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT u.* FROM core.app_users u WHERE u.email = lower(p_email) AND u.active
$$;

-- Row rule in one place: who can see which job.
CREATE OR REPLACE FUNCTION api._can_see(v core.app_users, j core.jobs)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE v.role
    WHEN 'admin'       THEN true
    WHEN 'claims'      THEN j.insurance_job
    WHEN 'ops_manager' THEN j.region_id = v.region_id
    WHEN 'estimator'   THEN j.region_id = v.region_id AND (j.estimator = v.email OR j.status = 'lead')
    WHEN 'crew_lead'   THEN j.crew_id = v.crew_id AND j.status IN ('scheduled', 'in_progress', 'complete')
    ELSE false END
$$;

-- Jobs list: parameterised filters, keyset pagination, PII masked by role.
-- api._can_see stays the single source of truth. On top of it we add a "scope" predicate the planner
-- can match to an index (region, crew or insurance). Dynamic SQL gives each role its own plan;
-- every value still goes in through USING, never into the SQL text.
CREATE OR REPLACE FUNCTION api.jobs_list(
  p_viewer text, p_status text DEFAULT NULL, p_search text DEFAULT NULL,
  p_after_created timestamptz DEFAULT NULL, p_after_id bigint DEFAULT NULL, p_limit int DEFAULT 50)
RETURNS TABLE (id bigint, status text, region text, crew text, customer text, phone text,
               address text, roof_type text, squares numeric, contract_usd numeric, insurance_job boolean,
               created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE v core.app_users; scope text;
BEGIN
  v := api._viewer(p_viewer);
  IF v.email IS NULL THEN RETURN; END IF;                       -- unknown or inactive user: no rows
  scope := CASE v.role
    WHEN 'admin'       THEN 'true'
    WHEN 'claims'      THEN 'j.insurance_job'
    WHEN 'ops_manager' THEN 'j.region_id = $2'
    WHEN 'estimator'   THEN 'j.region_id = $2'
    WHEN 'crew_lead'   THEN 'j.crew_id = $3'
    ELSE 'false' END;
  RETURN QUERY EXECUTE format($q$
    SELECT j.id, j.status::text, r.name, c.name, cu.full_name,
           CASE WHEN ($1).role IN ('admin', 'ops_manager', 'estimator') THEN cu.phone
                ELSE '***-***-' || right(cu.phone, 4) END,
           cu.address, j.roof_type, j.squares,
           CASE WHEN ($1).role = 'crew_lead' THEN NULL ELSE j.contract_usd END,
           j.insurance_job, j.created_at
    FROM jobs j
    JOIN regions r    ON r.id = j.region_id
    JOIN customers cu ON cu.id = j.customer_id
    LEFT JOIN crews c ON c.id = j.crew_id
    WHERE %s
      AND api._can_see($1, j)
      AND ($4::text IS NULL OR j.status = $4::core.job_status)
      AND ($5::text IS NULL OR cu.full_name ILIKE '%%' || $5 || '%%' OR cu.address ILIKE '%%' || $5 || '%%')
      AND ($6::timestamptz IS NULL OR (j.created_at, j.id) < ($6, $7))
    ORDER BY j.created_at DESC, j.id DESC
    LIMIT $8 $q$, scope)
  USING v, v.region_id, v.crew_id, p_status, p_search, p_after_created, p_after_id, least(greatest(p_limit, 1), 200);
END $$;

-- Claim details: regulated fields only for admin and claims, and every read is audited.
CREATE OR REPLACE FUNCTION api.claim_detail(p_viewer text, p_job_id bigint)
RETURNS TABLE (job_id bigint, carrier text, claim_number text, policy_number text, adjuster text, storm_date date)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE v core.app_users; j core.jobs;
BEGIN
  v := api._viewer(p_viewer);
  SELECT * INTO j FROM jobs WHERE jobs.id = p_job_id;
  IF v.email IS NULL OR j.id IS NULL OR NOT api._can_see(v, j) THEN RETURN; END IF;
  INSERT INTO audit_log(actor, action, job_id) VALUES (v.email, 'claim_detail.read', p_job_id);
  RETURN QUERY
  SELECT c.job_id, c.carrier,
         CASE WHEN v.role IN ('admin', 'claims') THEN c.claim_number ELSE 'restricted' END,
         CASE WHEN v.role IN ('admin', 'claims') THEN c.policy_number ELSE 'restricted' END,
         c.adjuster, c.storm_date
  FROM claims c WHERE c.job_id = p_job_id;
END $$;

-- Pipeline KPIs per region: aggregates respect the same row rule.
CREATE OR REPLACE FUNCTION api.pipeline_by_region(p_viewer text, p_since date DEFAULT current_date - 90)
RETURNS TABLE (region text, leads bigint, sold bigint, close_rate numeric, sold_usd numeric, avg_squares numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE v core.app_users;
BEGIN
  v := api._viewer(p_viewer);
  IF v.email IS NULL OR v.role = 'crew_lead' THEN RETURN; END IF;
  RETURN QUERY
  SELECT r.name,
         count(*),
         count(*) FILTER (WHERE j.status IN ('sold', 'scheduled', 'in_progress', 'complete')),
         round(count(*) FILTER (WHERE j.status IN ('sold', 'scheduled', 'in_progress', 'complete'))::numeric
               / nullif(count(*) FILTER (WHERE j.status <> 'lead'), 0), 3),
         coalesce(sum(j.contract_usd) FILTER (WHERE j.status IN ('sold', 'scheduled', 'in_progress', 'complete')), 0),
         round(avg(j.squares), 1)
  FROM jobs j JOIN regions r ON r.id = j.region_id
  WHERE j.created_at >= p_since AND api._can_see(v, j)
  GROUP BY r.name ORDER BY 5 DESC;
END $$;

-- Status change: write path checks the same rule, validates the transition, and audits.
CREATE OR REPLACE FUNCTION api.set_job_status(p_viewer text, p_job_id bigint, p_status_text text)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE v core.app_users; j core.jobs; p_status core.job_status;
BEGIN
  BEGIN p_status := p_status_text::core.job_status;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'unknown status %', p_status_text USING ERRCODE = '22023'; END;
  v := api._viewer(p_viewer);
  SELECT * INTO j FROM jobs WHERE jobs.id = p_job_id FOR UPDATE;
  IF v.email IS NULL OR j.id IS NULL OR NOT api._can_see(v, j) THEN
    RAISE EXCEPTION 'not found' USING ERRCODE = 'P0002';         -- same answer whether hidden or missing
  END IF;
  IF v.role = 'crew_lead' AND p_status NOT IN ('in_progress', 'complete') THEN
    RAISE EXCEPTION 'crew leads can only start or complete jobs' USING ERRCODE = '42501';
  END IF;
  UPDATE jobs SET status = p_status, updated_at = now() WHERE id = p_job_id;
  INSERT INTO audit_log(actor, action, job_id, detail)
  VALUES (v.email, 'job.status', p_job_id, jsonb_build_object('from', j.status, 'to', p_status));
  RETURN p_status::text;
END $$;

-- Least privilege for the Retool resource
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'retool_app') THEN
    CREATE ROLE retool_app LOGIN PASSWORD 'change-me';
  END IF;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA core FROM retool_app;
REVOKE ALL ON SCHEMA core FROM retool_app;
GRANT USAGE ON SCHEMA api TO retool_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.jobs_list, api.claim_detail, api.pipeline_by_region, api.set_job_status TO retool_app;
