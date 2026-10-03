# AGENTS.md

This repository is heavily AI-written and unowned (see [NOTICE](./NOTICE)).
Treat it as disposable source — copy, rewrite, lift, or borrow from
freely under the MIT licence in [LICENSE](./LICENSE).

What this is
------------

A Taskwarrior hooks bundle that mirrors notmuch messages (read and tagged
via `notmuch`) into TW tasks. The two Taskwarrior hooks (`on-launch`,
`on-modify`) plus the shared library (`lib/notmuch-task-lib.bash`), the
taskrc fragment (`notmuch-task.taskrc`), and the example configs
(`config.d/*.conf`) together form a self-contained bundle that
`install.bash` deploys under `<hooks.location>/notmuch-task/`.

Layout
------

```
notmuch-task/
├── LICENSE                       # MIT
├── NOTICE                        # AI-written / unowned disclosure
├── AGENTS.md                     # this file
├── README.md                     # user-facing docs (install + config + troubleshooting)
├── install.bash                  # bash installer (requires bash 4+)
├── config.d/
│   ├── example-default.conf      # starter config (tag:todo pool)
│   └── example-multi.conf        # second-pool starter config
├── hooks/
│   ├── on-launch.notmuch-task    # mirror notmuch → TW (run on every `task` invocation)
│   ├── on-modify.notmuch-task    # push TW edits → notmuch tags (run on task modification)
│   └── notmuch-task/
│       ├── notmuch-task.taskrc   # `include` this in your .taskrc
│       └── lib/
│           └── notmuch-task-lib.bash # shared library sourced by both hooks
└── tests/
    └── test-notmuch-task.bash    # full test suite (bash, no bats)
```

Conventions
-----------

- **Bash 4+.** All scripts target bash 4+ (uses `declare -A`, `mapfile`,
  `printf -v`, `[[ ]]`). The shebangs are `#!/usr/bin/env bash`.
- **File extensions**: `.bash` for bash-specific scripts; `.sh`
  reserved for POSIX-compliant scripts (none in this repo today).
- **`set -u` everywhere.** Every script uses `set -u` to catch unset-
  variable mistakes. The lib temporarily `set +u` around user `source`
  calls so a stray unset in a user's config doesn't abort the hook.
- **`notmuch_task::` namespace.** All lib helpers are `notmuch_task::name`
  bash functions. Variables are exported across the hook boundary so
  each hook can read them under its own `set -u`.
- **Hook output conventions.**
  - `on-launch` writes feedback on **stderr**, never stdout.
  - `on-modify` writes the modified task JSON as its **first stdout
    line** and feedback on subsequent stdout lines / stderr.
- **Fail-open.** Every helper returns 1 cleanly when its prerequisites
  are missing (jq, notmuch, config, etc.) and the caller logs a feedback
  line without aborting the hook. The only hard exit (`exit 1`) is for
  the structurally fatal case of a missing config directory in
  `on-launch`.

Editing the lib
---------------

Default values for all config keys live in
`notmuch_task::set_config_defaults` — update this function AND the
matching `export ...` line at the bottom of
`notmuch_task::source_config_file` when adding a new key.

New helpers belong in `lib/notmuch-task-lib.bash` and should be sourced
automatically by both hooks through `notmuch-task/lib/notmuch-task-lib.bash`.
Avoid `eval`. Prefer bash arrays + `mapfile`/`read -a`.

When a helper takes a per-config runtime flag (e.g. `init_age_from_notmuch`)
and reads it from `set_config_defaults`, make sure the per-config
function `notmuch_task::source_config_file` re-exports the flag, and the
hook refreshes it between config iterations.

Editing the hooks
-----------------

- Hooks source the lib via
  `source "$SELF_DIR/notmuch-task/lib/notmuch-task-lib.bash"`. Don't hardcode
  absolute paths.
- The config dir default is `$SELF_DIR/notmuch-task/config.d/`. Override
  with `$NOTMUCH_TASK_CONFIG_DIR` to point at a different directory.
- `on-launch` skips mirroring when the user is mid-`add` or mid-`import`.
  Reason: the user's just-saved task isn't yet visible to our
  `task export`, and mirroring in that state would race the user's
  task. New messages get mirrored at the next `task list` instead.
- Per-record fields that depend on a config's values (`project`) must be
  evaluated *per message* and baked into the flat record before batched
  import — otherwise multi-config flows inherit the last-loaded config's
  values.
- `on-launch` never pushes state back from notmuch to TW (TW is
  authoritative for state). A state-tag mismatch on a matched task is
  logged as a soft warning only.

Editing tests
-------------

- The single test entrypoint is `tests/test-notmuch-task.bash`. Run it
  directly with `bash tests/test-notmuch-task.bash` (no bats).
- The fake `notmuch` is on `$FAKE_BIN` (earlier on `PATH`). It detects
  the subcommand from `$1` (search/show/tag) rather than relying on a
  mode variable. For search, it inspects the query to return canned
  message-ids per query; for show, it inspects `id:` to return canned
  headers per id; for tag, it logs its args to `$FAKE_NOTMUCH_TAG_LOG`.
- Helpers near the top of the test file (`fresh_tasks`, `add_config`,
  `reset_configs`, `tx`, `t`) are the recommended primitives. Tests
  should compose them rather than build their own scaffolding.

Adding a new config key
-----------------------

1. Add the default to `notmuch_task::set_config_defaults` in the lib.
2. Add the key to the `export ...` line at the end of
   `notmuch_task::source_config_file`.
3. If the key drives a per-record field, add the corresponding `+ (if
   $X != "" then {…})` line to the jq block at the bottom of
   `notmuch_task::notmuch_to_task_import_record`.
4. Document the key:
   - In `README.md`'s Configuration table.
   - In `config.d/example-default.conf` (with a sensible example value).

Releasing
---------

No formal release cadence. Push to git whenever tests pass
(`bash tests/test-notmuch-task.bash` reports 21 PASS / 0 FAIL is the
current bar). No CHANGELOG file is kept — git history is the source.

Where to look first when something breaks
-----------------------------------------

- Hook isn't firing: check `task diag` (Taskwarrior lists discovered
  hooks and their executability).
- Tasks aren't being mirrored: `bash install.bash --help`, check the
  bundle's `notmuch-task/config.d/` for `.conf` files.
- Tasks are mirrored but state tags don't match: the issue is almost
  certainly in the `pending_tag` / `done_tag` / `deleted_tag` /
  `trigger_tag` values of one of your configs, or in notmuch itself.
  `notmuch_task::in_list` does case-insensitive whitespace-tolerant
  matching.
- notmuch push-back (on-modify) silently fails: check the
  `FAKE_NOTMUCH_TAG_LOG` in tests, or run `notmuch tag` by hand with the
  same args so you see real notmuch errors.

Background context
------------------

- Taskwarrior hook contract: see <https://taskwarrior.org/docs/hooks2/>.
  Hooks v2 (`api:2`) is the supported protocol.
- notmuch: see <https://notmuchmail.org/>. `notmuch search
  --output=messages --format=json` returns a JSON array of **bare**
  message-ids (no angle brackets); `notmuch show --format=json id:<id>`
  returns a thread tree whose message objects carry `subject`, `authors`,
  `headers.Date`, and `tags`, which is where the Subject/From/Date
  enrichment comes from.