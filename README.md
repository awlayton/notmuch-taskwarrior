# notmuch-task: Taskwarrior <-> notmuch tag sync hooks

> **AI-written, unowned code.** This repository is the output of an AI
> coding session with light human direction. No human claims authorship
> or ownership of the design, code, or documentation — see
> [NOTICE](./NOTICE) and [LICENSE](./LICENSE). Treat it as disposable
> source: copy, rewrite, lift, or borrow freely.

Two Taskwarrior hook scripts that sync notmuch messages (read and tagged via the
[notmuch](https://notmuchmail.org/) mail indexer) with a local Taskwarrior task
list.

| Hook | Runs | Direction |
| ------ | ------ | ----------- |
| `hooks/on-launch.notmuch-task` | before every `task` |
| invocation | notmuch -> Taskwarrior (mirror, with deterministic |
| UUIDs) |   | `hooks/on-modify.notmuch-task` | after every task |
| edit | Taskwarrior -> notmuch (push |
| tags) |

Tasks are linked to notmuch messages through a `notmuchid` UDA, so only tasks
that carry one are ever touched by the hooks.

## Requirements

- **Taskwarrior 2.4.3+** (uses the v2 hooks API; tested on 3.4.2)
- **notmuch** installed and indexed (`notmuch new` done at least once)
- **jq** (standard on Linux) — if missing, the hooks fail open with a warning
- **bash 4+** (for `mapfile`)

## Install

```sh
bash install.bash
```

This copies the two hooks into the destination directory and lays out the shared
library plus the taskrc fragment into a self-contained `notmuch-task/`
subdirectory next to them.
The hooks source the lib from `../notmuch-task/lib/notmuch-task-lib.bash`.
The install then prints **one** line to drop into your `.taskrc` — an `include`
pointing at the installed taskrc fragment (which itself defines the UDAs and
`hooks.location`).
`--force` overwrites existing copies.
The install is idempotent:
already-present files are skipped unless `--force` is given.

The install destination is resolved in this order:

1. `$TASK_HOOKS_DIR` (env override wins)
2. `${XDG_CONFIG_HOME:-$HOME/.config}/task/hooks` (XDG Base Directory Spec —
   hooks are user-managed config files, so they live alongside `.taskrc` under
   `XDG_CONFIG_HOME`)
3. `$HOME/.task/hooks` (legacy Taskwarrior 2.x default; co-located with the task
   data)

Note:
this only affects where the **hook scripts** are installed.
The task **data** directory used by the hooks themselves still follows
taskwarrior's own `data.location` (via the `data:` hook arg), which on stock TW
3.x lives under `$XDG_DATA_HOME/task`.
If your task data lives elsewhere (e.g., `~/.task` for TW 2.x or a custom path),
nothing here needs to change — the hooks reach it via the `data:` arg your
taskwarrior passes them.

If you keep your `.taskrc` under `$XDG_CONFIG_HOME/task/` (the typical XDG
layout), the helper installs into the matching `task/hooks` directory
automatically.
To install elsewhere, set `TASK_HOOKS_DIR` to that path before running install,
or set `hooks.location` in your rc and pass `TASK_HOOKS_DIR` accordingly.
Add the printed `include` line to `~/.taskrc` (no copy-pasting of contents to do
— the included file defines the UDAs and `hooks.location` internally):

```conf
include /home/you/.config/task/hooks/notmuch-task/notmuch-task.taskrc
```

Replace the path above with whichever absolute path `install.bash` actually
printed; `taskwarrior`'s `include` directive reads file paths literally (no `~`
or env-var expansion).
Create one or more configs in the bundle's `config.d/` directory — each file is
a **whole** config (defaults are reapplied per file, so a key unset in this file
does NOT leak from the previous file):

```sh
# The bundle's config.d/ lives next to the hooks - the paths below match
# what `bash install.bash` just deployed. Override hooks.location in your
# rc and re-run install to put the whole bundle elsewhere.
HOOK_BUNDLE="$HOME/.config/task/hooks/notmuch-task"      # adjust to match your install
mkdir -p "$HOOK_BUNDLE/config.d"
# One config per notmuch query / tag pool. Filename's alphabetical
# order is also the loading order, so prefix with a number (10-, 20-)
# to keep things deterministic when you need finer control.
cp config.d/example-default.conf "$HOOK_BUNDLE/config.d/10-inbox.conf"
cp config.d/example-multi.conf   "$HOOK_BUNDLE/config.d/20-waiting.conf"
$EDITOR "$HOOK_BUNDLE/config.d/10-inbox.conf"
```

Each file gets its own `query`, `project`, `sync_on_modify`, etc. Keys that
differ across configs are picked up per record at queue time — for instance, the
`project` you set in `10-inbox.conf` applies to the tasks mirrored from THAT
config's query, even if a later config (`20-waiting.conf`) overrides the global
`$project` during its loop.

Verify with `task diag` (hooks should be listed as executable) and then `task
list` — mirrored messages appear as tasks.

## Configuration

`KEY=VALUE`, bash-sourceable.
Default path is the bundle's own `notmuch-task/config.d/` (relative to the hooks
location — i.e. alongside `notmuch-task.taskrc` and `lib/`, inside the directory
that `bash install.bash` deployed).
Override with the `NOTMUCH_TASK_CONFIG_DIR` environment variable to put configs
anywhere else (e.g. `NOTMUCH_TASK_CONFIG_DIR=/srv/notmuch-configs`).
Each `*.conf` (or `*.bash`) file in that directory is loaded as a complete
config; the alphabetical order of filenames is the iteration order.

