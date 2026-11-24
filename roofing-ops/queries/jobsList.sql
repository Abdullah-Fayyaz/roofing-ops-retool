-- Retool resource query: jobsList (resource: roofing_pg, connected as role retool_app)
-- Every value is a Retool parameter, so Retool sends it as a prepared-statement value, never as SQL text.
-- Access is decided inside api.jobs_list from current_user.email: the UI only filters within what the DB allows.
select *
from api.jobs_list(
  {{ current_user.email }},                          -- plain reference: covered by query-spoofing protection
  {{ statusSelect.value || null }},   -- plain text; validated inside the function
  {{ searchInput.value.trim() || null }},
  {{ jobsTable.pagination?.afterCreated ?? null }}::timestamptz,  -- keyset cursor from last row
  {{ jobsTable.pagination?.afterId ?? null }}::bigint,
  50
);
