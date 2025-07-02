-- Test core trigger functionality
SELECT plan(21);

-- Setup: Create test users and initial configuration
DO $$
BEGIN
    -- Insert test users if they don't exist
    INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    VALUES
        ('11111111-1111-1111-1111-111111111111'::uuid, 'test1@example.com', 'encrypted', NOW(), NOW(), NOW()),
        ('22222222-2222-2222-2222-222222222222'::uuid, 'test2@example.com', 'encrypted', NOW(), NOW(), NOW())
    ON CONFLICT (id) DO NOTHING;

    -- Ensure we have a clean configuration state
    DELETE FROM supasession.config;

    -- Insert default configuration (disabled by default)
    INSERT INTO supasession.config (enabled, max_sessions, strategy)
    VALUES (FALSE, 1, 'dequeue');
END $$;

-- Test 0: Verify extension components exist
SELECT has_function(
    'supasession',
    '_limiter',
    ARRAY[]::TEXT[],
    'supasession._limiter function should exist'
);

SELECT has_trigger(
    'auth',
    'sessions',
    'supasession_interceptor',
    'supasession_interceptor trigger should exist on auth.sessions'
);

SELECT trigger_is(
    'auth',
    'sessions',
    'supasession_interceptor',
    'supasession',
    '_limiter',
    'Trigger should call supasession._limiter function'
);

-- Test 1: Extension disabled - should allow unlimited sessions
SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''11111111-1111-1111-1111-111111111111''::uuid, NOW(), NOW())',
    'Should allow session creation when extension is disabled'
);

SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''11111111-1111-1111-1111-111111111111''::uuid, NOW(), NOW())',
    'Should allow multiple sessions when extension is disabled'
);

-- Count sessions for user 1
SELECT is(
    (SELECT COUNT(*) FROM auth.sessions WHERE user_id = '11111111-1111-1111-1111-111111111111'::uuid),
    2::bigint,
    'Should have 2 sessions for user 1 when disabled'
);

-- Test 2: Enable extension with default settings (limit=1, strategy=dequeue)
SELECT lives_ok(
    'SELECT supasession.enable()',
    'Should be able to enable the extension'
);

-- Test 3: Within limit - should allow session creation
SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    'Should allow first session for user 2 when enabled'
);

-- Test 4: Exceed limit with dequeue strategy - should delete oldest and allow new
-- Insert sessions with specific UUIDs and staggered times to test oldest deletion
DO $$
DECLARE
    first_session_id uuid := '33333333-3333-3333-3333-333333333333'::uuid;
    second_session_id uuid := '44444444-4444-4444-4444-444444444444'::uuid;
BEGIN
    -- Insert first session (this will be the oldest)
    INSERT INTO auth.sessions (id, user_id, created_at, updated_at)
    VALUES (first_session_id, '22222222-2222-2222-2222-222222222222'::uuid, NOW() - INTERVAL '1 minute', NOW() - INTERVAL '1 minute');

    -- Small delay to ensure different timestamps
    PERFORM pg_sleep(0.01);

    -- Insert second session (this should trigger dequeue of the first)
    INSERT INTO auth.sessions (id, user_id, created_at, updated_at)
    VALUES (second_session_id, '22222222-2222-2222-2222-222222222222'::uuid, NOW(), NOW());
END $$;

-- Verify the oldest session was deleted and newest remains
SELECT is(
    (SELECT COUNT(*) FROM auth.sessions WHERE user_id = '22222222-2222-2222-2222-222222222222'::uuid),
    1::bigint,
    'Should maintain limit of 1 session with dequeue strategy'
);

SELECT is(
    (SELECT COUNT(*) FROM auth.sessions WHERE id = '33333333-3333-3333-3333-333333333333'::uuid),
    0::bigint,
    'Oldest session should be deleted (first session removed)'
);

SELECT is(
    (SELECT COUNT(*) FROM auth.sessions WHERE id = '44444444-4444-4444-4444-444444444444'::uuid),
    1::bigint,
    'Newest session should remain (second session kept)'
);

--  Change to `reject` strategy
SELECT supasession.set_config(strategy := 'reject'::supasession.enforcement_strategy);

-- Test 5: Exceed limit with reject strategy - should throw exception
SELECT throws_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    NULL,
    'Session limit of 1 exceeded for user 22222222-2222-2222-2222-222222222222',
    'Should reject new session when limit exceeded with reject strategy'
);

-- Should still have only 1 session (new one was rejected)
SELECT is(
    (SELECT COUNT(*) FROM auth.sessions WHERE user_id = '22222222-2222-2222-2222-222222222222'::uuid),
    1::bigint,
    'Should maintain 1 session after rejection'
);

-- Test 6: Increase limit and test multiple sessions
SELECT lives_ok(
    'SELECT supasession.set_config(max_sessions := 3)',
    'Should be able to increase session limit to 3'
);

-- Should now allow 2 more sessions (total 3)
SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    'Should allow second session when limit is 3'
);

SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    'Should allow third session when limit is 3'
);

SELECT is(
    (SELECT COUNT(*) FROM auth.sessions WHERE user_id = '22222222-2222-2222-2222-222222222222'::uuid),
    3::bigint,
    'Should have 3 sessions when limit is 3'
);

-- Test 7: Fourth session should be rejected
SELECT throws_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    NULL,
    'Session limit of 3 exceeded for user 22222222-2222-2222-2222-222222222222',
    'Should reject fourth session when limit is 3'
);

-- Test 8: Test expired sessions don't count toward limit

-- Change limit to 4
SELECT supasession.set_config(max_sessions := 4);

-- Insert an expired session (not_after in the past)
SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at, not_after) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW(), NOW() - INTERVAL ''1 hour'')',
    'Should allow inserting expired session'
);

-- Should still have 3 valid sessions (expired one doesn't count) but 4 total sessions

-- Now a new valid session should be allowed as the expired one doesn't count
SELECT lives_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    'Should allow new session (expired sessions do not count toward limit)'
);

-- Another session should finally be rejected
SELECT throws_ok(
    'INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), ''22222222-2222-2222-2222-222222222222''::uuid, NOW(), NOW())',
    NULL,
    'Session limit of 4 exceeded for user 22222222-2222-2222-2222-222222222222',
    'Should reject new session when limit is exceeded'
);

-- Cleanup: Reset to default disabled state
DELETE FROM auth.sessions WHERE user_id IN ('11111111-1111-1111-1111-111111111111'::uuid, '22222222-2222-2222-2222-222222222222'::uuid);
UPDATE supasession.config SET enabled = FALSE, max_sessions = 1, strategy = 'dequeue';

SELECT * FROM finish();