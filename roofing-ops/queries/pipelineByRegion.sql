-- Retool resource query: pipelineByRegion (feeds the KPI cards and the bar chart)
select * from api.pipeline_by_region({{ current_user.email }}, {{ sinceDate.value }}::date);
