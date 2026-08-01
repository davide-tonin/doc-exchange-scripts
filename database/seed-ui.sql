/*
 * Deterministic, production-shaped UI data for the local development database.
 *
 * Seeded application tenants: 80 (the migration-owned system tenant is untouched).
 * Playground totals:
 *   UI Playground 01 - Large   identities=99, identity_shares=99, povs=99, groups=99
 *   UI Playground 02 - Medium  identities=24, identity_shares=24, povs=24, groups=24
 *   UI Playground 03 - Small   identities=1,  identity_shares=1,  povs=1,  groups=1
 *
 * The script is additive and rerunnable. Its deterministic request ids and names keep
 * it from duplicating seed-owned rows. Everything runs in one transaction, so a failure
 * leaves no partial fixture graph.
 */

BEGIN;

SELECT pg_advisory_xact_lock(hashtext('doc-exchange-ui-seed-v1'));

/*
 * The normal Flyway login owns the tables but does not bypass forced RLS. The
 * migration-owned tenant_bootstrap_role does bypass RLS and already has the broad
 * bootstrap graph grants. Temporarily add only the two missing fixture-table grants,
 * remember exactly what was added, and remove them before commit. Running as postgres
 * follows the same path, so Docker and host/Flyway execution exercise identical SQL.
 */
CREATE TEMP TABLE ui_seed_added_grant (
    object_name TEXT NOT NULL,
    privilege_name TEXT NOT NULL,
    PRIMARY KEY (object_name, privilege_name)
) ON COMMIT DROP;

DO $seed$
DECLARE
    target_table TEXT;
    target_privilege TEXT;
BEGIN
    IF NOT pg_has_role(CURRENT_USER, 'tenant_bootstrap_role', 'MEMBER') THEN
        RAISE EXCEPTION
            'UI seed login % must be a member of tenant_bootstrap_role',
            CURRENT_USER;
    END IF;

    FOREACH target_table IN ARRAY ARRAY[
        'de_schema.group',
        'de_schema.identity_share'
    ] LOOP
        FOREACH target_privilege IN ARRAY ARRAY['SELECT', 'INSERT'] LOOP
            IF NOT has_table_privilege(
                'tenant_bootstrap_role',
                target_table,
                target_privilege
            ) THEN
                EXECUTE format(
                    'GRANT %s ON TABLE %s TO tenant_bootstrap_role',
                    target_privilege,
                    target_table
                );
                INSERT INTO ui_seed_added_grant (object_name, privilege_name)
                VALUES (target_table, target_privilege);
            END IF;
        END LOOP;
    END LOOP;
END
$seed$;

SET LOCAL ROLE tenant_bootstrap_role;

DO $seed$
DECLARE
    fixture_number INT;
    fixture_request_id UUID;
    fixture_tenant_id INT;
    fixture_display_name TEXT;
    fixture_email TEXT;
    fixture_alias TEXT;
