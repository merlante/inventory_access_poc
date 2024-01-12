ALTER TABLE system_repo 
        ADD CONSTRAINT system_platform_id
        FOREIGN KEY (rh_account_id, system_id)
        REFERENCES system_platform (rh_account_id, id);

ALTER TABLE system_advisories 
    ADD CONSTRAINT system_platform_id
    FOREIGN KEY (rh_account_id, system_id)
    REFERENCES system_platform (rh_account_id, id);

ALTER TABLE system_platform 
    ADD CONSTRAINT baseline_id 
    FOREIGN KEY (rh_account_id, baseline_id) 
    REFERENCES baseline (rh_account_id, id);