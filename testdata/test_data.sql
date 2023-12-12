-- runs: create_users.sql, then create_schema.sl, then create_inventory_hosts.sql, then test_data.sql original contents
DO
$$
    DECLARE
        usr text;
    BEGIN
    FOR usr IN
    SELECT name
    FROM (VALUES ('evaluator'), ('listener'), ('manager'), ('vmaas_sync'), ('cyndi')) users (name)
    WHERE name NOT IN (SELECT rolname FROM pg_catalog.pg_roles)
    LOOP
                    execute 'CREATE USER ' || usr || ';';
    END LOOP;
    END
$$
;
CREATE TABLE IF NOT EXISTS schema_migrations
(
    version bigint  NOT NULL,
    dirty   boolean NOT NULL,
    PRIMARY KEY (version)
    ) TABLESPACE pg_default;


INSERT INTO schema_migrations
VALUES (119, false);

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE COLLATION IF NOT EXISTS numeric (provider = icu, locale = 'en-u-kn-true');

-- empty
CREATE OR REPLACE FUNCTION empty(t TEXT)
    RETURNS BOOLEAN as
$$
BEGIN
RETURN t ~ '^[[:space:]]*$';
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION ternary(cond BOOL, iftrue ANYELEMENT, iffalse ANYELEMENT)
    RETURNS ANYELEMENT
AS
$$
SELECT CASE WHEN cond = TRUE THEN iftrue else iffalse END;
$$ LANGUAGE SQL IMMUTABLE;

-- set_first_reported
CREATE OR REPLACE FUNCTION set_first_reported()
    RETURNS TRIGGER AS
$set_first_reported$
BEGIN
    IF NEW.first_reported IS NULL THEN
        NEW.first_reported := CURRENT_TIMESTAMP;
END IF;
RETURN NEW;
END;
$set_first_reported$
LANGUAGE 'plpgsql';

-- set_last_updated
CREATE OR REPLACE FUNCTION set_last_updated()
    RETURNS TRIGGER AS
$set_last_updated$
BEGIN
    IF (TG_OP = 'UPDATE') OR
       NEW.last_updated IS NULL THEN
        NEW.last_updated := CURRENT_TIMESTAMP;
END IF;
RETURN NEW;
END;
$set_last_updated$
LANGUAGE 'plpgsql';

-- check_unchanged
CREATE OR REPLACE FUNCTION check_unchanged()
    RETURNS TRIGGER AS
$check_unchanged$
BEGIN
    IF (TG_OP = 'INSERT') AND
       NEW.unchanged_since IS NULL THEN
        NEW.unchanged_since := CURRENT_TIMESTAMP;
END IF;
    IF (TG_OP = 'UPDATE') AND
       NEW.json_checksum <> OLD.json_checksum THEN
        NEW.unchanged_since := CURRENT_TIMESTAMP;
END IF;
RETURN NEW;
END;
$check_unchanged$
LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION on_system_update()
-- this trigger updates advisory_account_data when server changes its stale flag
    RETURNS TRIGGER
AS
$system_update$
DECLARE
was_counted  BOOLEAN;
    should_count BOOLEAN;
    change       INT;
BEGIN
    -- Ignore not yet evaluated systems
    IF TG_OP != 'UPDATE' OR NEW.last_evaluation IS NULL THEN
        RETURN NEW;
END IF;

    was_counted := OLD.stale = FALSE;
    should_count := NEW.stale = FALSE;

    -- Determine what change we are performing
    IF was_counted and NOT should_count THEN
        change := -1;
    ELSIF NOT was_counted AND should_count THEN
        change := 1;
ELSE
        -- No change
        RETURN NEW;
END IF;

    -- find advisories linked to the server and lock them
WITH to_update_advisories AS (
    SELECT aad.advisory_id,
           aad.rh_account_id,
           -- Desired count depends on old count + change
           aad.systems_installable + case when sa.status_id = 0 then change else 0 end as systems_installable_dst,
           aad.systems_applicable + change as systems_applicable_dst
    FROM advisory_account_data aad
             JOIN system_advisories sa ON aad.advisory_id = sa.advisory_id
    -- Filter advisory_account_data only for advisories affectign this system & belonging to system account
    WHERE aad.rh_account_id =  NEW.rh_account_id
      AND sa.system_id = NEW.id AND sa.rh_account_id = NEW.rh_account_id
    ORDER BY aad.advisory_id FOR UPDATE OF aad),
-- Where count > 0, update existing rows
update AS (
UPDATE advisory_account_data aad
SET systems_installable = ta.systems_installable_dst,
    systems_applicable = ta.systems_applicable_dst
    FROM to_update_advisories ta
WHERE aad.advisory_id = ta.advisory_id
  AND aad.rh_account_id = NEW.rh_account_id
  AND (ta.systems_installable_dst > 0 OR ta.systems_applicable_dst > 0)
    ),
-- Where count = 0, delete existing rows
delete AS (
            DELETE
              FROM advisory_account_data aad
             USING to_update_advisories ta
             WHERE aad.rh_account_id = ta.rh_account_id
               AND aad.advisory_id = ta.advisory_id
               AND ta.systems_installable_dst <= 0
               AND ta.systems_applicable_dst <= 0
         )
    -- If we have system affected && no exisiting advisory_account_data entry, we insert new rows
    INSERT
      INTO advisory_account_data (advisory_id, rh_account_id, systems_installable, systems_applicable)
SELECT sa.advisory_id, NEW.rh_account_id,
       case when sa.status_id = 0 then 1 else 0 end as systems_installable,
       1 as systems_applicable
FROM system_advisories sa
WHERE sa.system_id = NEW.id AND sa.rh_account_id = NEW.rh_account_id
  AND change > 0
  -- create only rows which are not already in to_update_advisories
  AND (NEW.rh_account_id, sa.advisory_id) NOT IN (
    SELECT ta.rh_account_id, ta.advisory_id
    FROM to_update_advisories ta
)
    ON CONFLICT (advisory_id, rh_account_id) DO UPDATE
                                                    SET systems_installable = advisory_account_data.systems_installable + EXCLUDED.systems_installable,
                                                    systems_applicable = advisory_account_data.systems_applicable + EXCLUDED.systems_applicable;
RETURN NEW;
END;
$system_update$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_advisory_caches_multi(advisory_ids_in INTEGER[] DEFAULT NULL,
                                                         rh_account_id_in INTEGER DEFAULT NULL)
    RETURNS VOID AS
$refresh_advisory$
BEGIN
    -- Lock rows
    PERFORM aad.rh_account_id, aad.advisory_id
    FROM advisory_account_data aad
    WHERE (aad.advisory_id = ANY (advisory_ids_in) OR advisory_ids_in IS NULL)
      AND (aad.rh_account_id = rh_account_id_in OR rh_account_id_in IS NULL)
        FOR UPDATE OF aad;

WITH current_counts AS (
    SELECT sa.advisory_id, sa.rh_account_id,
           count(sa.*) filter (where sa.status_id = 0) as systems_installable,
            count(sa.*) as systems_applicable
    FROM system_advisories sa
             JOIN system_platform sp
                  ON sa.rh_account_id = sp.rh_account_id AND sa.system_id = sp.id
    WHERE sp.last_evaluation IS NOT NULL
      AND sp.stale = FALSE
      AND (sa.advisory_id = ANY (advisory_ids_in) OR advisory_ids_in IS NULL)
      AND (sp.rh_account_id = rh_account_id_in OR rh_account_id_in IS NULL)
    GROUP BY sa.advisory_id, sa.rh_account_id
),
     upserted AS (
INSERT INTO advisory_account_data (advisory_id, rh_account_id, systems_installable, systems_applicable)
SELECT advisory_id, rh_account_id, systems_installable, systems_applicable
FROM current_counts
    ON CONFLICT (advisory_id, rh_account_id) DO UPDATE SET
    systems_installable = EXCLUDED.systems_installable,
                                                    systems_applicable = EXCLUDED.systems_applicable
                                                    )
DELETE FROM advisory_account_data
WHERE (advisory_id, rh_account_id) NOT IN (SELECT advisory_id, rh_account_id FROM current_counts)
  AND (advisory_id = ANY (advisory_ids_in) OR advisory_ids_in IS NULL)
  AND (rh_account_id = rh_account_id_in OR rh_account_id_in IS NULL);
END;
$refresh_advisory$ language plpgsql;

CREATE OR REPLACE FUNCTION refresh_advisory_caches(advisory_id_in INTEGER DEFAULT NULL,
                                                   rh_account_id_in INTEGER DEFAULT NULL)
    RETURNS VOID AS
$refresh_advisory$
BEGIN
    IF advisory_id_in IS NOT NULL THEN
        PERFORM refresh_advisory_caches_multi(ARRAY [advisory_id_in], rh_account_id_in);
ELSE
        PERFORM refresh_advisory_caches_multi(NULL, rh_account_id_in);
END IF;
END;
$refresh_advisory$ language plpgsql;