BEGIN
    IF to_regprocedure(
            'de_schema.fn_tenant_bootstrap(integer,character,text,text,bytea,text,uuid,bigint,bigint)'
       ) IS NULL THEN
        RAISE EXCEPTION
            'Database schema is not migrated: de_schema.fn_tenant_bootstrap(...) is missing';
    END IF;

    FOR fixture_number IN 1..80 LOOP
        fixture_request_id := (
            'd0ce0000-0000-4000-8000-' || lpad(fixture_number::TEXT, 12, '0')
        )::UUID;

        SELECT id
        INTO fixture_tenant_id
        FROM de_schema.tenant
        WHERE created_by_req_id = fixture_request_id;

        IF fixture_tenant_id IS NULL THEN
            fixture_display_name := CASE fixture_number
                WHEN 1 THEN 'UI Playground 01 - Large (99)'
                WHEN 2 THEN 'UI Playground 02 - Medium (24)'
                WHEN 3 THEN 'UI Playground 03 - Small (1)'
                ELSE format('UI Fixture Tenant %s', lpad(fixture_number::TEXT, 2, '0'))
            END;
            fixture_email := format(
                'ui.seed.%s@example.test',
                lpad(fixture_number::TEXT, 2, '0')
            );
            fixture_alias := (
                'd0ce1000-0000-4000-8000-' || lpad(fixture_number::TEXT, 12, '0')
            )::UUID::TEXT;

            SELECT de_schema.fn_tenant_reserve(fixture_request_id)
            INTO fixture_tenant_id;

            PERFORM de_schema.fn_tenant_bootstrap(
                fixture_tenant_id,
                CASE
                    WHEN fixture_number % 5 = 0 THEN 'GO'
                    WHEN fixture_number % 7 = 0 THEN 'US'
                    ELSE 'CO'
                END::CHAR(2),
                fixture_display_name,
                fixture_email,
                /*
                 * A unique 32-byte placeholder satisfies the persisted lookup-key shape.
                 * It deliberately does not pretend to be derived from the running app's
                 * secret material; see docs/UI_SEED.md.
                 */
                decode(
                    md5('ui-seed:' || fixture_email)
                    || md5('ui-seed:lookup:' || fixture_email),
                    'hex'
                ),
                fixture_alias,
                fixture_request_id,
                262143,
                196608
            );
        END IF;
    END LOOP;
END
$seed$;

