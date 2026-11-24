-- Workflow block: recordInspection (resource: roofing_pg_workflow, role retool_workflow)
-- Idempotent: the same webhook delivered twice records one inspection.
select * from api.record_inspection(
  {{ validate.data.externalId }}, {{ validate.data.jobId }}::bigint, {{ validate.data.inspectedAt }}::timestamptz,
  {{ validate.data.hailHits }}::int, {{ validate.data.wind }}::boolean, {{ validate.data.notes }}
);
