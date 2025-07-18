\echo Use `CREATE EXTENSION supasession` to load this extension \quit

-- Requires Supabase Auth to be initialized:
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'auth' AND table_name = 'sessions'
    ) THEN
        RAISE EXCEPTION 'This extension requires Supabase Auth to be initialized';
    END IF;
END $$;

-- Create base schema:
CREATE SCHEMA supasession;
COMMENT ON SCHEMA supasession IS
'Reserved for the `supasession` extension';

/**
 * ### Types
 */

/**
 * #### supasession.enforcement_strategy
 *
 * Represents the strategy for enforcing session limits.
 *
 * - **dequeue** - Destroys the oldest session when the limit is reached
 * - **reject** - Rejects any new sessions when the limit is reached
 */
CREATE TYPE supasession.enforcement_strategy AS ENUM (
    'reject',
    'dequeue'
);
COMMENT ON TYPE supasession.enforcement_strategy IS 'Represents the strategy for enforcing session limits';

/**
 * ### Tables
 */

/**
 * #### supasession.config
 *
 * Extension configuration.
 *
 * - **enabled** (`BOOLEAN`) - Whether session limiting is enabled (Default: `FALSE`)
 * - **max_sessions** (`INTEGER`): Maximum number of active sessions allowed per user (Default: `1`)
 * - **strategy** ([`supasession.enforcement_strategy`](#supasessionenforcement_strategy)): Enforcement strategy when the session limit is reached (Default: `dequeue`)
 */
CREATE TABLE supasession.config (
    version TEXT PRIMARY KEY DEFAULT '0.1.2' CHECK (version = '0.1.2'), -- this it to enforce a single row configuration
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    max_sessions INTEGER NOT NULL DEFAULT 1 CHECK (max_sessions > 0),
    strategy supasession.enforcement_strategy NOT NULL DEFAULT 'dequeue'
);
COMMENT ON TABLE supasession.config IS 'Extension configuration';
COMMENT ON COLUMN supasession.config.version IS 'Configuration schema version';
COMMENT ON COLUMN supasession.config.enabled IS 'Whether session limiting is enabled';
COMMENT ON COLUMN supasession.config.max_sessions IS 'Maximum number of active sessions allowed per user';
COMMENT ON COLUMN supasession.config.strategy IS 'Enforcement strategy when the session limit is reached';

-- Insert default configuration
INSERT INTO supasession.config DEFAULT VALUES
ON CONFLICT (version) DO NOTHING;

/**
 * ### Functions
 *
 * These functions provide a convenient layer on top of [`supasession.config`](#supasessionconfig) to manage extension configuration.
 * Alternatively, you can always directly query/update the [`supasession.config`](#supasessionconfig) table.
 */

/**
 * #### supasession.enable()
 *
 * Enables session limits enforcement.
 *
 * ```sql
 * SELECT supasession.enable();
 * ```
 *
 * ##### Returns:
 *   - `VOID`
 */
CREATE FUNCTION supasession.enable()
RETURNS void AS $$
BEGIN
    UPDATE supasession.config
    SET enabled = TRUE
    WHERE version = '0.1.2';
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION supasession.enable() IS 'Enables session limits enforcement';

/**
 * #### supasession.disable()
 *
 * Disables session limits enforcement.
 *
 * ```sql
 * SELECT supasession.disable();
 * ```
 *
 * ##### Returns:
 *   - `VOID`
 */
CREATE FUNCTION supasession.disable()
RETURNS void AS $$
BEGIN
    UPDATE supasession.config
    SET enabled = FALSE
    WHERE version = '0.1.2';
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION supasession.disable() IS 'Disables session limits enforcement';

/**
 * #### supasession.set_config( [enabled BOOLEAN], [max_sessions INTEGER], [strategy supasession.enforcement_strategy] )
 *
 * Updates extension configuration.
 *
 * ```sql
 * SELECT supasession.set_config(max_sessions := 5);
 * SELECT supasession.set_config(enabled := FALSE, strategy := 'reject');
 * ```
 *
 * ##### Parameters:
 *   - **enabled** (`BOOLEAN`, *optional*) - Whether session limiting is enabled
 *   - **max_sessions** (`INTEGER`, *optional*) - Maximum number of active sessions allowed per user
 *   - **strategy** ([`supasession.enforcement_strategy`](#supasessionenforcement_strategy), *optional*) - Enforcement strategy when the session limit is reached
 *
 * ##### Returns:
 *   - [`supasession.config`](#supasessionconfig) - Updated configuration
 */
CREATE FUNCTION supasession.set_config(
    enabled BOOLEAN DEFAULT NULL,
    max_sessions INTEGER DEFAULT NULL,
    strategy supasession.enforcement_strategy DEFAULT NULL
)
RETURNS supasession.config AS $$
DECLARE
    updated_config supasession.config%ROWTYPE;
BEGIN
    UPDATE supasession.config
    SET
        enabled = COALESCE(set_config.enabled, supasession.config.enabled),
        max_sessions = COALESCE(set_config.max_sessions, supasession.config.max_sessions),
        strategy = COALESCE(set_config.strategy, supasession.config.strategy)
    WHERE version = '0.1.2'
    RETURNING * INTO updated_config;

    RETURN updated_config;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION supasession.set_config(enabled BOOLEAN, max_sessions INTEGER, strategy supasession.enforcement_strategy) IS 'Updates the configuration of the `supasession` extension';

