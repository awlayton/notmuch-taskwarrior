#!/usr/bin/env bash
#
# test-notmuch-task.bash -- fast shell tests for the notmuch-task hooks.
#
# Stubs `notmuch` with a fake script earlier on PATH (canned search/show
# JSON, logged tag calls) and runs the hooks directly against a throwaway
# TASKDATA. No bats, no install needed.
#
# Input:  none.
# Output: PASS/FAIL lines plus a summary on stdout.
# Exit:   0 if all tests pass, 1 otherwise.
#
# Synopsis:
#   bash tests/test-notmuch-task.bash
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$REPO_DIR/hooks"
EXAMPLE_CONF="$REPO_DIR/config.d/example-default.conf"

# --- Throwaway environment ---------------------------------------------------
TASKDATA=""
TASKRC=""
TEST_CONFIG_DIR=""
FAKE_BIN=""
FAKE_NOTMUCH_TAG_LOG=""
OUT=""
ERR=""

cleanup() {
    rm -rf -- "$TASKDATA" "$TASKRC" "$TEST_CONFIG_DIR" "$FAKE_BIN" "$FAKE_NOTMUCH_TAG_LOG" "$OUT" "$ERR"
}
trap cleanup EXIT

TASKDATA=$(mktemp -d)
TASKRC=$(mktemp)
TEST_CONFIG_DIR=$(mktemp -d)
EXAMPLE_CONF="$REPO_DIR/config.d/example-default.conf"
mkdir -p "$TEST_CONFIG_DIR"
# Seed the test config dir with the default example so most tests just work
# without needing to write config files themselves. Tests that exercise
# multi-config flow wipe and replace these.
cp "$EXAMPLE_CONF" "$TEST_CONFIG_DIR/00-default.conf"

FAKE_BIN=$(mktemp -d)
FAKE_NOTMUCH_TAG_LOG=$(mktemp)
OUT=$(mktemp)
ERR=$(mktemp)

# --- Fake notmuch stub -------------------------------------------------------
cat >"$FAKE_BIN/notmuch" <<'BASH'
#!/usr/bin/env bash
# Fake notmuch for tests. The subcommand is read off $1, so the same fake
# serves a --version check, a search snapshot, per-id show enrichment (for
# the init-age / description / state-tag paths), and tag writes in the same
# on-launch / on-modify pass.
set -u
if [ "${1:-}" = "--version" ]; then
    echo "notmuch 0.40 (fake for tests)"
    exit 0
fi

cmd="${1:-}"
case "$cmd" in
    search)
        # args: --output=messages --format=json <query> -- the query is the
        # only positional token, so drive distinct canned ids per query.
        query=""
        for arg in "$@"; do
            case "$arg" in
                --output=messages | --format=json) ;;
                *) query="$arg" ;;
            esac
        done
        case "$query" in
            "tag:waiting-for")
                # The multi-config test's second query returns the WAITING
                # family so each config gets its own snapshot.
                printf '["waiting-1@host","waiting-2@host"]\n'
                ;;
            "tag:acme-source")
                # The project-tag override test's query returns a single
                # message whose only project:* tag is `project:acme`.
                printf '["proj1@host"]\n'
                ;;
            "tag:no-proj")
                # The no-match test's query returns a message with no
                # project:* tags, so the literal $project fallback wins.
                printf '["proj3@host"]\n'
                ;;
            "tag:mixed")
                # The alphabetical-first test's query returns a message
                # carrying BOTH project:beta and project:alpha, so the
                # alphabetical-first selection is observable.
                printf '["proj2@host"]\n'
                ;;
            *)
                # Default: every other query (including tag:todo) returns
                # the MSGID family so existing tests keep working.
                printf '["msgid-1@host","msgid-2@host"]\n'
                ;;
        esac
        ;;
    show)
        # args: --format=json id:<bare-id>
        id=""
        for arg in "$@"; do
            case "$arg" in
                id:*) id="${arg#id:}" ;;
            esac
        done
        # Per-id canned headers. Dates are +0000 so the conversion to TW
        # compact UTC is identity (no TZ math). msgid-2@host deliberately
        # carries the task-done tag so the "does NOT push state" test can
        # expose a notmuch->TW state mismatch.
        case "$id" in
            msgid-1@host)
                # Mirror real notmuch 0.40 single-id show shape: subject and
                # authors are at the top level as null/unset; the actual Subject
                # and From live inside headers. (When tested against real
                # notmuch, top-level .subject was null and only headers.Subject
                # carried the value - the lib's filter falls back to
                # headers.Subject.)
                cat <<'JSON'