CREATE OR REPLACE FUNCTION refresh_system_caches(system_id_in BIGINT DEFAULT NULL,
                                                 rh_account_id_in INTEGER DEFAULT NULL)
    RETURNS INTEGER AS
$refresh_system$
DECLARE
COUNT INTEGER;
BEGIN
WITH system_advisories_count AS (
    SELECT asp.rh_account_id, asp.id,
           COUNT(advisory_id) FILTER (WHERE sa.status_id = 0) as installable_total,
            COUNT(advisory_id) FILTER (WHERE am.advisory_type_id = 1 AND sa.status_id = 0) AS installable_enhancement,
            COUNT(advisory_id) FILTER (WHERE am.advisory_type_id = 2 AND sa.status_id = 0) AS installable_bugfix,
            COUNT(advisory_id) FILTER (WHERE am.advisory_type_id = 3 AND sa.status_id = 0) as installable_security,
            COUNT(advisory_id) as applicable_total,
           COUNT(advisory_id) FILTER (WHERE am.advisory_type_id = 1) AS applicable_enhancement,
            COUNT(advisory_id) FILTER (WHERE am.advisory_type_id = 2) AS applicable_bugfix,
            COUNT(advisory_id) FILTER (WHERE am.advisory_type_id = 3) as applicable_security
    FROM system_platform asp  -- this table ensures even systems without any system_advisories are in results
             LEFT JOIN system_advisories sa
                       ON asp.rh_account_id = sa.rh_account_id AND asp.id = sa.system_id
             LEFT JOIN advisory_metadata am
                       ON sa.advisory_id = am.id
    WHERE (asp.id = system_id_in OR system_id_in IS NULL)
      AND (asp.rh_account_id = rh_account_id_in OR rh_account_id_in IS NULL)
    GROUP BY asp.rh_account_id, asp.id
    ORDER BY asp.rh_account_id, asp.id
)
UPDATE system_platform sp
SET installable_advisory_count_cache = sc.installable_total,
    installable_advisory_enh_count_cache = sc.installable_enhancement,
    installable_advisory_bug_count_cache = sc.installable_bugfix,
    installable_advisory_sec_count_cache = sc.installable_security,
    applicable_advisory_count_cache = sc.applicable_total,
    applicable_advisory_enh_count_cache = sc.applicable_enhancement,
    applicable_advisory_bug_count_cache = sc.applicable_bugfix,
    applicable_advisory_sec_count_cache = sc.applicable_security
    FROM system_advisories_count sc
WHERE sp.rh_account_id = sc.rh_account_id AND sp.id = sc.id
  AND (sp.id = system_id_in OR system_id_in IS NULL)
  AND (sp.rh_account_id = rh_account_id_in OR rh_account_id_in IS NULL);

GET DIAGNOSTICS COUNT = ROW_COUNT;
RETURN COUNT;
END;
$refresh_system$ LANGUAGE plpgsql;

-- update system advisories counts (all and according types)
CREATE OR REPLACE FUNCTION update_system_caches(system_id_in BIGINT)
    RETURNS VOID AS
$update_system_caches$
BEGIN
    PERFORM refresh_system_caches(system_id_in, NULL);
END;
$update_system_caches$
LANGUAGE 'plpgsql';

-- refresh_all_cached_counts
-- WARNING: executing this procedure takes long time,
--          use only when necessary, e.g. during upgrade to populate initial caches
CREATE OR REPLACE FUNCTION refresh_all_cached_counts()
    RETURNS void AS
$refresh_all_cached_counts$
BEGIN
    PERFORM refresh_system_caches(NULL, NULL);
    PERFORM refresh_advisory_caches(NULL, NULL);
END;
$refresh_all_cached_counts$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION refresh_account_cached_counts(rh_account_in varchar)
    RETURNS void AS
$refresh_account_cached_counts$
DECLARE
rh_account_id_in INT;
BEGIN
    -- update advisory count for ordered systems
SELECT id FROM rh_account WHERE name = rh_account_in INTO rh_account_id_in;

PERFORM refresh_system_caches(NULL, rh_account_id_in);
    PERFORM refresh_advisory_caches(NULL, rh_account_id_in);
END;
$refresh_account_cached_counts$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION refresh_advisory_cached_counts(advisory_name varchar)
    RETURNS void AS
$refresh_advisory_cached_counts$
DECLARE
advisory_id_id BIGINT;
BEGIN
    -- update system count for advisory
SELECT id FROM advisory_metadata WHERE name = advisory_name INTO advisory_id_id;

PERFORM refresh_advisory_caches(advisory_id_id, NULL);
END;
$refresh_advisory_cached_counts$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION refresh_advisory_account_cached_counts(advisory_name varchar, rh_account_name varchar)
    RETURNS void AS
$refresh_advisory_account_cached_counts$
DECLARE
advisory_md_id   BIGINT;
    rh_account_id_in INT;
BEGIN
    -- update system count for ordered advisories
SELECT id FROM advisory_metadata WHERE name = advisory_name INTO advisory_md_id;
SELECT id FROM rh_account WHERE name = rh_account_name INTO rh_account_id_in;

PERFORM refresh_advisory_caches(advisory_md_id, rh_account_id_in);
END;
$refresh_advisory_account_cached_counts$
LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION refresh_system_cached_counts(inventory_id_in varchar)
    RETURNS void AS
$refresh_system_cached_counts$
DECLARE
system_id int;
BEGIN

SELECT id FROM system_platform WHERE inventory_id = inventory_id_in INTO system_id;

PERFORM refresh_system_caches(system_id, NULL);
END;
$refresh_system_cached_counts$
LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION delete_system(inventory_id_in uuid)
    RETURNS TABLE
            (
                deleted_inventory_id uuid
            )
AS
$delete_system$
DECLARE
v_system_id  INT;
    v_account_id INT;
BEGIN
    -- opt out to refresh cache and then delete
SELECT id, rh_account_id
FROM system_platform
WHERE inventory_id = inventory_id_in
    LIMIT 1
        FOR UPDATE OF system_platform
            INTO v_system_id, v_account_id;

IF v_system_id IS NULL OR v_account_id IS NULL THEN
        RAISE NOTICE 'Not found';
        RETURN;
END IF;

UPDATE system_platform
SET stale = true
WHERE rh_account_id = v_account_id
  AND id = v_system_id;

DELETE
FROM system_advisories
WHERE rh_account_id = v_account_id
  AND system_id = v_system_id;

DELETE
FROM system_repo
WHERE rh_account_id = v_account_id
  AND system_id = v_system_id;

DELETE
FROM system_package
WHERE rh_account_id = v_account_id
  AND system_id = v_system_id;

DELETE
FROM system_package2
WHERE rh_account_id = v_account_id
  AND system_id = v_system_id;

RETURN QUERY DELETE FROM system_platform
        WHERE rh_account_id = v_account_id AND
              id = v_system_id
        RETURNING inventory_id;
END;
$delete_system$ LANGUAGE 'plpgsql';

CREATE OR REPLACE FUNCTION delete_systems(inventory_ids UUID[])
    RETURNS INTEGER
AS
$$
DECLARE
tmp_cnt INTEGER;
BEGIN

WITH systems as (
    SELECT rh_account_id, id
    FROM system_platform
    WHERE inventory_id = ANY (inventory_ids)
    ORDER BY rh_account_id, id FOR UPDATE OF system_platform),
         marked as (
             UPDATE system_platform sp
                 SET stale = true
                 WHERE (rh_account_id, id) in (select rh_account_id, id from systems)
         ),
         advisories as (
             DELETE
                 FROM system_advisories
                     WHERE (rh_account_id, system_id) in (select rh_account_id, id from systems)
         ),
         repos as (
             DELETE
                 FROM system_repo
                     WHERE (rh_account_id, system_id) in (select rh_account_id, id from systems)
         ),
         packages as (
             DELETE
                 FROM system_package
                     WHERE (rh_account_id, system_id) in (select rh_account_id, id from systems)
         ),
         packages2 as (
             DELETE
                 FROM system_package2
                     WHERE (rh_account_id, system_id) in (select rh_account_id, id from systems)
         ),
         deleted as (
             DELETE
                 FROM system_platform
                     WHERE (rh_account_id, id) in (select rh_account_id, id from systems)
                     RETURNING id
         )
SELECT count(*)
FROM deleted
    INTO tmp_cnt;

RETURN tmp_cnt;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION delete_culled_systems(delete_limit INTEGER)
    RETURNS INTEGER
AS
$fun$
DECLARE
ids UUID[];
BEGIN
    ids := ARRAY(
            SELECT inventory_id
            FROM system_platform
            WHERE culled_timestamp < now()
            ORDER BY id
            LIMIT delete_limit
        );
return delete_systems(ids);
END;
$fun$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_stale_systems(mark_limit integer)
    RETURNS INTEGER
