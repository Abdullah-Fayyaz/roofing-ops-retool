-- Retool resource query: claimDetail (runs when a row is selected; reads are audited in the DB)
select * from api.claim_detail({{ current_user.email }}, {{ jobsTable.selectedRow.id }}::bigint);