[[{"id":"msgid-1@host","thread":"t1","timestamp":1579084200,"date_relative":"2020-01-15","subject":null,"authors":null,"tags":["todo"],"headers":{"Subject":"Fix the frobnicator","From":"ada@example.com","Date":"Wed, 15 Jan 2020 10:30:00 +0000"}}]]
JSON
                ;;
            msgid-2@host)
                cat <<'JSON'
[[{"id":"msgid-2@host","thread":"t2","timestamp":1559386800,"date_relative":"2019-06-01","subject":null,"authors":null,"tags":["task-done"],"headers":{"Subject":"Document the widget","From":"bob@example.com","Date":"Sat, 01 Jun 2019 08:00:00 +0000"}}]]
JSON
                ;;
            waiting-1@host)
                cat <<'JSON'
[[{"id":"waiting-1@host","thread":"t3","timestamp":1583816400,"date_relative":"2020-03-10","subject":null,"authors":null,"tags":["waiting-for"],"headers":{"Subject":"Waiting item one","From":"carol@example.com","Date":"Tue, 10 Mar 2020 09:00:00 +0000"}}]]
JSON
                ;;
            waiting-2@host)
                cat <<'JSON'
[[{"id":"waiting-2@host","thread":"t4","timestamp":1587380400,"date_relative":"2020-04-20","subject":null,"authors":null,"tags":["waiting-for"],"headers":{"Subject":"Waiting item two","From":"dave@example.com","Date":"Mon, 20 Apr 2020 11:00:00 +0000"}}]]
JSON
                ;;
            proj1@host)
                # Single project:acme tag, plus the trigger. project_tag_prefix
                # test 1: tag wins over the literal $project=fallback-literal.
                cat <<'JSON'
[[{"id":"proj1@host","thread":"t5","timestamp":1579084200,"subject":null,"authors":null,"tags":["todo","project:acme"],"headers":{"Subject":"Acme item","From":"acme@example.com","Date":"Wed, 15 Jan 2020 10:30:00 +0000"}}]]
JSON
                ;;
            proj2@host)
                # Two project:* tags out of order so the alphabetical-first
                # selection is observable.
                cat <<'JSON'
[[{"id":"proj2@host","thread":"t6","timestamp":1579084200,"subject":null,"authors":null,"tags":["todo","project:beta","project:alpha"],"headers":{"Subject":"Mixed item","From":"m@example.com","Date":"Wed, 15 Jan 2020 10:30:00 +0000"}}]]
JSON
                ;;
            proj3@host)
                # No project:* tags at all. Test 2: literal $project applies.
                cat <<'JSON'
[[{"id":"proj3@host","thread":"t7","timestamp":1579084200,"subject":null,"authors":null,"tags":["todo"],"headers":{"Subject":"Plain item","From":"p@example.com","Date":"Wed, 15 Jan 2020 10:30:00 +0000"}}]]
JSON
                ;;
            *)
                printf '[]\n'
                ;;
        esac
        ;;
    tag)
        # Log every tag invocation for assertions.
        printf '%s\n' "$*" >> "${FAKE_NOTMUCH_TAG_LOG:-/dev/null}"
        ;;
    *)
        echo "unknown notmuch cmd=$cmd" >&2
        exit 1
        ;;
esac
BASH
chmod +x "$FAKE_BIN/notmuch"

# Test taskrc: hooks on, pointing at the repo hooks, UDAs defined. The
# data.location line is a convenience only; TASKDATA (env) takes precedence.
cat >"$TASKRC" <<EOF
hooks=1
hooks.location=$HOOKS_DIR
data.location=$TASKDATA
uda.notmuchid.type=string
uda.notmuchid.label=Notmuch Message-ID
uda.notmuchstate.type=string
uda.notmuchstate.label=Notmuch State
uda.notmuchmsgid.type=string
uda.notmuchmsgid.label=Notmuch RFC822 Message-ID
EOF

export TASKDATA
export TASKRC
export PATH="$FAKE_BIN:$PATH"
export NOTMUCH_TASK_CONFIG_DIR="$TEST_CONFIG_DIR"
export FAKE_NOTMUCH_TAG_LOG