AS
$fun$
DECLARE
marked integer;
BEGIN
WITH ids AS (
    SELECT rh_account_id, id
    FROM system_platform
    WHERE stale_warning_timestamp < now()
      AND stale = false
    ORDER BY rh_account_id, id FOR UPDATE OF system_platform
    LIMIT mark_limit
    )
UPDATE system_platform sp
SET stale = true
    FROM ids
WHERE sp.rh_account_id = ids.rh_account_id
  AND sp.id = ids.id;
GET DIAGNOSTICS marked = ROW_COUNT;
RETURN marked;
END;
$fun$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hash_partition_id(id int, parts int)
    RETURNS int AS
$$
BEGIN
        -- src/include/common/hashfn.h:83
        --  a ^= b + UINT64CONST(0x49a0f4dd15e5a8e3) + (a << 54) + (a >> 7);
        -- => 8816678312871386365
        -- src/include/catalog/partition.h:20
        --  #define HASH_PARTITION_SEED UINT64CONST(0x7A5B22367996DCFD)
        -- => 5305509591434766563
RETURN (((hashint4extended(id, 8816678312871386365)::numeric + 5305509591434766563) % parts + parts)::int % parts);
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION create_table_partitions(tbl regclass, parts INTEGER, rest text)
    RETURNS VOID AS
$$
DECLARE
I INTEGER;
BEGIN
    I := 0;
    WHILE I < parts
        LOOP
            EXECUTE 'CREATE TABLE IF NOT EXISTS ' || text(tbl) || '_' || text(I) || ' PARTITION OF ' || text(tbl) ||
                    ' FOR VALUES WITH ' || ' ( MODULUS ' || text(parts) || ', REMAINDER ' || text(I) || ')' ||
                    rest || ';';
            I = I + 1;
END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_table_partition_triggers(name text, trig_type text, tbl regclass, trig_text text)
    RETURNS VOID AS
$$
DECLARE
r record;
    trig_name text;
BEGIN
FOR r IN SELECT child.relname
         FROM pg_inherits
                  JOIN pg_class parent
                       ON pg_inherits.inhparent = parent.oid
                  JOIN pg_class child
                       ON pg_inherits.inhrelid   = child.oid
         WHERE parent.relname = text(tbl)
             LOOP
        trig_name := name || substr(r.relname, length(text(tbl)) +1 );
EXECUTE 'DROP TRIGGER IF EXISTS ' || trig_name || ' ON ' || r.relname;
EXECUTE 'CREATE TRIGGER ' || trig_name ||
        ' ' || trig_type || ' ON ' || r.relname || ' ' || trig_text || ';';
END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rename_table_with_partitions(tbl regclass, oldtext text, newtext text)
    RETURNS VOID AS
$$
DECLARE
r record;
BEGIN
FOR r IN SELECT child.relname
         FROM pg_inherits
                  JOIN pg_class parent
                       ON pg_inherits.inhparent = parent.oid
                  JOIN pg_class child
                       ON pg_inherits.inhrelid   = child.oid
         WHERE parent.relname = text(tbl)
             LOOP
        EXECUTE 'ALTER TABLE IF EXISTS ' || r.relname || ' RENAME TO ' || replace(r.relname, oldtext, newtext);
END LOOP;
EXECUTE 'ALTER TABLE IF EXISTS ' || text(tbl) || ' RENAME TO ' || replace(text(tbl), oldtext, newtext);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION drop_table_partition_triggers(name text, trig_type text, tbl regclass, trig_text text)
    RETURNS VOID AS
$$
DECLARE
r record;
    trig_name text;
BEGIN
FOR r IN SELECT child.relname
         FROM pg_inherits
                  JOIN pg_class parent
                       ON pg_inherits.inhparent = parent.oid
                  JOIN pg_class child
                       ON pg_inherits.inhrelid   = child.oid
         WHERE parent.relname = text(tbl)
             LOOP
        trig_name := name || substr(r.relname, length(text(tbl)) +1 );
EXECUTE 'DROP TRIGGER IF EXISTS ' || trig_name || ' ON ' || r.relname;
END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rename_index_with_partitions(idx regclass, oldtext text, newtext text)
    RETURNS VOID AS
$$
DECLARE
r record;
BEGIN
FOR r IN SELECT child.relname
         FROM pg_inherits
                  JOIN pg_class parent
                       ON pg_inherits.inhparent = parent.oid
                  JOIN pg_class child
                       ON pg_inherits.inhrelid   = child.oid
         WHERE parent.relname = text(idx)
             LOOP
        EXECUTE 'ALTER INDEX IF EXISTS ' || r.relname || ' RENAME TO ' || replace(r.relname, oldtext, newtext);
END LOOP;
EXECUTE 'ALTER INDEX IF EXISTS ' || text(idx) || ' RENAME TO ' || replace(text(idx), oldtext, newtext);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION update_status(update_data jsonb)
    RETURNS TEXT as
$$
DECLARE
len int;
BEGIN
    len = jsonb_array_length(update_data);
    IF len IS NULL or len = 0 THEN
        RETURN 'None';
END IF;
    len = jsonb_array_length(jsonb_path_query_array(update_data, '$ ? (@.status == "Installable")'));
    IF len > 0 THEN
        RETURN 'Installable';
END IF;
RETURN 'Applicable';
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;


-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- rh_account
CREATE TABLE IF NOT EXISTS rh_account
(
    id                      INT GENERATED BY DEFAULT AS IDENTITY,
    name                    TEXT UNIQUE CHECK (NOT empty(name)),
    org_id                  TEXT UNIQUE CHECK (NOT empty(org_id)),
    valid_package_cache     BOOLEAN NOT NULL DEFAULT FALSE,
    valid_advisory_cache    BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (name IS NOT NULL OR org_id IS NOT NULL),
    PRIMARY KEY (id)
    ) TABLESPACE pg_default;

GRANT SELECT, INSERT, UPDATE, DELETE ON rh_account TO listener;
GRANT SELECT, UPDATE ON rh_account TO evaluator;
GRANT SELECT, INSERT, UPDATE ON rh_account TO manager;
GRANT UPDATE ON rh_account TO vmaas_sync;

CREATE TABLE reporter
(
    id   INT  NOT NULL,
    name TEXT NOT NULL UNIQUE CHECK ( not empty(name) ),
    PRIMARY KEY (id)
);

INSERT INTO reporter (id, name)
VALUES (1, 'puptoo'),
       (2, 'rhsm-conduit'),
       (3, 'yupana'),
       (4, 'rhsm-system-profile-bridge')
    ON CONFLICT DO NOTHING;

-- baseline
CREATE TABLE IF NOT EXISTS baseline
(
    id            BIGINT            GENERATED BY DEFAULT AS IDENTITY,
    rh_account_id INT               NOT NULL REFERENCES rh_account (id),
    name          TEXT              NOT NULL CHECK (not empty(name)),
    config        JSONB,
    description   TEXT              CHECK (NOT empty(description)),
    creator       TEXT              CHECK (NOT empty(creator)),
    published     TIMESTAMP WITH TIME ZONE,
    last_edited   TIMESTAMP WITH TIME ZONE,
                                PRIMARY KEY (rh_account_id, id),
    UNIQUE(rh_account_id, name)
    ) PARTITION BY HASH (rh_account_id);

GRANT SELECT, UPDATE, DELETE, INSERT ON baseline TO manager;
GRANT SELECT, UPDATE, DELETE ON baseline TO listener;
GRANT SELECT, UPDATE, DELETE ON baseline TO evaluator;
GRANT SELECT, UPDATE, DELETE ON baseline TO vmaas_sync;

