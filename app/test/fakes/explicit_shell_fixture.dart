// Portable shell-only request; no command is executed by these unit tests.
const shellFixtureCommand = r"printf '%s\n' 'SHELL-APPROVAL-628'";
const shellFixtureCwd = '/tmp/woi-shell-fixture';
const explicitShellFixtureRequest =
    'Call run_bash exactly once with the exact command `$shellFixtureCommand`, '
    'cwd `$shellFixtureCwd`, and timeout_s 5. '
    'Do not use any other tools, run any other command, or edit any file.';