| Key | Default | Meaning |
| ----- | --------- | --------- |
| `query` | `tag:todo` | notmuch |
search query whose matching messages are import
| candidates. |
| --- |
| `project` | *(empty)* | Project |
assigned to mirrored tasks; empty = no project.
| Used as the fallback when `project_tag_prefi |
| --- |
is set but no `<prefix>:*` tag is present on the
| message. |
| --- |
| `project_tag_prefix` | *(empty)* | When |
non-empty, derive the project from `<prefix>:<X>` notmuch tags on the message
| (alphabetical-fir |
| --- |
`X` wins).
When set, this OVERRIDES the literal `project` value whenever a matching tag is
| presen |
| --- |
Leave empty to project solely from the
| literal. |
| --- |
| `notmuchid_uda` | `notmuchid` | UDA |
holding the bare message-id (RFC 5322, no angle
| brackets). |
| --- |
| `notmuchstate_uda` | `notmuchstate` | UDA |
holding the mirror of the latest applied state
| tag. |
| --- |
| `notmuchmsgid_uda` | `notmuchmsgid` | UDA |
holding the full RFC 5322 id (`<id@host>`),
| informational. |
| --- |
| `trigger_tag` | `todo` | Messages |
carrying this tag are import-eligible (the "import me"
| pool). |
| --- |
| `pending_tag` | `task-pending` | Tag |
added when a task enters pending (and on first
| import). |
| --- |
| `done_tag` | `task-done` | Tag |
added when a task is
| completed. |
| --- |
| `deleted_tag` | `task-deleted` | Tag |
added when a task is
| deleted. |
| --- |
| `remove_on_pending` | `todo` | Tags |
stripped when a task enters pending (default strips the trigger tag on first
| import). |
| --- |
| `remove_on_done` | `todo` | Tags |
stripped when a task is
| completed. |
| --- |
| `remove_on_deleted` | `todo` | Tags |
stripped when a task is
| deleted. |
| --- |
| `sync_on_modify` | `1` | Push |
task edits back to notmuch (on-modify
| hook). |
| --- |
| `sync_tags_on_modify` | `0` | Push |
tag changes as notmuch tag add/remove.
| **Off |  by default.** \| \| |
| --- | --- |
`sync_description_on_launch` | `1` | Mirror message Subjects over local
description edits on launch.
| | `notmuch_bin` | `notmuch` | Path/name of the notmuch binary.
| | `quiet` | `0` | `1` silences non-error feedback.
| | `init_age_from_notmuch` | `1` | When `1`, mirror the message's `Date` header
to the imported task's `entry` (so its `age` matches the email's age).
Costs one extra `notmuch show` per new message per on-launch pass.
When `0`, per-message enrichment is skipped entirely (no Subject/Date harvest)
and `entry` is the import moment.
|

## How it works

### on-launch (notmuch -> Taskwarrior)

1. Reads the v2 hook args (`data:` / `rc:` / `command:`), sources
   `hooks/notmuch-task/lib/notmuch-task-lib.bash`, loads the config, and
   verifies `notmuch` exists.
2. **Skips mirroring when the user is mid-`add` or mid-`import`** — those
   commands race the hooks' UUID assignment, so any new messages are mirrored at
   the next `task list` / `task next` / etc invocation instead.
3. Exports the local task list (hooks disabled internally with `rc.hooks=off
   rc.color=no`) and indexes it by the `notmuchid` UDA.
4. Fetches the snapshot:
   `notmuch search --output=messages --format=json "$query"`, yielding a JSON
   array of bare message-ids.
   When `init_age_from_notmuch=1` (the default), each id is enriched with a
   per-message `notmuch show --format=json id:<id>` call that harvests the
   Subject, From, and Date headers (and the message's current tags).
5. For each message:
   if no task has its message-id, the message is queued for batch import (always
   as a `pending` task — Taskwarrior is authoritative for state, so notmuch tags
   never decide the imported status).
   If a task matches, its description is re-synced to the Subject (when
   `sync_description_on_launch=1`) and its state is left alone; a message whose
   state tags imply a different state than the task's status is logged as a soft
   warning only.
   Tasks in `deleted`/`waiting`/`recurring` state with a `notmuchid` are matched
   but left untouched, so they are never mirrored twice.
6. After the loop, queued messages are batched into a single JSON file and
   imported via `task import`.
   Each record carries a **deterministic UUID** derived from its bare message-id
   (see `notmuch_task::msgid_to_uuid` in
   `hooks/notmuch-task/lib/notmuch-task-lib.bash`), so deleting and re-running
   on-launch (or replaying the import) yields the identical UUID again every
   time.
   **on-launch is observation-only — it NEVER writes to notmuch.** The trigger
   tag (`todo` by default) stays on the message until the user changes the
   task's state in Taskwarrior, at which point on-modify writes the new notmuch
   tags.
   Re-imports of an already-mirrored message are harmless:
   the deterministic UUID (and the existing-key index) match the existing task,
   so no duplicate is ever created even though the message keeps its trigger tag
   across on-launch passes.
   When `init_age_from_notmuch=1` (the default), `fetch_messages` enrichment has
   pre-fetched each message's `Date` header, so `entry` is that timestamp
   (converted to TW compact UTC) and `age` is the email's age; `modified` is
   still the import moment.

### on-modify (Taskwarrior -> notmuch)

Reads the two JSON lines (original, modified).
If the task has no `notmuchid` UDA, or `sync_on_modify=0`, it passes the
modification through unchanged.
Otherwise it pushes the deltas as notmuch tag operations:

- `pending -> completed`:
  `notmuch tag +task-done -task-pending -todo -- id:<bare-id>` (from `done_tag`
  / `remove_on_done`), and the `notmuchstate` UDA is set to `task-done` in the
  emitted JSON.
- `completed -> pending`:
  `notmuch tag +task-pending -task-done -- id:<bare-id>`, UDA updated.
- `pending -> deleted`:
  `notmuch tag +task-deleted -task-pending -todo -- id:<bare-id>`, UDA updated.
- `deleted -> pending`:
  `notmuch tag +task-pending -task-deleted -- id:<bare-id>`, UDA updated.
- description changed:
  notmuch cannot edit a message's headers, so the change is passed through and a
  `Sync SKIPPED for <id>:
  description edit (notmuch has no edit)` feedback line explains why the local
  edit does not propagate.
- tags changed (if enabled via `sync_tags_on_modify=1`):
  added tags become `notmuch tag +a +b -- id:<bare-id>`, removed tags become `-c
  -d` on the same call.

The modified task JSON is always the **first** stdout line; feedback follows.
The hook never vetoes (always exit 0).

## Worked example

Config:

```conf
query=tag:todo
project=mail
```

Tag a couple of messages and run `task list`:

```sh
notmuch tag +todo -- id:20240102@example.org id:20240103@example.org
```

```text
ID St UUID     Age Project  Description          NotmuchID         NotmuchState
-- -- -------- --- -------- ------------------- ----------------- ------------
 -  P  a1b2...  2h mail     Fix the frobnicator  20240102@example. task-pending
 -  P  c3d4...  1d mail     Document the widget  20240103@example. task-pending