SELECT create_table_partitions('baseline', 16,
                               $$WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')$$);

-- system_platform
CREATE TABLE IF NOT EXISTS system_platform
(
    id                                   BIGINT GENERATED BY DEFAULT AS IDENTITY,
    inventory_id                         UUID                     NOT NULL,
    rh_account_id                        INT                      NOT NULL,
    vmaas_json                           TEXT                     CHECK (NOT empty(vmaas_json)),
    json_checksum                        TEXT                     CHECK (NOT empty(json_checksum)),
    last_updated                         TIMESTAMP WITH TIME ZONE NOT NULL,
    unchanged_since                      TIMESTAMP WITH TIME ZONE NOT NULL,
    last_evaluation                      TIMESTAMP WITH TIME ZONE,
    installable_advisory_count_cache     INT                      NOT NULL DEFAULT 0,
    installable_advisory_enh_count_cache INT                      NOT NULL DEFAULT 0,
    installable_advisory_bug_count_cache INT                      NOT NULL DEFAULT 0,
    installable_advisory_sec_count_cache INT                      NOT NULL DEFAULT 0,
    last_upload              TIMESTAMP WITH TIME ZONE,
    stale_timestamp          TIMESTAMP WITH TIME ZONE,
    stale_warning_timestamp  TIMESTAMP WITH TIME ZONE,
    culled_timestamp         TIMESTAMP WITH TIME ZONE,
                                           stale                    BOOLEAN                  NOT NULL DEFAULT false,
                                           display_name             TEXT                     NOT NULL CHECK (NOT empty(display_name)),
    packages_installed       INT                      NOT NULL DEFAULT 0,
    packages_updatable       INT                      NOT NULL DEFAULT 0,
    reporter_id              INT,
    third_party              BOOLEAN                  NOT NULL DEFAULT false,
    baseline_id              BIGINT,
    baseline_uptodate        BOOLEAN,
    yum_updates              JSONB,
    applicable_advisory_count_cache      INT                      NOT NULL DEFAULT 0,
    applicable_advisory_enh_count_cache  INT                      NOT NULL DEFAULT 0,
    applicable_advisory_bug_count_cache  INT                      NOT NULL DEFAULT 0,
    applicable_advisory_sec_count_cache  INT                      NOT NULL DEFAULT 0,
    satellite_managed                    BOOLEAN                  NOT NULL DEFAULT FALSE,
    built_pkgcache                       BOOLEAN                  NOT NULL DEFAULT FALSE,
    PRIMARY KEY (rh_account_id, id),
    UNIQUE (rh_account_id, inventory_id),
    CONSTRAINT reporter_id FOREIGN KEY (reporter_id) REFERENCES reporter (id),
    CONSTRAINT baseline_id FOREIGN KEY (rh_account_id, baseline_id) REFERENCES baseline (rh_account_id, id)
    ) PARTITION BY HASH (rh_account_id);

SELECT create_table_partitions('system_platform', 16,
                               $$WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')
                                   TABLESPACE pg_default$$);

SELECT create_table_partition_triggers('system_platform_set_last_updated',
                                       $$BEFORE INSERT OR UPDATE$$,
                                       'system_platform',
                                       $$FOR EACH ROW EXECUTE PROCEDURE set_last_updated()$$);

SELECT create_table_partition_triggers('system_platform_check_unchanged',
                                       $$BEFORE INSERT OR UPDATE$$,
                                       'system_platform',
                                       $$FOR EACH ROW EXECUTE PROCEDURE check_unchanged()$$);

SELECT create_table_partition_triggers('system_platform_on_update',
                                       $$AFTER UPDATE$$,
                                       'system_platform',
                                       $$FOR EACH ROW EXECUTE PROCEDURE on_system_update()$$);

CREATE INDEX IF NOT EXISTS system_platform_inventory_id_idx
    ON system_platform (inventory_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON system_platform TO listener;
-- evaluator needs to update last_evaluation
GRANT UPDATE ON system_platform TO evaluator;
-- manager needs to update cache and delete systems
GRANT UPDATE (installable_advisory_count_cache,
              installable_advisory_enh_count_cache,
              installable_advisory_bug_count_cache,
              installable_advisory_sec_count_cache), DELETE ON system_platform TO manager;
GRANT UPDATE (applicable_advisory_count_cache,
              applicable_advisory_enh_count_cache,
              applicable_advisory_bug_count_cache,
              applicable_advisory_sec_count_cache), DELETE ON system_platform TO manager;

GRANT SELECT, UPDATE, DELETE ON system_platform TO manager;

-- VMaaS sync needs to be able to perform system culling tasks
GRANT SELECT, UPDATE, DELETE ON system_platform to vmaas_sync;

CREATE TABLE IF NOT EXISTS deleted_system
(
    inventory_id TEXT                     NOT NULL,
    CHECK (NOT empty(inventory_id)),
    when_deleted TIMESTAMP WITH TIME ZONE NOT NULL,
                               UNIQUE (inventory_id)
    ) TABLESPACE pg_default;

CREATE INDEX ON deleted_system (when_deleted);

GRANT SELECT, INSERT, UPDATE, DELETE ON deleted_system TO listener;
-- advisory_type
CREATE TABLE IF NOT EXISTS advisory_type
(
    id   INT  NOT NULL,
    name TEXT NOT NULL UNIQUE,
    preference INTEGER NOT NULL DEFAULT 0,
    CHECK (NOT empty(name)),
    PRIMARY KEY (id)
    ) TABLESPACE pg_default;

INSERT INTO advisory_type (id, name, preference)
VALUES (0, 'unknown', 100),
       (1, 'enhancement', 300),
       (2, 'bugfix', 400),
       (3, 'security', 500),
       (4, 'unspecified', 200)
    ON CONFLICT DO NOTHING;

CREATE TABLE advisory_severity
(
    id   INT  NOT NULL,
    name TEXT NOT NULL UNIQUE CHECK ( not empty(name) ),
    PRIMARY KEY (id)
);

INSERT INTO advisory_severity (id, name)
VALUES (1, 'Low'),
       (2, 'Moderate'),
       (3, 'Important'),
       (4, 'Critical')
    ON CONFLICT DO NOTHING;

-- advisory_metadata
CREATE TABLE IF NOT EXISTS advisory_metadata
(
    id               BIGINT GENERATED BY DEFAULT AS IDENTITY,
    name             TEXT                     NOT NULL CHECK (NOT empty(name)),
    description      TEXT                     NOT NULL CHECK (NOT empty(description)),
    synopsis         TEXT                     NOT NULL CHECK (NOT empty(synopsis)),
    summary          TEXT                     NOT NULL CHECK (NOT empty(summary)),
    solution         TEXT                     CHECK (NOT empty(solution)),
    advisory_type_id INT                      NOT NULL,
    public_date      TIMESTAMP WITH TIME ZONE NULL,
    modified_date    TIMESTAMP WITH TIME ZONE NULL,
                                   url              TEXT CHECK (NOT empty(url)),
    severity_id      INT,
    package_data     JSONB,
    cve_list         JSONB,
    reboot_required  BOOLEAN NOT NULL DEFAULT false,
    release_versions JSONB,
    synced           BOOLEAN NOT NULL DEFAULT false,
    UNIQUE (name),
    PRIMARY KEY (id),
    CONSTRAINT advisory_type_id
    FOREIGN KEY (advisory_type_id)
    REFERENCES advisory_type (id),
    CONSTRAINT advisory_severity_id
    FOREIGN KEY (severity_id)
    REFERENCES advisory_severity (id)
    ) TABLESPACE pg_default;

CREATE INDEX ON advisory_metadata (advisory_type_id);

CREATE INDEX IF NOT EXISTS
    advisory_metadata_pkgdata_idx ON advisory_metadata
    USING GIN ((advisory_metadata.package_data));

GRANT SELECT, INSERT, UPDATE, DELETE ON advisory_metadata TO evaluator;
GRANT SELECT, INSERT, UPDATE, DELETE ON advisory_metadata TO vmaas_sync;
GRANT SELECT ON advisory_metadata TO manager;

-- status table
CREATE TABLE IF NOT EXISTS status
(
    id   INT  NOT NULL,
    name TEXT NOT NULL UNIQUE,
    CHECK (NOT empty(name)),
    PRIMARY KEY (id)
    ) TABLESPACE pg_default;

INSERT INTO status (id, name)
VALUES (0, 'Installable'),
       (1, 'Applicable')
    ON CONFLICT DO NOTHING;


-- system_advisories
CREATE TABLE IF NOT EXISTS system_advisories
(
    rh_account_id  INT                      NOT NULL,
    system_id      BIGINT                   NOT NULL,
    advisory_id    BIGINT                   NOT NULL,
    first_reported TIMESTAMP WITH TIME ZONE NOT NULL,
    status_id      INT                      NOT NULL,
    PRIMARY KEY (rh_account_id, system_id, advisory_id),
    CONSTRAINT advisory_metadata_id
    FOREIGN KEY (advisory_id)
    REFERENCES advisory_metadata (id)
    ) PARTITION BY HASH (rh_account_id);

SELECT create_table_partitions('system_advisories', 32,
                               $$WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')$$);

SELECT create_table_partition_triggers('system_advisories_set_first_reported',
                                       $$BEFORE INSERT$$,
                                       'system_advisories',
                                       $$FOR EACH ROW EXECUTE PROCEDURE set_first_reported()$$);

GRANT SELECT, INSERT, UPDATE, DELETE ON system_advisories TO evaluator;
-- manager needs to be able to update things like 'status' on a sysid/advisory combination, also needs to delete
GRANT UPDATE, DELETE ON system_advisories TO manager;
-- manager needs to be able to update opt_out column
GRANT UPDATE (stale) ON system_platform TO manager;
-- listener deletes systems, TODO: temporary added evaluator permissions to listener
GRANT SELECT, INSERT, UPDATE, DELETE ON system_advisories TO listener;
-- vmaas_sync needs to delete culled systems, which cascades to system_advisories
GRANT SELECT, DELETE ON system_advisories TO vmaas_sync;

-- advisory_account_data
CREATE TABLE IF NOT EXISTS advisory_account_data
(
    advisory_id              BIGINT NOT NULL,
    rh_account_id            INT NOT NULL,
    systems_applicable       INT NOT NULL DEFAULT 0,
    systems_installable      INT NOT NULL DEFAULT 0,
    notified                 TIMESTAMP WITH TIME ZONE NULL,
    CONSTRAINT advisory_metadata_id
    FOREIGN KEY (advisory_id)
    REFERENCES advisory_metadata (id),
    CONSTRAINT rh_account_id
    FOREIGN KEY (rh_account_id)
    REFERENCES rh_account (id),
    UNIQUE (advisory_id, rh_account_id),
    PRIMARY KEY (rh_account_id, advisory_id)
    ) WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')
    TABLESPACE pg_default;

-- manager user needs to change this table for opt-out functionality
GRANT SELECT, INSERT, UPDATE, DELETE ON advisory_account_data TO manager;
-- evaluator user needs to change this table
GRANT SELECT, INSERT, UPDATE, DELETE ON advisory_account_data TO evaluator;
-- listner user needs to change this table when deleting system
GRANT SELECT, INSERT, UPDATE, DELETE ON advisory_account_data TO listener;
-- vmaas_sync needs to update stale mark, which creates and deletes advisory_account_data
GRANT SELECT, INSERT, UPDATE, DELETE ON advisory_account_data TO vmaas_sync;

-- repo
CREATE TABLE IF NOT EXISTS repo
(
    id              BIGINT GENERATED BY DEFAULT AS IDENTITY,
    name            TEXT NOT NULL UNIQUE,
    third_party     BOOLEAN NOT NULL DEFAULT true,
    CHECK (NOT empty(name)),
    PRIMARY KEY (id)
    ) TABLESPACE pg_default;

GRANT SELECT, INSERT, UPDATE, DELETE ON repo TO listener;
GRANT SELECT, INSERT, UPDATE, DELETE ON repo TO evaluator;


-- system_repo
CREATE TABLE IF NOT EXISTS system_repo
(
    system_id     BIGINT NOT NULL,
    repo_id       BIGINT NOT NULL,
    rh_account_id INT NOT NULL,
    UNIQUE (rh_account_id, system_id, repo_id),
    CONSTRAINT system_platform_id
    FOREIGN KEY (rh_account_id, system_id)
    REFERENCES system_platform (rh_account_id, id),
    CONSTRAINT repo_id
    FOREIGN KEY (repo_id)
    REFERENCES repo (id)
    ) TABLESPACE pg_default;

CREATE INDEX ON system_repo (repo_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON system_repo TO listener;
GRANT DELETE ON system_repo TO manager;
GRANT SELECT, INSERT, UPDATE, DELETE ON system_repo TO evaluator;
GRANT SELECT, DELETE on system_repo to vmaas_sync;

-- the following constraints are enabled here not directly in the table definitions
-- to make new schema equal to the migrated schema
ALTER TABLE system_advisories
    ADD CONSTRAINT system_platform_id
        FOREIGN KEY (rh_account_id, system_id)
            REFERENCES system_platform (rh_account_id, id),
    ADD CONSTRAINT status_id
        FOREIGN KEY (status_id)
            REFERENCES status (id);
ALTER TABLE system_platform
    ADD CONSTRAINT rh_account_id
        FOREIGN KEY (rh_account_id)
            REFERENCES rh_account (id);

CREATE TABLE IF NOT EXISTS package_name
(
    id   BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL PRIMARY KEY,
    name TEXT                                 NOT NULL CHECK (NOT empty(name)) UNIQUE,
    -- "cache" latest summary for given package name here to display it on /packages API
    -- without joining other tables
    summary      TEXT                         CHECK (NOT empty(summary))
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE package_name TO vmaas_sync;
GRANT SELECT, INSERT, UPDATE ON TABLE package_name TO evaluator;

CREATE TABLE IF NOT EXISTS strings
(
    id    BYTEA NOT NULL PRIMARY KEY,
    value TEXT  NOT NULL CHECK (NOT empty(value))
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE strings TO vmaas_sync;

CREATE TABLE IF NOT EXISTS package
(
    id               BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL PRIMARY KEY,
    name_id          BIGINT                                  NOT NULL REFERENCES package_name,
    evra             TEXT                                 NOT NULL CHECK (NOT empty(evra)),
    description_hash BYTEA                                         REFERENCES strings (id),
    summary_hash     BYTEA                                         REFERENCES strings (id),
    advisory_id      BIGINT REFERENCES advisory_metadata (id),
    synced           BOOLEAN                              NOT NULL DEFAULT false,
    UNIQUE (name_id, evra)
    ) WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')
    TABLESPACE pg_default;

CREATE UNIQUE INDEX IF NOT EXISTS package_evra_idx on package (evra, name_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE package TO vmaas_sync;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE package TO evaluator;

CREATE TABLE IF NOT EXISTS system_package
(
    rh_account_id INT                                  NOT NULL REFERENCES rh_account,
    system_id     BIGINT                               NOT NULL,
    package_id    BIGINT                               NOT NULL REFERENCES package,
    -- Use null to represent up-to-date packages
    update_data   JSONB DEFAULT NULL,
    latest_evra   TEXT GENERATED ALWAYS AS ( ((update_data ->> -1)::jsonb ->> 'evra')::text) STORED
    CHECK(NOT empty(latest_evra)),
    name_id       BIGINT REFERENCES package_name (id) NOT NULL,

    PRIMARY KEY (rh_account_id, system_id, package_id) INCLUDE (latest_evra)
    ) PARTITION BY HASH (rh_account_id);

CREATE INDEX IF NOT EXISTS system_package_name_pkg_system_idx
    ON system_package (rh_account_id, name_id, package_id, system_id) INCLUDE (latest_evra);

CREATE INDEX IF NOT EXISTS system_package_package_id_idx on system_package (package_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON system_package TO evaluator;
GRANT SELECT, UPDATE, DELETE ON system_package TO listener;
GRANT SELECT, UPDATE, DELETE ON system_package TO manager;
GRANT SELECT, UPDATE, DELETE ON system_package TO vmaas_sync;

SELECT create_table_partitions('system_package', 128,
                               $$WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')$$);

CREATE TABLE IF NOT EXISTS system_package2
(
    rh_account_id  INT    NOT NULL,
    system_id      BIGINT NOT NULL,
    name_id        BIGINT NOT NULL REFERENCES package_name (id),
    package_id     BIGINT NOT NULL REFERENCES package (id),
    -- Use null to represent up-to-date packages
    installable_id BIGINT REFERENCES package (id),
    applicable_id  BIGINT REFERENCES package (id),

    PRIMARY KEY (rh_account_id, system_id, package_id),
    FOREIGN KEY (rh_account_id, system_id) REFERENCES system_platform (rh_account_id, id)
    ) PARTITION BY HASH (rh_account_id);

CREATE INDEX IF NOT EXISTS system_package2_account_pkg_name_idx
    ON system_package2 (rh_account_id, name_id) INCLUDE (system_id, package_id, installable_id, applicable_id);

CREATE INDEX IF NOT EXISTS system_package2_package_id_idx on system_package2 (package_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON system_package2 TO evaluator;
GRANT SELECT, UPDATE, DELETE ON system_package2 TO listener;
GRANT SELECT, UPDATE, DELETE ON system_package2 TO manager;
GRANT SELECT, UPDATE, DELETE ON system_package2 TO vmaas_sync;

SELECT create_table_partitions('system_package2', 128,
                               $$WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')$$);

-- package_account_data
CREATE TABLE IF NOT EXISTS package_account_data
(
    package_name_id          BIGINT NOT NULL,
    rh_account_id            INT NOT NULL,
    systems_installed        INT NOT NULL DEFAULT 0,
    systems_installable      INT NOT NULL DEFAULT 0,
    systems_applicable       INT NOT NULL DEFAULT 0,
    CONSTRAINT package_name_id
    FOREIGN KEY (package_name_id)
    REFERENCES package_name (id),
    CONSTRAINT rh_account_id
    FOREIGN KEY (rh_account_id)
    REFERENCES rh_account (id),
    UNIQUE (package_name_id, rh_account_id),
    PRIMARY KEY (rh_account_id, package_name_id)
    ) WITH (fillfactor = '70', autovacuum_vacuum_scale_factor = '0.05')
    TABLESPACE pg_default;

-- vmaas_sync user is used for admin api and for cronjobs, it needs to update counts
GRANT SELECT, INSERT, UPDATE, DELETE ON package_account_data TO vmaas_sync;

-- timestamp_kv
CREATE TABLE IF NOT EXISTS timestamp_kv
(
    name  TEXT                     NOT NULL UNIQUE,
    CHECK (NOT empty(name)),
    value TIMESTAMP WITH TIME ZONE NOT NULL
                        ) TABLESPACE pg_default;

GRANT SELECT, INSERT, UPDATE, DELETE ON timestamp_kv TO vmaas_sync;

-- vmaas_sync needs to delete from this tables to sync CVEs correctly
GRANT DELETE ON system_advisories TO vmaas_sync;
GRANT DELETE ON advisory_account_data TO vmaas_sync;

-- ----------------------------------------------------------------------------
-- Read access for all users
-- ----------------------------------------------------------------------------

-- user for evaluator component
GRANT SELECT ON ALL TABLES IN SCHEMA public TO evaluator;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO evaluator;

-- user for listener component
GRANT SELECT ON ALL TABLES IN SCHEMA public TO listener;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO listener;

-- user for UI manager component
GRANT SELECT ON ALL TABLES IN SCHEMA public TO manager;

-- user for VMaaS sync component
GRANT SELECT ON ALL TABLES IN SCHEMA public TO vmaas_sync;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vmaas_sync;
GRANT SELECT, UPDATE ON repo TO vmaas_sync;


CREATE SCHEMA IF NOT EXISTS inventory;

-- The admin ROLE that allows the inventory schema to be managed
DO $$
BEGIN
CREATE ROLE cyndi_admin;
EXCEPTION WHEN DUPLICATE_OBJECT THEN
    RAISE NOTICE 'cyndi_admin already exists';
END
$$;
GRANT ALL PRIVILEGES ON SCHEMA inventory TO cyndi_admin;

-- The reader ROLE that provides SELECT access to the inventory.hosts view
DO $$
BEGIN
CREATE ROLE cyndi_reader;
EXCEPTION WHEN DUPLICATE_OBJECT THEN
    RAISE NOTICE 'cyndi_reader already exists';
END
$$;

-- Create "inventory.hosts" for testing purposes. In deployment it's created by remote Cyndi service.
CREATE SCHEMA IF NOT EXISTS inventory;

DO
$$
BEGIN
        -- The admin ROLE that allows the inventory schema to be managed
CREATE ROLE cyndi_admin;
-- The reader ROLE that provides SELECT access to the inventory.hosts view
CREATE ROLE cyndi_reader;
EXCEPTION
        WHEN DUPLICATE_OBJECT THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS inventory.hosts_v1_0 (
                                                    id uuid PRIMARY KEY,
                                                    account character varying(10),
    display_name character varying(200) NOT NULL,
    tags jsonb NOT NULL,
    updated timestamp with time zone NOT NULL,
    created timestamp with time zone NOT NULL,
    stale_timestamp timestamp with time zone NOT NULL,
                                  system_profile jsonb NOT NULL,
                                  insights_id uuid,
                                  reporter character varying(255) NOT NULL,
    per_reporter_staleness jsonb NOT NULL,
    org_id character varying(36),
    groups jsonb
    );

DELETE FROM inventory.hosts_v1_0;

CREATE INDEX IF NOT EXISTS hosts_v1_0_tags_index ON inventory.hosts_v1_0 USING GIN (tags JSONB_PATH_OPS);
CREATE INDEX IF NOT EXISTS hosts_v1_0_insights_reporter_index ON inventory.hosts_v1_0 (reporter);
CREATE INDEX IF NOT EXISTS hosts_v1_0_stale_timestamp_index ON inventory.hosts_v1_0 USING btree (stale_timestamp);
CREATE INDEX IF NOT EXISTS hosts_v1_0_groups_index ON inventory.hosts_v1_0 USING GIN (groups JSONB_PATH_OPS);

CREATE OR REPLACE VIEW inventory.hosts AS SELECT
                                              id,
                                              account,
                                              display_name,
                                              created,
                                              updated,
                                              stale_timestamp,
                                              stale_timestamp + INTERVAL '1' DAY * '7'::double precision AS stale_warning_timestamp,
	stale_timestamp + INTERVAL '1' DAY * '14'::double precision AS culled_timestamp,
	tags,
	system_profile,
	insights_id,
	reporter,
	per_reporter_staleness,
	org_id,
	groups
                                          FROM inventory.hosts_v1_0;

GRANT SELECT ON TABLE inventory.hosts TO cyndi_reader;
GRANT USAGE ON SCHEMA inventory TO cyndi_reader;

-- The application user is granted the reader role only to eliminate any interference with Cyndi
GRANT cyndi_reader to listener;
GRANT cyndi_reader to evaluator;
GRANT cyndi_reader to manager;
GRANT cyndi_reader TO vmaas_sync;

GRANT cyndi_admin to cyndi;

DELETE FROM system_advisories;
DELETE FROM system_repo;
DELETE FROM system_package;
DELETE FROM system_package2;
DELETE FROM system_platform;
DELETE FROM deleted_system;
DELETE FROM repo;
DELETE FROM timestamp_kv;
DELETE FROM advisory_account_data;
DELETE FROM package_account_data;
DELETE FROM package;
DELETE FROM package_name;
DELETE FROM advisory_metadata;
DELETE FROM baseline;
DELETE FROM rh_account;
DELETE FROM strings;

INSERT INTO rh_account (id, name, org_id) VALUES
                                              (1, 'acc-1', 'org_1'), (2, 'acc-2', 'org_2'), (3, 'acc-3', 'org_3'), (4, 'acc-4', 'org_4');

INSERT INTO baseline (id, rh_account_id, name, config, description) VALUES
                                                                        (1, 1, 'baseline_1-1', '{"to_time": "2010-09-22T00:00:00+00:00"}', 'desc'),
                                                                        (2, 1, 'baseline_1-2', '{"to_time": "2021-01-01T00:00:00+00:00"}', NULL),
                                                                        (3, 1, 'baseline_1-3', '{"to_time": "2000-01-01T00:00:00+00:00"}', NULL),
                                                                        (4, 3, 'baseline_3-4', '{"to_time": "2000-01-01T00:00:00+00:00"}', NULL);

INSERT INTO system_platform (id, inventory_id, display_name, rh_account_id, reporter_id, vmaas_json, json_checksum, last_evaluation, last_upload, packages_installed, packages_updatable, third_party, baseline_id, baseline_uptodate) VALUES
                                                                                                                                                                                                                                           (1, '00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001', 1, 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2020-09-22 12:00:00-04',0,0, true, 1, true),
                                                                                                                                                                                                                                           (2, '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002', 1, 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-09-22 12:00:00-04',0,0, false, 1, true),
                                                                                                                                                                                                                                           (3, '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003', 1, 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-09-18 12:00:00-04',0,0, false, 2, false),
                                                                                                                                                                                                                                           (4, '00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000004', 1, 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-09-18 12:00:00-04',0,0, false, NULL, NULL),
                                                                                                                                                                                                                                           (5, '00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000005', 1, 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-09-18 12:00:00-04',0,0, false, NULL, NULL),
                                                                                                                                                                                                                                           (6, '00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000006', 1, 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04',0,0, false, NULL, NULL);

INSERT INTO system_platform (id, inventory_id, display_name, rh_account_id,  vmaas_json, json_checksum, last_updated, unchanged_since, last_upload, packages_installed, packages_updatable) VALUES
    (7, '00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000007', 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-10-04 14:13:12-04', '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04',0,0);

INSERT INTO system_platform (id, inventory_id, display_name, rh_account_id,  vmaas_json, json_checksum, last_evaluation, last_upload, packages_installed, packages_updatable) VALUES
                                                                                                                                                                                  (8, '00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000008', 1, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04',0,0),
                                                                                                                                                                                  (9, '00000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000009', 2, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04',0,0),
                                                                                                                                                                                  (10, '00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000010', 2, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04',0,0),
                                                                                                                                                                                  (11, '00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000011', 2, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04',0,0),
                                                                                                                                                                                  (12, '00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000012', 3, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04',2,2);

INSERT INTO system_platform (id, inventory_id, display_name, rh_account_id,  vmaas_json, json_checksum, last_evaluation, last_upload, packages_installed, packages_updatable, yum_updates) VALUES
                                                                                                                                                                                               (13, '00000000-0000-0000-0000-000000000013','00000000-0000-0000-0000-000000000013', 3, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04', 1,0, NULL),
                                                                                                                                                                                               (14, '00000000-0000-0000-0000-000000000014','00000000-0000-0000-0000-000000000014', 3, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04', 0,0, NULL),
                                                                                                                                                                                               (15, '00000000-0000-0000-0000-000000000015','00000000-0000-0000-0000-000000000015', 3, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04', 0,0,
                                                                                                                                                                                                '{"update_list": {"suricata-0:6.0.3-2.fc35.i686": {"available_updates": [{"erratum": "RHSA-2021:3801", "basearch": "i686", "releasever": "ser1", "repository": "group_oisf:suricata-6.0", "package": "suricata-0:6.0.4-2.fc35.i686"}]}}, "basearch": "i686", "releasever": "ser1"}');

INSERT INTO system_platform (id, inventory_id, display_name, rh_account_id,  vmaas_json, json_checksum, last_evaluation, last_upload, packages_installed, packages_updatable, yum_updates, baseline_id) VALUES
    (16, '00000000-0000-0000-0000-000000000016','00000000-0000-0000-0000-000000000016', 3, '{ "package_list": [ "kernel-2.6.32-696.20.1.el6.x86_64" ], "repository_list": [ "rhel-6-server-rpms" ] }', '1', '2018-09-22 12:00:00-04', '2018-01-22 12:00:00-04', 1,0, NULL, 4);

INSERT INTO advisory_metadata (id, name, description, synopsis, summary, solution, advisory_type_id,
                               public_date, modified_date, url, severity_id, cve_list, release_versions) VALUES
                                                                                                             (1, 'RH-1', 'adv-1-des', 'adv-1-syn', 'adv-1-sum', 'adv-1-sol', 1, '2016-09-22 12:00:00-04', '2017-09-22 12:00:00-04', 'url1', NULL, NULL, '["7.0","7Server"]'),
                                                                                                             (2, 'RH-2', 'adv-2-des', 'adv-2-syn', 'adv-2-sum', 'adv-2-sol', 2, '2016-09-22 12:00:00-04', '2017-09-22 12:00:00-04', 'url2', NULL, NULL, NULL),
                                                                                                             (3, 'RH-3', 'adv-3-des', 'adv-3-syn', 'adv-3-sum', 'adv-3-sol', 3, '2016-09-22 12:00:00-04', '2017-09-22 12:00:00-04', 'url3', 2, '["CVE-1","CVE-2"]', NULL),
                                                                                                             (4, 'RH-4', 'adv-4-des', 'adv-4-syn', 'adv-4-sum', 'adv-4-sol', 1, '2016-09-22 12:00:00-04', '2017-09-22 12:00:00-04', 'url4', NULL, NULL, '["8.0","8.1"]'),
                                                                                                             (5, 'RH-5', 'adv-5-des', 'adv-5-syn', 'adv-5-sum', 'adv-5-sol', 2, '2016-09-22 12:00:00-05', '2017-09-22 12:00:00-05', 'url5', NULL, NULL, '["8.0"]'),
                                                                                                             (6, 'RH-6', 'adv-6-des', 'adv-6-syn', 'adv-6-sum', 'adv-6-sol', 3, '2016-09-22 12:00:00-06', '2017-09-22 12:00:00-06', 'url6', 4, '["CVE-2","CVE-3"]', NULL),
                                                                                                             (7, 'RH-7', 'adv-7-des', 'adv-7-syn', 'adv-7-sum', 'adv-7-sol', 1, '2017-09-22 12:00:00-07', '2017-09-22 12:00:00-07', 'url7', NULL, NULL, NULL),
                                                                                                             (8, 'RH-8', 'adv-8-des', 'adv-8-syn', 'adv-8-sum', 'adv-8-sol', 2, '2016-09-22 12:00:00-08', '2018-09-22 12:00:00-08', 'url8', NULL, NULL, NULL),
                                                                                                             (9, 'RH-9', 'adv-9-des', 'adv-9-syn', 'adv-9-sum', 'adv-9-sol', 3, '2016-09-22 12:00:00-08', '2018-09-22 12:00:00-08', 'url9', NULL, '["CVE-4"]', '["8.2","8.4"]'),
                                                                                                             (10, 'UNSPEC-10', 'adv-10-des', 'adv-10-syn', 'adv-10-sum', 'adv-10-sol', 4, '2016-09-22 12:00:00-08', '2018-09-22 12:00:00-08', 'url10', NULL, NULL, NULL),
                                                                                                             (11, 'UNSPEC-11', 'adv-11-des', 'adv-11-syn', 'adv-11-sum', 'adv-11-sol', 4, '2016-09-22 12:00:00-08', '2018-09-22 12:00:00-08', 'url11', NULL, NULL, NULL),
                                                                                                             (12, 'CUSTOM-12', 'adv-12-des', 'adv-12-syn', 'adv-12-sum', 'adv-12-sol', 0, '2016-09-22 12:00:00-08', '2018-09-22 12:00:00-08', 'url12', NULL, NULL, NULL),
                                                                                                             (13, 'CUSTOM-13', 'adv-13-des', 'adv-13-syn', 'adv-13-sum', 'adv-13-sol', 0, '2016-09-22 12:00:00-08', '2018-09-22 12:00:00-08', 'url13', NULL, NULL, NULL);

INSERT INTO advisory_metadata (id, name, description, synopsis, summary, solution, advisory_type_id,
                               public_date, modified_date, url, severity_id, cve_list, release_versions, synced) VALUES
    (14, 'RHSA-2021:3801', 'adv-14-des', 'adv-14-syn', 'adv-14-sum', 'adv-14-sol', 3, '2016-09-22 12:00:00-04', '2017-09-22 12:00:00-04', 'url14', NULL, NULL, '["7.0","ser1"]', true);

UPDATE advisory_metadata SET package_data = '["firefox-77.0.1-1.fc31.x86_64", "firefox-77.0.1-1.fc31.s390"]' WHERE name = 'RH-9';

INSERT INTO system_advisories (rh_account_id, system_id, advisory_id, first_reported, status_id) VALUES
                                                                                                     (1, 1, 1, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 1, 2, '2016-09-22 12:00:00-04', 1),
                                                                                                     (1, 1, 3, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 1, 4, '2016-09-22 12:00:00-04', 1),
                                                                                                     (1, 1, 5, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 1, 6, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 1, 7, '2016-09-22 12:00:00-04', 1),
                                                                                                     (1, 1, 8, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 2, 1, '2016-09-22 12:00:00-04', 1),
                                                                                                     (1, 3, 1, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 4, 1, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 5, 1, '2016-09-22 12:00:00-04', 1),
                                                                                                     (1, 6, 1, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 8, 10, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 8, 11, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 8, 12, '2016-09-22 12:00:00-04', 0),
                                                                                                     (1, 8, 13, '2016-09-22 12:00:00-04', 0),
                                                                                                     (2, 10, 1, '2016-09-22 12:00:00-04', 1),
                                                                                                     (2, 11, 1, '2016-09-22 12:00:00-04', 0);

INSERT INTO repo (id, name, third_party) VALUES
                                             (1, 'repo1', false),
                                             (2, 'repo2', false),
                                             (3, 'repo3', false),
-- repo4 is not in platform mock for a purpose
                                             (4, 'repo4', true);

INSERT INTO system_repo (rh_account_id, system_id, repo_id) VALUES
                                                                (1, 2, 1),
                                                                (1, 3, 1),
                                                                (1, 2, 2);


INSERT INTO package_name(id, name, summary) VALUES
                                                (101, 'kernel', 'The Linux kernel'),
                                                (102, 'firefox', 'Mozilla Firefox Web browser'),
                                                (103, 'bash', 'The GNU Bourne Again shell'),
                                                (104, 'curl', 'A utility for getting files from remote servers...'),
                                                (105, 'tar', 'tar summary'),
                                                (106, 'systemd', 'systemd summary'),
                                                (107, 'sed', 'sed summary'),
                                                (108, 'grep', 'grep summary'),
                                                (109, 'which', 'which summary'),
                                                (110, 'passwd', 'passwd summary');

INSERT INTO strings(id, value) VALUES
                                   ('1', 'The Linux kernel'), -- kernel summary
                                   ('11', 'The kernel meta package'), -- kernel description
                                   ('2', 'Mozilla Firefox Web browser'), -- firefox summary
                                   ('22', 'Mozilla Firefox is an open-source web browser...'), -- firefox description
                                   ('3', 'The GNU Bourne Again shell'), -- bash summary
                                   ('33', 'The GNU Bourne Again shell (Bash) is a shell...'), -- bash description
                                   ('4', 'A utility for getting files from remote servers...'), -- curl summary
                                   ('44', 'curl is a command line tool for transferring data...'), -- curl description
                                   ('5', 'A GNU file archiving program'), -- tar summary
                                   ('55', 'The GNU tar program saves many files together in one archive...'), -- tar description
                                   ('6', 'System and Service Manager'), -- systemd summary
                                   ('66', 'systemd is a system and service manager that runs as PID 1...'), -- systemd description
                                   ('7', 'A GNU stream text editor'), -- sed summary
                                   ('77', 'The sed (Stream EDitor) editor is a stream or batch...'), -- sed description
                                   ('8', 'Pattern matching utilities'), -- grep summary
                                   ('88', 'The GNU versions of commonly used grep utilities...'), -- grep description
                                   ('9', 'Displays where a particular program in your path is located'), -- which summary
                                   ('99', 'The which command shows the full pathname of a specific program...'), -- which description
                                   ('10', 'An utility for setting or changing passwords using PAM'), -- passwd summary
                                   ('1010', 'This package contains a system utility (passwd) which sets...'); -- passwd description

INSERT INTO package(id, name_id, evra, description_hash, summary_hash, advisory_id, synced) VALUES
                                                                                                (1, 101, '5.6.13-200.fc31.x86_64', '11', '1', 1, true), -- kernel
                                                                                                (2, 102, '76.0.1-1.fc31.x86_64', '22', '2', 1, true), -- firefox
                                                                                                (3, 103, '4.4.19-8.el8_0.x86_64', '33', '3', 3, true), -- bash
                                                                                                (4, 104, '7.61.1-8.el8.x86_64', '44', '4', 4, true), -- curl
                                                                                                (5, 105, '1.30-4.el8.x86_64', '55', '5', 5, true), -- tar
                                                                                                (6, 106, '239-13.el8_0.5.x86_64', '66', '6', 6, true), -- systemd
                                                                                                (7, 107, '4.5-1.el8.x86_64', '77', '7', 7, true), -- sed
                                                                                                (8, 108, '3.1-6.el8.x86_64', '88', '8', 8, true), -- grep
                                                                                                (9, 109, '2.21-10.el8.x86_64', '99', '9', 9, true), -- which
                                                                                                (10, 110, '0.80-2.el8.x86_64', '1010', '10', 9, true), -- passwd
                                                                                                (11, 101, '5.6.13-201.fc31.x86_64', '11', '1', 7, true), -- kernel
                                                                                                (12, 102, '76.0.1-2.fc31.x86_64', '22', '2', null, true), -- firefox
                                                                                                (13, 102, '77.0.1-1.fc31.x86_64', '22', '2', null, true); -- firefox

INSERT INTO system_package (rh_account_id, system_id, package_id, name_id, update_data) VALUES
                                                                                            (3, 12, 1, 101, '[{"evra": "5.10.13-201.fc31.x86_64", "advisory": "RH-100", "status": "Installable"}]'),
                                                                                            (3, 12, 2, 102, '[{"evra": "77.0.1-1.fc31.x86_64", "advisory": "RH-1", "status": "Installable"}, {"evra": "76.0.1-2.fc31.x86_64", "advisory": "RH-2", "status": "Installable"}]'),
                                                                                            (3, 13, 1, 101, null),
                                                                                            (3, 13, 2, 102, '[{"evra": "76.0.1-2.fc31.x86_64", "advisory": "RH-2", "status": "Installable"},{"evra": "77.0.1-1.fc31.x86_64", "advisory": "RH-1", "status": "Applicable"}]'),
                                                                                            (3, 13, 3, 103, null),
                                                                                            (3, 13, 4, 104, null),
                                                                                            (3, 16, 1, 101, '[{"evra": "5.10.13-201.fc31.x86_64", "advisory": "RH-100", "status": "Installable"}]');

INSERT INTO system_package2 (rh_account_id, system_id, name_id, package_id, installable_id, applicable_id) VALUES
                                                                                                               (3, 12, 101, 1, 11, null),
                                                                                                               (3, 12, 102, 2, 12, null),
                                                                                                               (3, 13, 101, 1, null, null),
                                                                                                               (3, 13, 102, 2, 12, 13),
                                                                                                               (3, 13, 103, 3, null, null),
                                                                                                               (3, 13, 104, 4, null, null),
                                                                                                               (3, 16, 101, 1, 11, 11);

INSERT INTO timestamp_kv (name, value) VALUES
    ('last_eval_repo_based', '2018-04-05T01:23:45+02:00');

INSERT INTO inventory.hosts_v1_0 (id, insights_id, account, display_name, tags, updated, created, stale_timestamp, system_profile, reporter, per_reporter_staleness, org_id, groups) VALUES
                                                                                                                                                                                         ('00000000000000000000000000000001', '00000000-0000-0000-0001-000000000001', '1', '00000000-0000-0000-0000-000000000001', '[{"key": "k1", "value": "val1", "namespace": "ns1"},{"key": "k2", "value": "val2", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "sap_sids": ["ABC", "DEF", "GHI"], "operating_system": {"name": "RHEL", "major": 8, "minor": 10}, "rhsm": {"version": "8.10"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-1", "name": "group1"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000002', '00000000-0000-0000-0002-000000000001', '1', '00000000-0000-0000-0000-000000000002', '[{"key": "k1", "value": "val1", "namespace": "ns1"},{"key": "k2", "value": "val2", "namespace": "ns1"},{"key": "k3", "value": "val3", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "sap_sids": ["ABC"], "operating_system": {"name": "RHEL", "major": 8, "minor": 1}, "rhsm": {"version": "8.1"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-1", "name": "group1"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000003', '00000000-0000-0000-0003-000000000001', '1', '00000000-0000-0000-0000-000000000003', '[{"key": "k1", "value": "val1", "namespace": "ns1"}, {"key": "k3", "value": "val4", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 1}, "rhsm": {"version": "8.0"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-1", "name": "group1"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000004', '00000000-0000-0000-0004-000000000001', '1', '00000000-0000-0000-0000-000000000004', '[{"key": "k3", "value": "val4", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 2}, "rhsm": {"version": "8.3"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-1", "name": "group1"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000005', '00000000-0000-0000-0005-000000000001', '1', '00000000-0000-0000-0000-000000000005', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 3}, "rhsm": {"version": "8.3"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-1", "name": "group1"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000006', '00000000-0000-0000-0006-000000000001', '1', '00000000-0000-0000-0000-000000000006', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 7, "minor": 3}, "rhsm": {"version": "7.3"}, "mssql": { "version": "15.3.0"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-1", "name": "group1"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000007', '00000000-0000-0000-0007-000000000001', '1', '00000000-0000-0000-0000-000000000007','[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": "x"}, "rhsm": {"version": "8.x"}, "ansible": {"controller_version": "1.0"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-2", "name": "group2"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000008', '00000000-0000-0000-0008-000000000001', '1', '00000000-0000-0000-0000-000000000008', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 3}, "rhsm": {"version": "8.3"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_1', '[{"id": "inventory-group-2", "name": "group2"}]'),
                                                                                                                                                                                         ('00000000000000000000000000000009', '00000000-0000-0000-0009-000000000001', '2', '00000000-0000-0000-0000-000000000009', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 1}, "rhsm": {"version": "8.1"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_2', NULL),
                                                                                                                                                                                         ('00000000000000000000000000000010', '00000000-0000-0000-0010-000000000001', '2', '00000000-0000-0000-0000-000000000010', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 2}, "rhsm": {"version": "8.2"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_2', NULL),
                                                                                                                                                                                         ('00000000000000000000000000000011', '00000000-0000-0000-0011-000000000001', '2', '00000000-0000-0000-0000-000000000011', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 3}, "rhsm": {"version": "8.3"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_2', '[]'),
                                                                                                                                                                                         ('00000000000000000000000000000012', '00000000-0000-0000-0012-000000000001', '3', '00000000-0000-0000-0000-000000000012', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 1}, "rhsm": {"version": "8.1"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_3', '[]'),
                                                                                                                                                                                         ('00000000000000000000000000000013', '00000000-0000-0000-0013-000000000001', '3', '00000000-0000-0000-0000-000000000013', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 2}, "rhsm": {"version": "8.2"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_3', '[]'),
                                                                                                                                                                                         ('00000000000000000000000000000014', '00000000-0000-0000-0014-000000000001', '3', '00000000-0000-0000-0000-000000000014', '[{"key": "k1", "value": "val1", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": true, "operating_system": {"name": "RHEL", "major": 8, "minor": 3}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_3', '[]'),
                                                                                                                                                                                         ('00000000000000000000000000000015', '00000000-0000-0000-0015-000000000001', '3', '00000000-0000-0000-0000-000000000015', '[{"key": "k3", "value": "val4", "namespace": "ns1"}]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": false, "operating_system": {"name": "RHEL", "major": 8, "minor": 1}, "rhsm": {"version": "8.1"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_3', '[]'),
                                                                                                                                                                                         ('00000000000000000000000000000016', '00000000-0000-0000-0016-000000000001', '3', '00000000-0000-0000-0000-000000000016', '[]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04', '{"sap_system": false, "operating_system": {"name": "RHEL", "major": 8, "minor": 2}, "rhsm": {"version": "8.2"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_3', '[]'),
                                                                                                                                                                                         ('00000000000000000000000000000017', '00000000-0000-0000-0017-000000000001', '3', '00000000-0000-0000-0000-000000000017', '[]',
                                                                                                                                                                                          '2018-09-22 12:00:00-04', '2018-08-26 12:00:00-04', '2018-08-26 12:00:00-04',
                                                                                                                                                                                          '{"rhsm": {"version": "8.1"}, "operating_system": {"name": "RHEL", "major": 8, "minor": 1}, "ansible": {"controller_version": "1.0", "hub_version": "3.4.1", "catalog_worker_version": "100.387.9846.12", "sso_version": "1.28.3.52641.10000513168495123"}, "mssql": { "version": "15.3.0"}}',
                                                                                                                                                                                          'puptoo', '{}', 'org_3', '[]');

SELECT refresh_all_cached_counts();

ALTER TABLE advisory_metadata ALTER COLUMN id RESTART WITH 100;
ALTER TABLE system_platform ALTER COLUMN id RESTART WITH 100;
ALTER TABLE rh_account ALTER COLUMN id RESTART WITH 100;
ALTER TABLE repo ALTER COLUMN id RESTART WITH 100;
ALTER TABLE package ALTER COLUMN id RESTART WITH 100;
ALTER TABLE package_name ALTER COLUMN id RESTART WITH 150;
ALTER TABLE baseline ALTER COLUMN id RESTART WITH 100;