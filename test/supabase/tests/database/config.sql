-- Test configuration table and functions
SELECT plan(31);

-- Test schema existence
SELECT has_schema('supasession', 'supasession schema should exist');

-- Test table existence
SELECT has_table('supasession', 'config', 'supasession.config table should exist');

-- Test table columns
SELECT has_column('supasession', 'config', 'version', 'config table should have version column');
SELECT has_column('supasession', 'config', 'enabled', 'config table should have enabled column');
SELECT has_column('supasession', 'config', 'max_sessions', 'config table should have max_sessions column');
SELECT has_column('supasession', 'config', 'strategy', 'config table should have strategy column');

-- Test column types
SELECT col_type_is('supasession', 'config', 'version', 'text', 'version column should be text');
SELECT col_type_is('supasession', 'config', 'enabled', 'boolean', 'enabled column should be boolean');
SELECT col_type_is('supasession', 'config', 'max_sessions', 'integer', 'max_sessions column should be integer');
SELECT col_type_is('supasession', 'config', 'strategy', 'supasession.enforcement_strategy', 'strategy column should be enforcement_strategy enum');

-- Test primary key
SELECT col_is_pk('supasession', 'config', 'version', 'version should be primary key');

-- Test default row exists
SELECT ok(
    EXISTS(SELECT 1 FROM supasession.config),
    'Default configuration row should exist'
);

-- Test default values using entire record
SELECT is(
    (SELECT (enabled, max_sessions, strategy) FROM supasession.config LIMIT 1),
    (false, 1, 'dequeue'::supasession.enforcement_strategy),
    'Default configuration should have correct values'
);

-- Test that inserting a new record fails (single row constraint)
SELECT throws_ok(
    'INSERT INTO supasession.config (enabled) VALUES (true)',
    NULL,
    NULL,
    'Inserting a new config row should fail due to single row constraint'
);

-- Test supasession.get_config() function
SELECT has_function('supasession', 'get_config', ARRAY[]::TEXT[], 'get_config function should exist');

SELECT is(
    (SELECT (enabled, max_sessions, strategy) FROM supasession.get_config()),
    (false, 1, 'dequeue'::supasession.enforcement_strategy),
    'get_config() should return default configuration'
);

-- Test supasession.enable() function
SELECT has_function('supasession', 'enable', ARRAY[]::TEXT[], 'enable function should exist');

SELECT lives_ok(
    'SELECT supasession.enable()',
    'enable() function should execute without error'
);

SELECT is(
    (SELECT enabled FROM supasession.config LIMIT 1),
    true,
    'After enable(), enabled should be true'
);

-- Test supasession.disable() function
SELECT has_function('supasession', 'disable', ARRAY[]::TEXT[], 'disable function should exist');

SELECT lives_ok(
    'SELECT supasession.disable()',
    'disable() function should execute without error'
);

SELECT is(
    (SELECT enabled FROM supasession.config LIMIT 1),
    false,
    'After disable(), enabled should be false'
);

-- Test supasession.set_config() function
SELECT has_function('supasession', 'set_config',
    ARRAY['boolean', 'integer', 'supasession.enforcement_strategy'],
    'set_config function should exist with correct parameters'
);

-- Test setting individual parameters
SELECT lives_ok(
    'SELECT supasession.set_config(enabled := true)',
    'set_config() with enabled parameter should execute without error'
);

SELECT is(
    (SELECT enabled FROM supasession.config LIMIT 1),
    true,
    'After set_config(enabled := true), enabled should be true'
);

SELECT lives_ok(
    'SELECT supasession.set_config(max_sessions := 5)',
    'set_config() with max_sessions parameter should execute without error'
);

SELECT is(
    (SELECT max_sessions FROM supasession.config LIMIT 1),
    5,
    'After set_config(max_sessions := 5), max_sessions should be 5'
);

SELECT lives_ok(
    'SELECT supasession.set_config(strategy := ''reject''::supasession.enforcement_strategy)',
    'set_config() with strategy parameter should execute without error'
);

SELECT is(
    (SELECT strategy FROM supasession.config LIMIT 1),
    'reject'::supasession.enforcement_strategy,
    'After set_config(strategy := reject), strategy should be reject'
);

-- Test setting multiple parameters at once
SELECT lives_ok(
    'SELECT supasession.set_config(enabled := false, max_sessions := 3, strategy := ''dequeue''::supasession.enforcement_strategy)',
    'set_config() with multiple parameters should execute without error'
);

-- Verify all changes were applied using entire record
SELECT is(
    (SELECT (enabled, max_sessions, strategy) FROM supasession.config LIMIT 1),
    (false, 3, 'dequeue'::supasession.enforcement_strategy),
    'After multi-parameter set_config(), all values should be updated correctly'
);

-- Cleanup: Reset to default disabled state
UPDATE supasession.config SET enabled = FALSE, max_sessions = 1, strategy = 'dequeue';

SELECT * FROM finish();