-- Applied 2026-11-25: legacy accruals are internal Make operations.
REVOKE EXECUTE ON FUNCTION public.accrue_referral(text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.accrue_welcome(text,numeric) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.import_sheet_project_operation(text,text,numeric,date,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.accrue_referral(text,text),public.accrue_welcome(text,numeric),public.import_sheet_project_operation(text,text,numeric,date,text) TO make_connector;