```

`task 1 done` fires `on-modify.notmuch-task`, which runs `notmuch tag +task-done
-task-pending -todo -- id:20240102@example.org` and writes
`notmuchstate:task-done` into the task.
The next `task` invocation runs `on-launch.notmuch-task`, which re-syncs from
notmuch:
the message is no longer in the `todo` pool (the trigger tag was stripped), so
it is not mirrored twice, and the mirror task keeps its state.

## Troubleshooting

- **`notmuch-task:
  config dir not found:
  ...`** — create `*.conf` files in the bundle's `notmuch-task/config.d/` (next
  to the hooks the installer deployed, see install step 2).
  Override the default location with the `${NOTMUCH_TASK_CONFIG_DIR}`
  environment variable.
- **`notmuch-task:
  notmuch binary ...
  failed its --version check`** — the hooks run `notmuch --version` on launch.
  If your notmuch build lacks that flag, set `notmuch_bin` to a wrapper that
  answers it.
- **No messages mirrored** — run `notmuch search tag:todo` by hand and confirm
  it returns the messages you expect; `notmuch tag +todo` anything you want
  imported.
  The trigger tag is what makes a message import-eligible.
  `quiet=0` shows hook feedback on stderr.
- **Tasks not appearing** — verify `query` matches something, that the config
  file is named `*.conf`/`*.bash` in the bundle's `config.d/`, and that `task
  diag` lists both hooks as executable.
- **Hooks not running** — confirm `hooks=1` in `~/.taskrc`, that the files in
  `~/.task/hooks/` are executable, and check `task diag`.
  Debug with `task rc.debug.hooks=2 list`.
- **Description keeps reverting** — message Subjects are mirrored on launch (the
  email is the source of truth).
  Set `sync_description_on_launch=0` to keep local edits.
- **State tags don't match the task list** — the tags a task's message carries
  (`task-pending`/`task-done`/`task-deleted`) are set by on-modify and on first
  import.
  If you hand-edit notmuch tags, on-launch logs a soft warning and leaves the
  task alone (Taskwarrior is authoritative for state); fix the tags by hand.

## Quirks & TODOs

- `sync_tags_on_modify=0` by default — tag sync is conservative.
- **Description edits do not propagate back to the email**:
  notmuch cannot edit a message's headers, so a Taskwarrior description change
  is passed through locally but never written to the message.
  on-modify reports the skip; on-launch will re-sync the description to the
  Subject on the next invocation unless `sync_description_on_launch=0`.
- `init_age_from_notmuch=0` skips the per-message `notmuch show` enrichment
  entirely, so imported tasks get no Subject-derived description either — they
  are bare `notmuchid` tasks with `entry` at the import moment.
- The launch hook runs before **every** `task` command (including reports), so
  it adds a small notmuch round-trip to each invocation.
  Slow down your `query` rather than mirroring the whole index.
- Deleted/waiting tasks with a `notmuchid` are preserved as-is; re-adding a
  deliberately deleted mirror is a manual act.
- Internal `task` calls always run with `rc.hooks=off rc.color=no`, so the hooks
  never recurse and never emit color codes.
- Test with `bash tests/test-notmuch-task.bash` (stubs `notmuch`, throws away
  `TASKDATA`).

