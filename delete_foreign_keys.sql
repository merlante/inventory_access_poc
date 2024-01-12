ALTER TABLE system_repo DROP CONSTRAINT system_platform_id;
ALTER TABLE system_advisories DROP CONSTRAINT system_platform_id;
ALTER TABLE system_platform DROP CONSTRAINT baseline_id