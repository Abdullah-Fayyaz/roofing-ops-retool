-- Used by the Retool Workflow "inspectionWebhook". Separate DB role, separate privileges.
CREATE OR REPLACE FUNCTION api.record_inspection(p_external_id text, p_job_id bigint, p_inspected_at timestamptz,
                                                 p_hail_hits int, p_wind boolean, p_notes text)
RETURNS TABLE (inspection_id bigint, created boolean, job_status core.job_status)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE v_id bigint; v_new boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jobs WHERE id = p_job_id) THEN
    RAISE EXCEPTION 'unknown job %', p_job_id USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO inspections(job_id, external_id, inspected_at, hail_hits, wind_damage, notes)
  VALUES (p_job_id, p_external_id, p_inspected_at, p_hail_hits, p_wind, p_notes)
  ON CONFLICT (external_id) DO NOTHING
  RETURNING id INTO v_id;
  v_new := v_id IS NOT NULL;
  IF NOT v_new THEN SELECT id INTO v_id FROM inspections WHERE external_id = p_external_id; END IF;
  IF v_new THEN
    UPDATE jobs SET status = 'inspected', updated_at = now() WHERE id = p_job_id AND status = 'lead';
    INSERT INTO audit_log(actor, action, job_id, detail)
    VALUES ('workflow:inspectionWebhook', 'inspection.recorded', p_job_id, jsonb_build_object('external_id', p_external_id));
  END IF;
  RETURN QUERY SELECT v_id, v_new, (SELECT status FROM jobs WHERE id = p_job_id);
END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='retool_workflow') THEN CREATE ROLE retool_workflow LOGIN PASSWORD 'change-me'; END IF; END $$;
GRANT USAGE ON SCHEMA api TO retool_workflow;
GRANT EXECUTE ON FUNCTION api.record_inspection TO retool_workflow;