/**
 * #### supasession.get_config()
 *
 * Retrieves extension configuration.
 *
 * ```sql
 * SELECT supasession.get_config();
 * ```
 *
 * ##### Returns:
 *   - [`supasession.config`](#supasessionconfig) - Current configuration
 */
CREATE FUNCTION supasession.get_config()
RETURNS supasession.config
STABLE
AS $$
DECLARE
    config_record supasession.config%ROWTYPE;
BEGIN
    SELECT * INTO config_record FROM supasession.config WHERE version = '0.1.2';
    RETURN config_record;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION supasession.get_config() IS 'Retrieves the current extension configuration';

/**
 * (internal) ### Core
 */

/**
 * (internal) #### supasession._limiter()
 *
 * Core trigger function that enforces session limits.
 */
CREATE FUNCTION supasession._limiter()
RETURNS TRIGGER
SECURITY DEFINER -- this function needs owner privileges to manage session records
AS $$
DECLARE
    config supasession.config%ROWTYPE;
    valid_session_count INTEGER;
BEGIN
    -- Get configuration
    SELECT * INTO config FROM supasession.config WHERE version = '0.1.2';

    -- If config doesn't exist or not enabled, allow insertion
    IF config IS NULL OR NOT config.enabled THEN
        RETURN NEW;
    END IF;

    -- Validity check of the new session for sanity
    IF NEW.not_after IS NOT NULL AND NEW.not_after <= NOW() THEN
        -- Insert anyways as an expired session doesn't matter and we don't want to disappoint the client making this request
        RETURN NEW;
    END IF;

    -- Count valid sessions for this user
    SELECT COUNT(*) INTO valid_session_count
    FROM auth.sessions
    WHERE user_id = NEW.user_id
        AND (not_after IS NULL OR not_after > NOW());

    -- If we're within the limit, allow insertion
    IF valid_session_count < config.max_sessions THEN
        RETURN NEW;
    END IF;

    -- Handle enforcement strategy when limit is exceeded
    IF config.strategy = 'reject' THEN
        RAISE EXCEPTION 'Session limit of % exceeded for user %', config.max_sessions, NEW.user_id;
    ELSIF config.strategy = 'dequeue' THEN
        -- Delete the oldest sessions over the limit, for this user
        -- NOTE: This will also delete all associated refresh tokens via cascade which is intended behavior
        DELETE FROM auth.sessions
        WHERE id IN (
            SELECT id
            FROM auth.sessions
            WHERE user_id = NEW.user_id
                AND (not_after IS NULL OR not_after > NOW())
            ORDER BY updated_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT valid_session_count - config.max_sessions + 1 -- delete enough to make room for the new session
        );
        -- Finally, register the new session
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION supasession._limiter() IS 'Session limit enforcer';

/**
 * (internal) #### auth.sessions.supasession_interceptor
 *
 * Trigger that calls `supasession._limiter()` before registering a session into `auth.sessions`.
 */
CREATE TRIGGER supasession_interceptor
    BEFORE INSERT ON auth.sessions
    FOR EACH ROW
    EXECUTE FUNCTION supasession._limiter();

-- NOTE: Why are we enforcing session limits during sign-ins and not by blocking token refreshes? Wouldn't that be more effective?
-- Yes, it's more effective as limits would also be enforced on existing sessions but it comes with some dirty caveats which is better to stay away from:
-- Blocking a transaction at the DB level like is represented as a 500 internal server error by the API layer.
-- Most well-written Supabase clients implement retry loops when refreshing tokens for server errors they deem as "retryable". This is to enable a flawless UX where a user is not randomly logged out of their session due to bad network.
-- These 5XX errors are part of these "retryable" errors and will cause the client to retry the request. Although the server will successfully return a `BadRequest` for the retried request (because we deleted the session entry on first request) causing the client to resign, it still took two requests to get there.
-- Some official client SDKs (js, py) more specifically only retry on 502, 503, and 504, but some (flutter) treat all 5XX as "retryable". Better to stay conservative and avoid writing brittle logic around the "token-refresh" flow.

/**
 * ### Auth helpers
 *
 * Helper functions to work with sessions within [RPCs](https://docs.postgrest.org/en/stable/references/api/functions.html).
 */

/**
 * #### supasession.sid()
 *
 * Returns the session ID from the JWT of the current request. (Analogous to `auth.uid()`)
 *
 * ```sql
 * SELECT supasession.sid() AS session_id;
 * ```
 *
 * ##### Returns:
 *   - `UUID|NULL` - The session ID (`auth.sessions.id`), or `NULL` if not available
 */
CREATE OR REPLACE FUNCTION supasession.sid()
RETURNS uuid
STABLE
AS $$
    SELECT
    COALESCE(
        NULLIF(current_setting('request.jwt.claim.session_id', TRUE), ''),
        (NULLIF(current_setting('request.jwt.claims', TRUE), '')::jsonb ->> 'session_id')
    )::uuid
$$ LANGUAGE sql;
COMMENT ON FUNCTION supasession.sid() IS 'Returns the session ID from the JWT of the current request';