-- Least-privilege for the Teleport `reader` role.
--
-- reader is the read-only debugging tier: GitHub team `readonly` -> Teleport role
-- newapi-db-reader -> db_users ["reader"]. That tier is deliberately built to see no
-- secrets (kube-viewer excludes k8s Secrets, and the role file calls the DB user a
-- "masked reader"), but the masking was one RLS policy on `options` while the role
-- held pg_read_all_data over all 86 tables.
--
-- Measured before this change, connecting as reader:
--   3,908 personal access tokens        (plaintext)
--   27,962 user API keys                (plaintext)
--   17,273 password hashes
--   162 distinct upstream provider keys (plaintext)
--   43 TOTP seeds + 172 backup codes    -- including root's, so the second factor
--                                          is generatable by this role
--
-- Postgres logs none of it: log_connections and log_statement are off, and Teleport
-- has recorded zero db sessions, so use leaves no trace on either side.
--
-- Shape: revoke the blanket grant, then grant per table, naming columns wherever a
-- table carries a secret. New tables are NOT readable until granted here. That is
-- deliberate -- a forgotten grant costs a debugging session, a forgotten exclusion
-- costs every credential on the platform.

BEGIN;

REVOKE pg_read_all_data FROM reader;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM reader;

GRANT SELECT ON public._bak_attacker_sessions_20260827 TO reader;
GRANT SELECT ON public._bak_blank_group_20260827 TO reader;
-- public._bak_chi_channels_20260827: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public._bak_chi_channels_20260827 TO reader;
-- public._bak_duck_channels_20260827: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public._bak_duck_channels_20260827 TO reader;
-- public._bak_duck_channels_20260827b: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public._bak_duck_channels_20260827b TO reader;
-- public._bak_easy_channels_20260827: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public._bak_easy_channels_20260827 TO reader;
-- public._bak_fish_channels_20260827: withholding key
GRANT SELECT ("id", "name", "tag", "status", "models", "group", "base_url") ON public._bak_fish_channels_20260827 TO reader;
-- public._bak_gg_channels_20260827: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public._bak_gg_channels_20260827 TO reader;
-- public._bak_held_tokens_20260827: withholding key
GRANT SELECT ("id", "user_id", "status", "name", "created_time", "accessed_time", "expired_time", "remain_quota", "unlimited_quota", "model_limits_enabled", "model_limits", "allow_ips", "used_quota", "group", "cross_group_retry", "deleted_at", "group_mapping", "auto_groups") ON public._bak_held_tokens_20260827 TO reader;
-- public._bak_noncrit_tokens_20260827: withholding key
GRANT SELECT ("id", "user_id", "status", "name", "created_time", "accessed_time", "expired_time", "remain_quota", "unlimited_quota", "model_limits_enabled", "model_limits", "allow_ips", "used_quota", "group", "cross_group_retry", "deleted_at", "group_mapping", "auto_groups") ON public._bak_noncrit_tokens_20260827 TO reader;
-- public._bak_open1_keys_20260827: withholding key
GRANT SELECT ("id", "name", "status") ON public._bak_open1_keys_20260827 TO reader;
-- public._bak_pol_channels_20260827: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public._bak_pol_channels_20260827 TO reader;
-- public._bak_pw_20260827: withholding password
GRANT SELECT ("id", "username", "auth_version") ON public._bak_pw_20260827 TO reader;
-- public._bak_root_pat_20260827: withholding access_token
GRANT SELECT ("id", "username", "backed_up_at") ON public._bak_root_pat_20260827 TO reader;
-- public._bak_stolen_tokens_20260827: withholding key
GRANT SELECT ("id", "user_id", "status", "name", "created_time", "accessed_time", "expired_time", "remain_quota", "unlimited_quota", "model_limits_enabled", "model_limits", "allow_ips", "used_quota", "group", "cross_group_retry", "deleted_at", "group_mapping", "auto_groups") ON public._bak_stolen_tokens_20260827 TO reader;
-- public._bak_tokens_4167_20260827: withholding key
GRANT SELECT ("id", "user_id", "status", "name", "created_time", "accessed_time", "expired_time", "remain_quota", "unlimited_quota", "model_limits_enabled", "model_limits", "allow_ips", "used_quota", "group", "cross_group_retry", "deleted_at", "group_mapping", "auto_groups") ON public._bak_tokens_4167_20260827 TO reader;
GRANT SELECT ON public._bak_user_setting_20260826 TO reader;
GRANT SELECT ON public._incident_20260827_noface2003 TO reader;
GRANT SELECT ON public.abil_grp_backup TO reader;
GRANT SELECT ON public.abilities TO reader;
-- public.auth_flows: withholding token_hash
GRANT SELECT ("id", "purpose", "provider", "intent", "user_id", "session_id", "payload", "created_at", "expires_at", "consumed_at") ON public.auth_flows TO reader;
GRANT SELECT ON public.authz_roles TO reader;
GRANT SELECT ON public.casbin_rule TO reader;
GRANT SELECT ON public.chan_grp_backup TO reader;
GRANT SELECT ON public.chan_tag_backup TO reader;
GRANT SELECT ON public.channel_diagnostics TO reader;
-- public.channels: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels TO reader;
-- public.channels_backup_20260814_glmcut: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_backup_20260814_glmcut TO reader;
-- public.channels_backup_20260818_chatdupes: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_backup_20260818_chatdupes TO reader;
-- public.channels_backup_20260818_glmcg_retire: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_backup_20260818_glmcg_retire TO reader;
GRANT SELECT ON public.channels_backup_20260819_vxinterval TO reader;
-- public.channels_backup_20260820_vxcut: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_backup_20260820_vxcut TO reader;
-- public.channels_backup_duck_20260815: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_backup_duck_20260815 TO reader;
-- public.channels_deleted_backup_20260812: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_deleted_backup_20260812 TO reader;
-- public.channels_deleted_backup_20260813: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_deleted_backup_20260813 TO reader;
-- public.channels_deleted_backup_20260813_dead: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_deleted_backup_20260813_dead TO reader;
-- public.channels_deleted_backup_20260813_exhausted: withholding key
GRANT SELECT ("id", "type", "open_ai_organization", "test_model", "status", "name", "weight", "created_time", "test_time", "response_time", "base_url", "other", "balance", "balance_updated_time", "models", "group", "used_quota", "model_mapping", "status_code_mapping", "priority", "auto_ban", "other_info", "tag", "setting", "param_override", "header_override", "remark", "channel_info", "settings", "workflow_templates") ON public.channels_deleted_backup_20260813_exhausted TO reader;
GRANT SELECT ON public.channels_setting_backup_20260814 TO reader;
GRANT SELECT ON public.checkins TO reader;
-- public.custom_oauth_providers: withholding client_secret
GRANT SELECT ("id", "name", "slug", "enabled", "client_id", "authorization_endpoint", "token_endpoint", "user_info_endpoint", "scopes", "user_id_field", "username_field", "display_name_field", "email_field", "well_known", "auth_style", "created_at", "updated_at", "icon", "access_policy", "access_denied_message") ON public.custom_oauth_providers TO reader;
GRANT SELECT ON public.external_identity_claims TO reader;
-- public.grp_rename_backup: withholding key
GRANT SELECT ("value") ON public.grp_rename_backup TO reader;
GRANT SELECT ON public.logs TO reader;
GRANT SELECT ON public.midjourneys TO reader;
GRANT SELECT ON public.model_status_components TO reader;
GRANT SELECT ON public.model_status_incidents TO reader;
GRANT SELECT ON public.model_status_pings TO reader;
GRANT SELECT ON public.model_statuses TO reader;
GRANT SELECT ON public.models TO reader;
GRANT SELECT ON public.models_deleted_backup_20260813_dark TO reader;
GRANT SELECT ON public.models_dup_backup TO reader;
GRANT SELECT ON public.mrtn_disable_backup TO reader;
GRANT SELECT ON public.o_auth_authn_sessions TO reader;
GRANT SELECT ON public.o_auth_clients TO reader;
-- public.o_auth_grants: withholding refresh_token
GRANT SELECT ("id", "grant_id", "auth_code", "client_id", "user_id", "data", "expires_at_unix", "created_at", "updated_at", "deleted_at") ON public.o_auth_grants TO reader;
GRANT SELECT ON public.o_auth_tokens TO reader;
-- public.options: withholding key
GRANT SELECT ("value") ON public.options TO reader;
-- public.options_backup_20260813_vertexcg: withholding key
GRANT SELECT ("value") ON public.options_backup_20260813_vertexcg TO reader;
-- public.options_backup_20260814_glmcut: withholding key
GRANT SELECT ("value") ON public.options_backup_20260814_glmcut TO reader;
-- public.options_backup_20260818_glmcg: withholding key
GRANT SELECT ("value") ON public.options_backup_20260818_glmcg TO reader;
GRANT SELECT ON public.passkey_credentials TO reader;
GRANT SELECT ON public.perf_metrics TO reader;
GRANT SELECT ON public.prefill_groups TO reader;
GRANT SELECT ON public.push_subscriptions TO reader;
GRANT SELECT ON public.quota_audit TO reader;
GRANT SELECT ON public.quota_data TO reader;
-- public.redemptions: withholding key
GRANT SELECT ("id", "user_id", "status", "name", "quota", "created_time", "redeemed_time", "used_user_id", "deleted_at", "expired_time") ON public.redemptions TO reader;
GRANT SELECT ON public.referral_commissions TO reader;
GRANT SELECT ON public.secret_keys TO reader;
GRANT SELECT ON public.setups TO reader;
GRANT SELECT ON public.subscription_orders TO reader;
GRANT SELECT ON public.subscription_plans TO reader;
GRANT SELECT ON public.subscription_pre_consume_records TO reader;
GRANT SELECT ON public.system_instances TO reader;
GRANT SELECT ON public.system_task_locks TO reader;
-- public.system_tasks: withholding active_key
GRANT SELECT ("id", "task_id", "type", "status", "payload", "state", "result", "error", "locked_by", "created_at", "updated_at") ON public.system_tasks TO reader;
-- public.tasks: withholding private_data
GRANT SELECT ("id", "created_at", "updated_at", "task_id", "platform", "user_id", "group", "channel_id", "quota", "action", "status", "fail_reason", "submit_time", "start_time", "finish_time", "progress", "properties", "data") ON public.tasks TO reader;
-- public.tokens: withholding key
GRANT SELECT ("id", "user_id", "status", "name", "created_time", "accessed_time", "expired_time", "remain_quota", "unlimited_quota", "model_limits_enabled", "model_limits", "allow_ips", "used_quota", "group", "cross_group_retry", "deleted_at", "group_mapping", "auto_groups") ON public.tokens TO reader;
GRANT SELECT ON public.top_ups TO reader;
-- public.two_fa_backup_codes: every column is secret-bearing, no grant
-- public.two_fas: withholding secret
GRANT SELECT ("id", "user_id", "is_enabled", "failed_attempts", "locked_until", "last_used_at", "created_at", "updated_at", "deleted_at") ON public.two_fas TO reader;
GRANT SELECT ON public.user_oauth_bindings TO reader;
GRANT SELECT ON public.user_sessions TO reader;
GRANT SELECT ON public.user_subscriptions TO reader;
-- public.users: withholding password, access_token
GRANT SELECT ("id", "username", "display_name", "role", "status", "email", "github_id", "discord_id", "oidc_id", "wechat_id", "telegram_id", "quota", "used_quota", "request_count", "group", "aff_code", "aff_count", "aff_quota", "aff_history", "inviter_id", "deleted_at", "linux_do_id", "setting", "remark", "stripe_customer", "referral_commission_percent", "creem_customer", "created_at", "last_login_at", "register_ip", "auth_version") ON public.users TO reader;
GRANT SELECT ON public.vendors TO reader;

COMMIT;

-- 46 secret columns withheld across 86 tables.