# task helpers: setup and assertions must not re-trigger hooks.
t() { task rc.hooks=off rc.color=no "$@"; }
tx() { task rc.hooks=off rc.color=no rc.json.array=on export 2>/dev/null; }

# Clear task data between tests. TW 2.x uses *.data files, TW 3.x a sqlite db.
fresh_tasks() { rm -f -- "$TASKDATA"/*.data "$TASKDATA"/taskchampion.sqlite3; }

# Add a config file to the test config dir.
add_config() {  # add_config <name> <body>
    local name="$1" body="$2"
    printf '%s\n' "$body" > "$TEST_CONFIG_DIR/$name"
}

# Wipe all config files in the test config dir so the next test starts
# with a clean slate.
reset_configs() {
    rm -f -- "$TEST_CONFIG_DIR"/*.conf \
        "$TEST_CONFIG_DIR"/*.bash \
        "$TEST_CONFIG_DIR"/.[!.]* 2>/dev/null || true
}

pass=0
fail=0

run_test() { # run_test <name> <fn>
  local name="$1" fn="$2"
  if "$fn"; then
    pass=$((pass + 1))
    echo "PASS: $name"
  else
    fail=$((fail + 1))
    echo "FAIL: $name"
  fi
}

# --- Test cases --------------------------------------------------------------

test_launch_adds_new() {
  fresh_tasks
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  tx | jq -e 'length == 2' >/dev/null || return 1
  tx | jq -e '[.[] | select(.notmuchid != null)] | length == 2' >/dev/null || return 1
  tx | jq -e '[.[] | select(.notmuchstate != null)] | length == 2' >/dev/null || return 1
  tx | jq -e '[.[] | select(.project == "notmuch")] | length == 2' >/dev/null || return 1
  # msgid-1: subject becomes description, full id lands in notmuchmsgid.
  tx | jq -e '.[] | select(.notmuchid == "msgid-1@host") | .status == "pending" and .description == "Fix the frobnicator" and .notmuchmsgid == "<msgid-1@host>" and .notmuchstate == "task-pending"' >/dev/null || return 1
  return 0
}

test_launch_creates_task_with_deterministic_uuid() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  fresh_tasks
  local uuid_1 uuid_2 actual_1 actual_2
  uuid_1=$(bash -c "source '$REPO_DIR/hooks/notmuch-task/lib/notmuch-task-lib.bash'; notmuch_task::msgid_to_uuid msgid-1@host") || return 1
  uuid_2=$(bash -c "source '$REPO_DIR/hooks/notmuch-task/lib/notmuch-task-lib.bash'; notmuch_task::msgid_to_uuid msgid-2@host") || return 1
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  actual_1=$(tx | jq -r '.[] | select(.notmuchid == "msgid-1@host") | .uuid')
  actual_2=$(tx | jq -r '.[] | select(.notmuchid == "msgid-2@host") | .uuid')
  [ "$actual_1" = "$uuid_1" ] || { echo "want msgid-1 uuid=$uuid_1 got $actual_1" >&2; return 1; }
  [ "$actual_2" = "$uuid_2" ] || { echo "want msgid-2 uuid=$uuid_2 got $actual_2" >&2; return 1; }
  return 0
}

test_launch_reimport_yields_same_uuid() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  fresh_tasks
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  local u1 u2
  u1=$(tx | jq -r '.[] | select(.notmuchid == "msgid-1@host") | .uuid')
  [ -n "$u1" ] || return 1
  # Delete the msgid-1 task so the next on-launch pass sees it as a matched
  # deleted task. The deterministic UUID must survive (never clobbered, never
  # re-created with a different id). Pipe "y" into the delete so TW's
  # interactive prompt is satisfied when running under a non-TTY test harness.
  yes y | t "$u1" delete >/dev/null 2>&1 || return 1
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  u2=$(tx | jq -r '.[] | select(.notmuchid == "msgid-1@host") | .uuid')
  [ "$u1" = "$u2" ] || { echo "want $u1 got $u2" >&2; return 1; }
  return 0
}

test_launch_reconciles_description() {
  fresh_tasks
  t add notmuchid:msgid-1@host description:Old >/dev/null 2>&1 || return 1
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  # The Subject wins (sync_description_on_launch=1 default).
  tx | jq -e '.[] | select(.notmuchid == "msgid-1@host") | .description == "Fix the frobnicator"' >/dev/null || return 1
  # State was NOT pushed: task stays pending (TW is authoritative).
  tx | jq -e '.[] | select(.notmuchid == "msgid-1@host") | .status == "pending"' >/dev/null || return 1
  return 0
}

test_launch_does_not_push_state() {
  fresh_tasks
  # msgid-2@host carries the task-done tag in the fake show output, so
  # notmuch's implied state is "completed" while the TW task is pending.
  # on-launch must NOT push that state back; it only logs a soft warning.
  t add notmuchid:msgid-2@host description:"Document the widget" >/dev/null 2>&1 || return 1
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  tx | jq -e '.[] | select(.notmuchid == "msgid-2@host") | .status == "pending"' >/dev/null || return 1
  # msgid-1@host was unmatched and still imported alongside.
  tx | jq -e '.[] | select(.notmuchid == "msgid-1@host") | .status == "pending"' >/dev/null || return 1
  return 0
}

test_launch_skips_mirroring_during_command_add_or_import() {
    fresh_tasks
    # Simulate TW firing on-launch while the user is mid-add (or mid-import).
    # The hook must short-circuit to exit 0 without touching the task list.
    bash "$HOOKS_DIR/on-launch.notmuch-task" \
        'api:2' 'args:task add something' 'command:add' 'rc:/tmp/x' 'data:/tmp/x' 'version:3.4.2' \
        >/dev/null 2>&1 || return 1
    tx | jq -e 'length == 0' >/dev/null || return 1

    bash "$HOOKS_DIR/on-launch.notmuch-task" \
        'api:2' 'args:task import ./x.json' 'command:import' 'rc:/tmp/x' 'data:/tmp/x' 'version:3.4.2' \
        >/dev/null 2>&1 || return 1
    tx | jq -e 'length == 0' >/dev/null || return 1
    return 0
}

test_launch_init_age_from_notmuch_created() {
    fresh_tasks
    # Default config has init_age_from_notmuch=1. The fake show returns
    # Date="Wed, 15 Jan 2020 10:30:00 +0000" for msgid-1@host (+0000 offset,
    # so the conversion to TW compact UTC is identity).
    bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
    local k1_entry k1_modified
    k1_entry=$(tx | jq -r '.[] | select(.notmuchid == "msgid-1@host") | .entry')
    [ "$k1_entry" = "20200115T103000Z" ] || \
        { echo "want msgid-1 entry=20200115T103000Z got=$k1_entry" >&2; return 1; }
    # modified is the import moment, distinct from entry.
    k1_modified=$(tx | jq -r '.[] | select(.notmuchid == "msgid-1@host") | .modified')
    [ -n "$k1_modified" ] || return 1
    [ "$k1_modified" != "$k1_entry" ] || \
        { echo "modified should differ from entry, both=$k1_entry" >&2; return 1; }
    return 0
}

test_launch_init_age_off_uses_now() {
    fresh_tasks
    # Override the config dir with init_age_from_notmuch=0: enrichment is
    # skipped, so entry defaults to the import moment ("now") rather than the
    # message Date.
    local override_dir k1_entry
    override_dir=$(mktemp -d)
    printf 'query=tag:todo\ninit_age_from_notmuch=0\n' >"$override_dir/00-disable.conf"
    NOTMUCH_TASK_CONFIG_DIR="$override_dir" \
        bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 ||
        { rm -rf "$override_dir"; return 1; }
    k1_entry=$(tx | jq -r '.[] | select(.notmuchid == "msgid-1@host") | .entry')
    rm -rf "$override_dir"
    # It must NOT equal the Date-derived timestamp; that confirms enrichment
    # was skipped and entry defaulted to "now".
    [ "$k1_entry" != "20200115T103000Z" ] || return 1
    [ -n "$k1_entry" ] || return 1
    return 0
}

test_launch_missing_config_exits_nonzero() {
    fresh_tasks
    if NOTMUCH_TASK_CONFIG_DIR=/nonexistent bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

test_launch_iterates_multiple_configs() {
    fresh_tasks
    # Wipe the default config; build two configs explicitly.
    reset_configs
    add_config "10-default.conf" 'query=tag:todo
project=alpha'
    add_config "20-multi.conf" 'query=tag:waiting-for
project=beta'
    bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
    # The union of both configs' snapshots is 4 messages; the dedup-by-id
    # index in the hook ensures no overlap is needed for this test to pass.
    tx | jq -e 'length == 4' >/dev/null || return 1
    tx | jq -e '.[] | select(.notmuchid == "msgid-1@host") | .project == "alpha"' >/dev/null || return 1
    tx | jq -e '.[] | select(.notmuchid == "msgid-2@host") | .project == "alpha"' >/dev/null || return 1
    tx | jq -e '.[] | select(.notmuchid == "waiting-1@host") | .project == "beta"' >/dev/null || return 1
    tx | jq -e '.[] | select(.notmuchid == "waiting-2@host") | .project == "beta"' >/dev/null || return 1
    return 0
}

test_msgid_to_uuid_deterministic() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  local u1 u2
  u1=$(bash -c "source '$REPO_DIR/hooks/notmuch-task/lib/notmuch-task-lib.bash'; notmuch_task::msgid_to_uuid msgid-1@host") || return 1
  u2=$(bash -c "source '$REPO_DIR/hooks/notmuch-task/lib/notmuch-task-lib.bash'; notmuch_task::msgid_to_uuid msgid-1@host") || return 1
  [ -n "$u1" ] || return 1
  [ "$u1" = "$u2" ] || return 1
  return 0
}

test_msgid_to_uuid_unique() {
  command -v md5sum >/dev/null 2>&1 || { echo "SKIP: md5sum not found"; return 0; }
  local u1 u2
  u1=$(bash -c "source '$REPO_DIR/hooks/notmuch-task/lib/notmuch-task-lib.bash'; notmuch_task::msgid_to_uuid msgid-1@host") || return 1
  u2=$(bash -c "source '$REPO_DIR/hooks/notmuch-task/lib/notmuch-task-lib.bash'; notmuch_task::msgid_to_uuid msgid-2@host") || return 1
  [ -n "$u1" ] && [ -n "$u2" ] || return 1
  [ "$u1" != "$u2" ] || return 1
  return 0
}

test_modify_completes_triggers_tag_transition() {
  fresh_tasks
  t add notmuchid:msgid-1@host description:"Fix the frobnicator" >/dev/null 2>&1 || return 1
  orig=$(tx | jq -c '.[0]')
  mod=$(printf '%s' "$orig" | jq -c '.status = "completed"')
  : >"$FAKE_NOTMUCH_TAG_LOG"
  printf '%s\n%s\n' "$orig" "$mod" |
    bash "$HOOKS_DIR/on-modify.notmuch-task" >"$OUT" 2>"$ERR" || return 1
  # First stdout line is the modified JSON with the notmuchstate UDA set to
  # the done state tag.
  head -n1 "$OUT" | jq -e '.status == "completed" and .notmuchstate == "task-done"' >/dev/null || return 1
  grep -q '+task-done' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  grep -q -- '-task-pending' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  grep -q -- '-todo' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  grep -q -- 'id:msgid-1@host' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  return 0
}

test_modify_deleted_triggers_tag_transition() {
  fresh_tasks
  t add notmuchid:msgid-1@host description:"Fix the frobnicator" >/dev/null 2>&1 || return 1
  orig=$(tx | jq -c '.[0]')
  mod=$(printf '%s' "$orig" | jq -c '.status = "deleted"')
  : >"$FAKE_NOTMUCH_TAG_LOG"
  printf '%s\n%s\n' "$orig" "$mod" |
    bash "$HOOKS_DIR/on-modify.notmuch-task" >"$OUT" 2>"$ERR" || return 1
  head -n1 "$OUT" | jq -e '.status == "deleted" and .notmuchstate == "task-deleted"' >/dev/null || return 1
  grep -q '+task-deleted' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  grep -q -- '-task-pending' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  grep -q -- 'id:msgid-1@host' "$FAKE_NOTMUCH_TAG_LOG" || return 1
  return 0
}

test_modify_no_notmuchid_is_pass_through() {
  fresh_tasks
  t add description:Hello >/dev/null 2>&1 || return 1
  orig=$(tx | jq -c '.[0]')
  mod=$(printf '%s' "$orig" | jq -c '.description = "Changed"')
  : >"$FAKE_NOTMUCH_TAG_LOG"
  printf '%s\n%s\n' "$orig" "$mod" |
    bash "$HOOKS_DIR/on-modify.notmuch-task" >"$OUT" 2>"$ERR" || return 1
  [ "$(head -n1 "$OUT")" = "$mod" ] || return 1
  [ ! -s "$FAKE_NOTMUCH_TAG_LOG" ] || return 1
  return 0
}

test_modify_description_edit_reported_skipped() {
  fresh_tasks
  t add notmuchid:msgid-1@host description:"Old desc" >/dev/null 2>&1 || return 1
  orig=$(tx | jq -c '.[0]')
  mod=$(printf '%s' "$orig" | jq -c '.description = "New desc"')
  : >"$FAKE_NOTMUCH_TAG_LOG"
  printf '%s\n%s\n' "$orig" "$mod" |
    bash "$HOOKS_DIR/on-modify.notmuch-task" >"$OUT" 2>"$ERR" || return 1
  # Pass-through unchanged on stdout line 1...
  [ "$(head -n1 "$OUT")" = "$mod" ] || return 1
  # ...but the skip is reported so users understand why local edits don't
  # propagate.
  grep -q 'Sync SKIPPED' "$OUT" || return 1
  grep -q 'description edit (notmuch has no edit)' "$OUT" || return 1
  # No tag op was issued.
  [ ! -s "$FAKE_NOTMUCH_TAG_LOG" ] || return 1
  return 0
}

# --- XDG-aware install destination -------------------------------------------
# Run install.bash in a sandboxed HOME / XDG_CONFIG_HOME and verify the default
# destination honors the XDG Base Directory Spec. Hooks are config files and
# therefore live under XDG_CONFIG_HOME/task/hooks (NOT XDG_DATA_HOME/task).

run_install_in_sandbox() { # run_install_in_sandbox <home> <xdg_config_home> <task_hooks_dir>
  local home="$1" xdg_cfg="$2" thd="$3"
  mkdir -p "$home"
  [ -n "$xdg_cfg" ] && mkdir -p "$xdg_cfg"
  # Note: we do NOT export these inside the sandbox shell; install.bash reads
  # them as regular env vars, but we also have to scope HOME so the
  # ${HOME:?} fallbacks used by install.bash and the lib see the sandbox.
  HOME="$home" XDG_CONFIG_HOME="$xdg_cfg" TASK_HOOKS_DIR="$thd" bash install.bash --force 2>&1
}

test_install_xdg_config_home_respected() {
  local base
  base=$(mktemp -d)
  local home="$base/home" xdg_cfg="$base/xdg_cfg"
  local out
  out=$(run_install_in_sandbox "$home" "$xdg_cfg" "") || {
    rm -rf -- "$base"
    return 1
  }
  if [[ "$out" != *"installed: $xdg_cfg/task/hooks/on-launch.notmuch-task"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $xdg_cfg/task/hooks/notmuch-task/lib/notmuch-task-lib.bash"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $xdg_cfg/task/hooks/notmuch-task/notmuch-task.taskrc"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  # Example configs land in the bundle's config.d/ so the hooks have
  # visible starter configs on first install.
  if [[ "$out" != *"installed: $xdg_cfg/task/hooks/notmuch-task/config.d/example-default.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $xdg_cfg/task/hooks/notmuch-task/config.d/example-multi.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_xdg_empty_uses_dot_config() {
    local base
    base=$(mktemp -d)
    local home="$base/home"
    local out expected_hook expected_lib expected_taskrc
    out=$(run_install_in_sandbox "$home" "" "") || { rm -rf -- "$base"; return 1; }
    expected_hook="$home/.config/task/hooks/on-launch.notmuch-task"
    expected_lib="$home/.config/task/hooks/notmuch-task/lib/notmuch-task-lib.bash"
    expected_taskrc="$home/.config/task/hooks/notmuch-task/notmuch-task.taskrc"
  if [[ "$out" != *"installed: $expected_hook"* ]] ||
    [[ "$out" != *"installed: $expected_lib"* ]] ||
    [[ "$out" != *"installed: $expected_taskrc"* ]] ||
    [[ "$out" != *"installed: $home/.config/task/hooks/notmuch-task/config.d/example-default.conf"* ]] ||
    [[ "$out" != *"installed: $home/.config/task/hooks/notmuch-task/config.d/example-multi.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_task_hooks_dir_overrides() {
  local base
  base=$(mktemp -d)
  local home="$base/home" xdg_cfg="$base/xdg_cfg" custom="$base/custom"
  local out
  out=$(run_install_in_sandbox "$home" "$xdg_cfg" "$custom/hooks") || {
    rm -rf -- "$base"
    return 1
  }
  if [[ "$out" != *"installed: $custom/hooks/on-launch.notmuch-task"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  # Lib lives inside the notmuch-task/ bundle under HOOK_DEST (alongside the
  # hooks).
  if [[ "$out" != *"installed: $custom/hooks/notmuch-task/lib/notmuch-task-lib.bash"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $custom/hooks/notmuch-task/notmuch-task.taskrc"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $custom/hooks/notmuch-task/config.d/example-default.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  if [[ "$out" != *"installed: $custom/hooks/notmuch-task/config.d/example-multi.conf"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  # Neither XDG_CONFIG_HOME nor legacy ~/.task path should be chosen when
  # TASK_HOOKS_DIR is set.
  if [[ "$out" == *"installed: $xdg_cfg/task/hooks/"* ]] ||
    [[ "$out" == *"installed: $home/.config/task/"* ]] ||
    [[ "$out" == *"installed: $home/.task/hooks/"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_xdg_preempts_legacy_dot_task() {
  # With XDG_CONFIG_HOME set, the legacy ~/.task/hooks path (and the
  # ~/.local/share/task/hooks DATA-home path) must never appear.
  local base
  base=$(mktemp -d)
  local home="$base/home" xdg_cfg="$base/xdg_cfg"
  local out
  out=$(run_install_in_sandbox "$home" "$xdg_cfg" "") || {
    rm -rf -- "$base"
    return 1
  }
  if [[ "$out" == *"$home/.task/hooks/"* ]] ||
    [[ "$out" == *"$home/.local/share/task/hooks/"* ]]; then
    rm -rf -- "$base"
    return 1
  fi
  rm -rf -- "$base"
  return 0
}

test_install_prints_include_line_not_pasted_snippet() {
    # The installer must tell the user to add ONE `include` line and must
    # NOT print the UDA / hooks block contents to paste.
    local base home out
    base=$(mktemp -d)
    home="$base/home"
    out=$(run_install_in_sandbox "$home" "" "") || { rm -rf -- "$base"; return 1; }
    local include_line
    include_line="include $home/.config/task/hooks/notmuch-task/notmuch-task.taskrc"
    if [[ "$out" != *"$include_line"* ]]; then
        echo "missing include line: $include_line" >&2
        rm -rf -- "$base"
        return 1
    fi
    # Reject any of the old pasted contents.
    if [[ "$out" == *"uda.notmuchid.type=string"* ]] || \
       [[ "$out" == *"hooks.location="* ]]; then
        echo "installer still prints the previous snippet contents" >&2
        rm -rf -- "$base"
        return 1
    fi
    # The taskrc fragment was actually installed alongside the hooks.
    [ -f "$home/.config/task/hooks/notmuch-task/notmuch-task.taskrc" ] || \
        { rm -rf -- "$base"; return 1; }
    rm -rf -- "$base"
    return 0
}

# --- Run ---------------------------------------------------------------------
run_test "on-launch adds new mirrored tasks" test_launch_adds_new
run_test "on-launch creates tasks with deterministic message-id UUIDs" test_launch_creates_task_with_deterministic_uuid
run_test "on-launch reimport yields same UUID after delete" test_launch_reimport_yields_same_uuid
run_test "on-launch reconciles description of matched task when out of sync" test_launch_reconciles_description
run_test "on-launch does NOT push state from notmuch to TW" test_launch_does_not_push_state
run_test "on-launch skips mirroring during command:add|import" test_launch_skips_mirroring_during_command_add_or_import
run_test "on-launch inherits task entry from message Date" test_launch_init_age_from_notmuch_created
run_test "on-launch falls back to now when init_age_from_notmuch=0" test_launch_init_age_off_uses_now
run_test "on-launch exits non-zero when config dir is missing" test_launch_missing_config_exits_nonzero
run_test "on-launch iterates multiple config.d files" test_launch_iterates_multiple_configs
run_test "msgid_to_uuid is deterministic for same id" test_msgid_to_uuid_deterministic
run_test "msgid_to_uuid differs for different ids" test_msgid_to_uuid_unique
run_test "on-modify completed task triggers notmuch tag add/remove" test_modify_completes_triggers_tag_transition
run_test "on-modify deleted task triggers notmuch tag add/remove" test_modify_deleted_triggers_tag_transition
run_test "on-modify task without notmuchid passes through" test_modify_no_notmuchid_is_pass_through
run_test "on-modify description edit is reported as skipped (notmuch has no edit)" test_modify_description_edit_reported_skipped
run_test "install respects XDG_CONFIG_HOME" test_install_xdg_config_home_respected
run_test "install falls back to ~/.config/task when XDG_CONFIG_HOME is unset" test_install_xdg_empty_uses_dot_config
run_test "install honors TASK_HOOKS_DIR override" test_install_task_hooks_dir_overrides
run_test "install does not fall back to legacy paths when XDG set" test_install_xdg_preempts_legacy_dot_task
run_test "install prints include line not pasted snippet" test_install_prints_include_line_not_pasted_snippet

# --- project-tag-driven project derivation -----------------------------------
# When project_tag_prefix is set, the project field on a mirrored task is
# derived from <prefix>:<X> tags on the corresponding notmuch message.
# Alphabetical-first match wins; the literal `project=` value is the
# fallback when no matching tag exists.

test_launch_project_from_tag_overrides_literal() {
  fresh_tasks
  reset_configs
  # proj1 has tag `project:acme`; literal project=fallback-literal must NOT win.
  add_config "00-acme.conf" 'query=tag:acme-source
project=fallback-literal
project_tag_prefix=project'
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  tx | jq -e '.[] | select(.notmuchid == "proj1@host") | .project == "acme"' >/dev/null || return 1
  return 0
}

test_launch_project_from_tag_falls_back_to_literal() {
  fresh_tasks
  reset_configs
  # proj3 has NO project:* tags; literal project=fallback-literal must apply.
  add_config "00-noproj.conf" 'query=tag:no-proj
project=fallback-literal
project_tag_prefix=project'
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  tx | jq -e '.[] | select(.notmuchid == "proj3@host") | .project == "fallback-literal"' >/dev/null || return 1
  return 0
}

test_launch_project_from_tag_picks_alphabetical_first() {
  fresh_tasks
  reset_configs
  # proj2 carries project:beta AND project:alpha (in that order).
  # Alphabetical first (alpha) must win.
  add_config "00-mixed.conf" 'query=tag:mixed
project_tag_prefix=project'
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  tx | jq -e '.[] | select(.notmuchid == "proj2@host") | .project == "alpha"' >/dev/null || \
    { echo "expected project=alpha for proj2@host (got $(tx | jq -r '.[] | select(.notmuchid=="proj2@host") | .project'))" >&2; return 1; }
  return 0
}

# --- on-launch is observation-only -------------------------------------------
# State-tag application is exclusively on-modify's job. on-launch must
# NEVER call `notmuch tag` - the FAKE_NOTMUCH_TAG_LOG must be empty
# after an on-launch pass even when the hook imports new tasks.

test_launch_does_not_mutate_notmuch_tags() {
  fresh_tasks
  reset_configs
  # Re-add the default example config so on-launch actually has work to do
  # (reset_configs wiped the directory; without a config, on-launch exits
  # early with "no *.conf files" and the post-condition length==2 below
  # would fail before reaching the tag-log check).
  cp "$EXAMPLE_CONF" "$TEST_CONFIG_DIR/00-default.conf"
  : >"$FAKE_NOTMUCH_TAG_LOG"
  bash "$HOOKS_DIR/on-launch.notmuch-task" >/dev/null 2>&1 || return 1
  # Imports did happen (sanity check before the no-mutation assertion).
  tx | jq -e 'length == 2' >/dev/null || return 1
  if [ -s "$FAKE_NOTMUCH_TAG_LOG" ]; then
    echo "on-launch wrote to notmuch: $(cat "$FAKE_NOTMUCH_TAG_LOG")" >&2
    return 1
  fi
  return 0
}

run_test "on-launch derives project from <project_tag_prefix>:* tag (overrides literal)" test_launch_project_from_tag_overrides_literal
run_test "on-launch falls back to literal project when no matching tag exists" test_launch_project_from_tag_falls_back_to_literal
run_test "on-launch picks alphabetical-first matching tag when multiple are present" test_launch_project_from_tag_picks_alphabetical_first
run_test "on-launch NEVER writes to notmuch (only on-modify may)" test_launch_does_not_mutate_notmuch_tags

echo
echo "Tests passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]