CREATE TEMP TABLE ui_seed_playground (
    ordinal INT PRIMARY KEY,
    tenant_id INT NOT NULL,
    desired_count INT NOT NULL,
    size_name TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO ui_seed_playground (ordinal, tenant_id, desired_count, size_name)
SELECT spec.ordinal, tenant.id, spec.desired_count, spec.size_name
FROM (
    VALUES
        (1, 99, 'large'),
        (2, 24, 'medium'),
        (3, 1,  'small')
) AS spec(ordinal, desired_count, size_name)
JOIN de_schema.tenant tenant
  ON tenant.created_by_req_id = (
      'd0ce0000-0000-4000-8000-' || lpad(spec.ordinal::TEXT, 12, '0')
  )::UUID;

DO $seed$
BEGIN
    IF (SELECT COUNT(*) FROM ui_seed_playground) <> 3 THEN
        RAISE EXCEPTION 'Expected all three UI playground tenants to exist';
    END IF;
END
$seed$;

/*
 * Top up identities. The bootstrap identity is row 1; every generated identity has
 * no credential lookup key, which is a valid "credentials not configured" state.
 * The mixture exercises human/service, username-password/API-key/OAuth2, and enabled/
 * disabled presentation.
 */
WITH actor AS (
    SELECT playground.tenant_id, MIN(identity.version_id) AS actor_vid
    FROM ui_seed_playground playground
    JOIN de_schema.identity identity
      ON identity.tenant_id = playground.tenant_id
     AND identity.is_latest = TRUE
     AND identity.deleted_at IS NULL
    GROUP BY playground.tenant_id
),
targets AS (
    SELECT
        playground.tenant_id,
        playground.size_name,
        actor.actor_vid,
        generated.number
    FROM ui_seed_playground playground
    JOIN actor USING (tenant_id)
    CROSS JOIN LATERAL generate_series(2, playground.desired_count) generated(number)
)
INSERT INTO de_schema.identity (
    created_by,
    tenant_id,
    version,
    is_latest,
    auth_type,
    status,
    type,
    lookup_key,
    email,
    display_name,
    expires_at
)
SELECT
    targets.actor_vid,
    targets.tenant_id,
    1,
    TRUE,
    CASE
        WHEN targets.number % 7 = 0 THEN 'AK'
        WHEN targets.number % 5 = 0 THEN 'O2'
        ELSE 'UP'
    END,
    CASE WHEN targets.number % 11 = 0 THEN 'DI' ELSE 'EN' END,
    CASE WHEN targets.number % 7 = 0 THEN 'SV' ELSE 'HU' END,
    NULL,
    CASE
        WHEN targets.number % 7 = 0 THEN NULL
        ELSE format(
            'ui.%s.identity.%s@example.test',
            targets.size_name,
            lpad(targets.number::TEXT, 3, '0')
        )
    END,
    format(
        'UI %s identity %s',
        initcap(targets.size_name),
        lpad(targets.number::TEXT, 3, '0')
    ),
    CASE
        WHEN targets.number % 13 = 0 THEN NOW() - INTERVAL '1 day'
        WHEN targets.number % 9 = 0 THEN NOW() + INTERVAL '30 days'
        ELSE NULL
    END
FROM targets
WHERE NOT EXISTS (
    SELECT 1
    FROM de_schema.identity existing
    WHERE existing.tenant_id = targets.tenant_id
      AND existing.is_latest = TRUE
      AND existing.deleted_at IS NULL
      AND LOWER(existing.display_name) = LOWER(format(
          'UI %s identity %s',
          initcap(targets.size_name),
          lpad(targets.number::TEXT, 3, '0')
      ))
);

/* Top up POV totals (the bootstrap graph already contributes "Sent documents"). */
WITH actor AS (
    SELECT playground.tenant_id, MIN(identity.version_id) AS actor_vid
    FROM ui_seed_playground playground
    JOIN de_schema.identity identity
      ON identity.tenant_id = playground.tenant_id
     AND identity.is_latest = TRUE
     AND identity.deleted_at IS NULL
    GROUP BY playground.tenant_id
),
targets AS (
    SELECT
        playground.tenant_id,
        playground.size_name,
        actor.actor_vid,
        generated.number
    FROM ui_seed_playground playground
    JOIN actor USING (tenant_id)
    CROSS JOIN LATERAL generate_series(2, playground.desired_count) generated(number)
)
INSERT INTO de_schema.pov (
    created_by,
    tenant_id,
    version,
    is_latest,
    from_dt,
    to_dt,
    tenant_role,
    display_name,
    json_filters,
    b_filters,
    description
)
SELECT
    targets.actor_vid,
    targets.tenant_id,
    1,
    TRUE,
    TIMESTAMPTZ '2020-01-01T00:00:00Z' + (targets.number * INTERVAL '1 day'),
    TIMESTAMPTZ '2199-12-31T23:59:59Z',
    ((targets.number - 1) % 3) + 1,
    format(
        'UI %s POV %s',
        initcap(targets.size_name),
        lpad(targets.number::TEXT, 3, '0')
    ),
    '{"and":[]}'::JSONB,
    '\x010100'::BYTEA,
    format('Pagination fixture POV %s', targets.number)
FROM targets
WHERE NOT EXISTS (
    SELECT 1
    FROM de_schema.pov existing
    WHERE existing.tenant_id = targets.tenant_id
      AND existing.is_latest = TRUE
      AND existing.deleted_at IS NULL
      AND LOWER(existing.display_name) = LOWER(format(
          'UI %s POV %s',
          initcap(targets.size_name),
          lpad(targets.number::TEXT, 3, '0')
      ))
);

/*
 * Groups contain one real local identity stable id. PostgreSQL int8send emits the
 * same canonical 8-byte big-endian anchor used by NumberListCompressor for a
 * one-member list, so API deserialization remains production-valid.
 */
WITH identities AS (
    SELECT
        playground.tenant_id,
        identity.stable_id,
        identity.version_id,
        row_number() OVER (
            PARTITION BY playground.tenant_id
            ORDER BY LOWER(identity.display_name), identity.stable_id
        ) AS identity_number,
        count(*) OVER (PARTITION BY playground.tenant_id) AS identity_count
    FROM ui_seed_playground playground
    JOIN de_schema.identity identity
      ON identity.tenant_id = playground.tenant_id
     AND identity.is_latest = TRUE
     AND identity.deleted_at IS NULL
),
actor AS (
    SELECT tenant_id, MIN(version_id) AS actor_vid
    FROM identities
    GROUP BY tenant_id
),
targets AS (
    SELECT
        playground.tenant_id,
        playground.size_name,
        playground.desired_count,
        actor.actor_vid,
        generated.number
    FROM ui_seed_playground playground
    JOIN actor USING (tenant_id)
    CROSS JOIN LATERAL generate_series(1, playground.desired_count) generated(number)
)
INSERT INTO de_schema.group (
    created_by,
    tenant_id,
    version,
    is_latest,
    entity_id,
    compressed_ids,
    display_name,
    description
)
SELECT
    targets.actor_vid,
    targets.tenant_id,
    1,
    TRUE,
    5,
    pg_catalog.int8send(member.stable_id),
    format(
        'UI %s group %s',
        initcap(targets.size_name),
        lpad(targets.number::TEXT, 3, '0')
    ),
    format('Contains identity %s', member.stable_id)
FROM targets
JOIN identities member
  ON member.tenant_id = targets.tenant_id
 AND member.identity_number = ((targets.number - 1) % member.identity_count) + 1
WHERE NOT EXISTS (
    SELECT 1
    FROM de_schema.group existing
    WHERE existing.tenant_id = targets.tenant_id
      AND existing.is_latest = TRUE
      AND existing.deleted_at IS NULL
      AND LOWER(existing.display_name) = LOWER(format(
          'UI %s group %s',
          initcap(targets.size_name),
          lpad(targets.number::TEXT, 3, '0')
      ))
);

/*
 * One share per selected local identity, pointed at another seeded tenant. The state
 * mix includes live, disabled, expired, single-use available, and single-use spent.
 */
WITH seeded_tenants AS (
    SELECT
        tenant.id,
        row_number() OVER (ORDER BY tenant.created_by_req_id) AS tenant_number,
        count(*) OVER () AS tenant_count
    FROM de_schema.tenant tenant
    WHERE tenant.created_by_req_id::TEXT LIKE 'd0ce0000-0000-4000-8000-%'
),
identities AS (
    SELECT
        playground.tenant_id,
        identity.stable_id,
        identity.version_id,
        row_number() OVER (
            PARTITION BY playground.tenant_id
            ORDER BY LOWER(identity.display_name), identity.stable_id
        ) AS identity_number
    FROM ui_seed_playground playground
    JOIN de_schema.identity identity
      ON identity.tenant_id = playground.tenant_id
     AND identity.is_latest = TRUE
     AND identity.deleted_at IS NULL
),
actor AS (
    SELECT tenant_id, MIN(version_id) AS actor_vid
    FROM identities
    GROUP BY tenant_id
),
targets AS (
    SELECT
        playground.tenant_id,
        playground.desired_count,
        actor.actor_vid,
        identities.stable_id AS identity_sid,
        identities.identity_number
    FROM ui_seed_playground playground
    JOIN actor USING (tenant_id)
    JOIN identities USING (tenant_id)
    WHERE identities.identity_number <= playground.desired_count
),
with_grantor AS (
    SELECT
        targets.*,
        grantor.id AS grantor_id
    FROM targets
    JOIN seeded_tenants owner ON owner.id = targets.tenant_id
    JOIN seeded_tenants grantor
      ON grantor.tenant_number = (
          (
              owner.tenant_number
              + ((targets.identity_number - 1) % (owner.tenant_count - 1))
          ) % owner.tenant_count
      ) + 1
)
INSERT INTO de_schema.identity_share (
    created_by,
    grantee_id,
    identity_sid,
    grantor_id,
    allow_roles,
    allow_povs,
    single_use,
    used_by,
    used_by_request_id,
    expires_at,
    status,
    version,
    is_latest
)
SELECT
    target.actor_vid,
    target.tenant_id,
    target.identity_sid,
    target.grantor_id,
    target.identity_number % 3 <> 0,
    target.identity_number % 3 <> 1,
    target.identity_number % 5 = 0,
    CASE WHEN target.identity_number % 10 = 5 THEN target.actor_vid ELSE NULL END,
    CASE
        WHEN target.identity_number % 10 = 5
        THEN (
            'd0ce2000-0000-4000-8000-'
            || lpad((target.tenant_id * 1000 + target.identity_number)::TEXT, 12, '0')
        )::UUID
        ELSE NULL
    END,
    CASE
        WHEN target.identity_number % 10 = 1 THEN NOW() - INTERVAL '1 day'
        ELSE NOW() + INTERVAL '1 year'
    END,
    CASE WHEN target.identity_number % 10 = 0 THEN 'DI' ELSE 'EN' END,
    1,
    TRUE
FROM with_grantor target
WHERE NOT EXISTS (
    SELECT 1
    FROM de_schema.identity_share existing
    WHERE existing.grantee_id = target.tenant_id
      AND existing.identity_sid = target.identity_sid
      AND existing.grantor_id = target.grantor_id
      AND existing.is_latest = TRUE
);

/* Multiple coherent aliases per playground, including lifecycle-state variety. */
CREATE TEMP TABLE ui_seed_alias_spec (
    tenant_id INT NOT NULL,
    type CHAR(2) NOT NULL,
    status CHAR(2) NOT NULL,
    value TEXT NOT NULL,
    normalized TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO ui_seed_alias_spec (tenant_id, type, status, value, normalized)
SELECT
    playground.tenant_id,
    alias_spec.type::CHAR(2),
    alias_spec.status::CHAR(2),
    replace(alias_spec.value_pattern, '{size}', playground.size_name),
    LOWER(replace(alias_spec.value_pattern, '{size}', playground.size_name))
FROM ui_seed_playground playground
CROSS JOIN (
    VALUES
        ('RA', 'PB', 'ui-{size}-shortcut'),
        ('EM', 'RQ', 'requested.{size}@example.test'),
        ('EM', 'VR', 'verified.{size}@example.test'),
        ('EM', 'PB', 'published.{size}@example.test'),
        ('VA', 'PB', 'IT-UI-{size}-0001')
) AS alias_spec(type, status, value_pattern);

INSERT INTO de_schema.alias_registry (type, normalized, tenant_id, status)
SELECT spec.type, spec.normalized, spec.tenant_id, 'EN'
FROM ui_seed_alias_spec spec
ON CONFLICT DO NOTHING;

WITH actor AS (
    SELECT playground.tenant_id, MIN(identity.version_id) AS actor_vid
    FROM ui_seed_playground playground
    JOIN de_schema.identity identity
      ON identity.tenant_id = playground.tenant_id
     AND identity.is_latest = TRUE
     AND identity.deleted_at IS NULL
    GROUP BY playground.tenant_id
)
INSERT INTO de_schema.alias (
    stable_id,
    tenant_id,
    created_by,
    version,
    is_latest,
    type,
    status,
    verification_mode,
    value,
    normalized,
    verification_expires_at,
    requested_at,
    verified_at,
    published_at,
    notes
)
SELECT
    registry.alias_id,
    spec.tenant_id,
    actor.actor_vid,
    1,
    TRUE,
    spec.type,
    spec.status,
    CASE WHEN spec.type IN ('EM', 'VA') THEN 'OT' ELSE NULL END,
    spec.value,
    spec.normalized,
    CASE WHEN spec.type IN ('EM', 'VA') THEN NOW() + INTERVAL '30 days' ELSE NULL END,
    CASE WHEN spec.type IN ('EM', 'VA') THEN NOW() - INTERVAL '2 days' ELSE NULL END,
    CASE WHEN spec.status IN ('VR', 'PB') THEN NOW() - INTERVAL '1 day' ELSE NULL END,
    CASE WHEN spec.status = 'PB' THEN NOW() ELSE NULL END,
    jsonb_build_array(jsonb_build_object(
        'at', NOW(),
        'text', 'Created by deterministic UI seed',
        'by_identity_vid', actor.actor_vid
    ))
FROM ui_seed_alias_spec spec
JOIN actor USING (tenant_id)
JOIN de_schema.alias_registry registry
  ON registry.type = spec.type
 AND registry.normalized = spec.normalized
 AND registry.status = 'EN'
WHERE NOT EXISTS (
    SELECT 1
    FROM de_schema.alias existing
    WHERE existing.tenant_id = spec.tenant_id
      AND existing.type = spec.type
      AND existing.normalized = spec.normalized
      AND existing.is_latest = TRUE
);

DO $seed$
DECLARE
    mismatch RECORD;
BEGIN
    SELECT *
    INTO mismatch
    FROM (
        SELECT
            playground.size_name,
            playground.desired_count,
            (SELECT COUNT(*) FROM de_schema.identity i
             WHERE i.tenant_id = playground.tenant_id
               AND i.is_latest = TRUE AND i.deleted_at IS NULL) AS identities,
            (SELECT COUNT(*) FROM de_schema.identity_share s
             WHERE s.grantee_id = playground.tenant_id
               AND s.is_latest = TRUE) AS identity_shares,
            (SELECT COUNT(*) FROM de_schema.pov p
             WHERE p.tenant_id = playground.tenant_id
               AND p.is_latest = TRUE AND p.deleted_at IS NULL) AS povs,
            (SELECT COUNT(*) FROM de_schema.group g
             WHERE g.tenant_id = playground.tenant_id
               AND g.is_latest = TRUE AND g.deleted_at IS NULL) AS groups
        FROM ui_seed_playground playground
    ) counts
    WHERE counts.identities <> counts.desired_count
       OR counts.identity_shares <> counts.desired_count
       OR counts.povs <> counts.desired_count
       OR counts.groups <> counts.desired_count
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'UI seed count mismatch for %: wanted %, identities %, shares %, povs %, groups %',
            mismatch.size_name,
            mismatch.desired_count,
            mismatch.identities,
            mismatch.identity_shares,
            mismatch.povs,
            mismatch.groups;
    END IF;
END
$seed$;

SELECT
    tenant.id AS tenant_id,
    tenant.display_name_cache AS tenant,
    playground.desired_count AS expected_each,
    COUNT(DISTINCT identity.stable_id) FILTER (
        WHERE identity.is_latest = TRUE AND identity.deleted_at IS NULL
    ) AS identities,
    (SELECT COUNT(*) FROM de_schema.identity_share share
     WHERE share.grantee_id = tenant.id AND share.is_latest = TRUE) AS identity_shares,
    (SELECT COUNT(*) FROM de_schema.pov pov
     WHERE pov.tenant_id = tenant.id AND pov.is_latest = TRUE AND pov.deleted_at IS NULL) AS povs,
    (SELECT COUNT(*) FROM de_schema.group grouped
     WHERE grouped.tenant_id = tenant.id
       AND grouped.is_latest = TRUE AND grouped.deleted_at IS NULL) AS groups,
    (SELECT COUNT(*) FROM de_schema.alias alias
     WHERE alias.tenant_id = tenant.id AND alias.is_latest = TRUE) AS aliases
FROM ui_seed_playground playground
JOIN de_schema.tenant tenant ON tenant.id = playground.tenant_id
LEFT JOIN de_schema.identity identity ON identity.tenant_id = tenant.id
GROUP BY tenant.id, tenant.display_name_cache, playground.desired_count, playground.ordinal
ORDER BY playground.ordinal;

RESET ROLE;

DO $seed$
DECLARE
    added_grant RECORD;
BEGIN
    FOR added_grant IN
        SELECT object_name, privilege_name
        FROM ui_seed_added_grant
    LOOP
        EXECUTE format(
            'REVOKE %s ON TABLE %s FROM tenant_bootstrap_role',
            added_grant.privilege_name,
            added_grant.object_name
        );
    END LOOP;
END
$seed$;

COMMIT;
