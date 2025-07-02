-- Test auth helpers

BEGIN;

SELECT plan(4);

-- Test 1: Check that supasession.sid() function exists
SELECT has_function(
    'supasession',
    'sid',
    ARRAY[]::TEXT[],
    'supasession.sid() function should exist'
);

-- Test 2: Check return type is UUID
SELECT function_returns(
    'supasession',
    'sid',
    ARRAY[]::TEXT[],
    'uuid',
    'supasession.sid() should return UUID type'
);

-- Test 3: Test supasession.sid() returns NULL when no JWT session_id is set
-- (This simulates the case when there's no valid JWT or session context)
SELECT is(
    supasession.sid(),
    NULL::uuid,
    'supasession.sid() should return NULL when no session context is available'
);

-- Test 4: Test supasession.sid() with mocked JWT claim
-- Note: In a real Supabase environment, you'd need to set up proper JWT context
-- This test simulates setting the request.jwt.claim.session_id setting
DO $$
DECLARE
    test_session_id uuid := gen_random_uuid();
BEGIN
    -- Set the request.jwt.claim.session_id setting to simulate JWT context
    PERFORM set_config('request.jwt.claim.session_id', test_session_id::text, false);

    -- Store the test session ID for comparison outside the DO block
    PERFORM set_config('test.expected_session_id', test_session_id::text, false);
END $$;

-- Test that supasession.sid() returns the expected session ID
SELECT is(
    supasession.sid(),
    current_setting('test.expected_session_id')::uuid,
    'supasession.sid() should return the session ID from JWT claim'
);

-- Clean up the settings
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.session_id', '', false);
    PERFORM set_config('test.expected_session_id', '', false);
END $$;

SELECT * FROM finish();

ROLLBACK;