-- Retool resource query: setJobStatus (write path, triggered by the status button)
-- On success: jobsList.trigger(). On error: show the DB message, which is written for users.
select api.set_job_status({{ current_user.email }}, {{ jobsTable.selectedRow.id }}::bigint, {{ newStatus.value }});
