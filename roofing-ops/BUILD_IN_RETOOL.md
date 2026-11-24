# Building the Retool side (about 2 hours)

1. Run the four SQL files on a Postgres you control (Supabase or Neon free tier works).
2. Retool > Resources > PostgreSQL `roofing_pg`, user `retool_app`. A second one, `roofing_pg_workflow`, user `retool_workflow`.
3. App `Roofing Ops` (React-based app builder):
   - Header: status Select `statusSelect`, Text input `searchInput`, Date `sinceDate`.
   - KPI row: 3 Statistic components from `pipelineByRegion`; bar chart of sold USD by region.
   - Table `jobsTable` from `jobsList`, server-side pagination using the last row's created_at and id.
   - Drawer on row select: job details, `claimDetail` result, status Select `newStatus` and a Save button (`setJobStatus`, on success `jobsList.trigger()`).
   - Paste the four files from `queries/`. Leave "Prevent query variable spoofing" on.
4. Workflow `inspectionWebhook`: Webhook trigger > JS `verifySignature` > JS `validate` > SQL `recordInspection` > Branch `suggestsClaim` > REST `notifyEstimator` (retries on) ; Error handler block uses `errorReport`.
5. Test as three users: `ops.north@`, `lead.a@`, `claims@`. Use Retool's "View as" or three test accounts.

# Loom script (3-4 minutes, show the builder)
1. 0:00 Open the app as ops.north. "Only North Dallas. That's not a filter in the UI."
2. 0:30 Open `jobsList` in the query editor. Point at `{{ current_user.email }}` and the function call. Show the resource is `retool_app`.
3. 1:00 Switch to SQL: `api._can_see`, one rule for everything. Show the role table in the README.
4. 1:40 Switch user to lead.a: phones masked, prices empty, only Crew A. Try Save with "sold": the DB error appears in the toast.
5. 2:20 Open the workflow canvas: signature, validate, idempotent insert, retries, error handler. Replay the same webhook: no duplicate.
6. 3:00 Terminal: `pytest` and `node workflow/blocks.test.js`, 37 passing. One line on the MCP agent inheriting the same rules.
