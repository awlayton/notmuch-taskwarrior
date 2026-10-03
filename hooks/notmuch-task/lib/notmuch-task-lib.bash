# notmuch-task shared library.
#
# Sourced by hooks/on-launch.notmuch-task and hooks/on-modify.notmuch-task.
# Safe under `set -u`. Feedback goes to stderr via notmuch_task::log so hook
# stdout stays machine-clean (one JSON line per stdout for on-modify, nothing
# for on-launch).
#
# Configuration model: the hooks iterate every `*.conf` (or `*.bash`)
# file in the bundle's `notmuch-task/config.d/` (next to the installed
# hooks) - or in `${NOTMUCH_TASK_CONFIG_DIR}` if set. Each file is its own
# whole config (`set_config_defaults` reapplies per iteration). Filename
# alphabetical order is the iteration order; prefix with a number
# (10-, 20-) for explicit control. on-launch's per-record project is
# baked at queue time so multi-config flows don't all share the last-
# loaded config's project.
#
# Public functions:
#   notmuch_task::die "msg"                    print msg to stderr, exit 1
#   notmuch_task::log "msg"                    timestamped line on stderr unless
#                                              quiet=1
#   notmuch_task::set_config_defaults          reset all config globals to the
#                                              built-in defaults (called by
#                                              source_config_file at the top
#                                              of each per-config iteration)
#   notmuch_task::source_config_file <path>    source one config file with full
#                                              defaults applied first; re-
#                                              exports globals for the calling
#                                              hook. rc 1 if the file is missing
#                                              or sourcing fails
#   notmuch_task::list_config_files <dir>      print sorted *.conf / *.bash paths
#                                              under <dir>, one per line
#                                              (hidden files skipped). rc 1 if
#                                              <dir> doesn't exist
#   notmuch_task::require_notmuch              rc 1 if $notmuch_bin is missing on
#                                              PATH or `notmuch --version` fails
#   notmuch_task::fetch_messages               use the currently sourced config's
#                                              `query`. Print a flattened JSON
#                                              array of messages on stdout;
#                                              each record carries the bare
#                                              message-id plus Subject/From/Date
#                                              (and the message's tags) when
#                                              init_age_from_notmuch=1. When
#                                              init_age_from_notmuch=0 the
#                                              per-message enrichment is skipped
#                                              and only bare-id records are
#                                              returned. non-zero rc only on a
#                                              notmuch search failure
#   notmuch_task::notmuch_to_task_import_record  build one TW-style JSON record
#     "<flat>" "<now_ts>"                      (with deterministic UUID baked
#                                              from the message-id, status
#                                              pending, notmuchstate UDA set to
#                                              the pending state tag, and the
#                                              full RFC 5322 id with angle
#                                              brackets in the notmuchmsgid UDA)
#                                              from a single flat notmuch
#                                              record. `project` is taken from
#                                              the flat record first (so
#                                              multi-config flows don't share
#                                              the last-loaded config's
#                                              project) and falls back to the
#                                              global. entry = message Date
#                                              (converted via iso_to_twdate) or
#                                              `<now_ts>`. modified = `<now_ts>`.
#                                              Echo compact JSON; rc 1 if the
#                                              id is empty or msgid_to_uuid
#                                              fails
#   notmuch_task::task_import_records          read newline-delimited flat records
#                                              on stdin, batch them into a
#                                              single `[ {...}, {...} ]` JSON
#                                              file, and `task import` it.
#                                              rc 0 on no-op or success;
#                                              propagated from `task import`
#                                              on failure
#   notmuch_task::iso_to_twdate <iso>          convert an RFC 5322 / ISO 8601
#                                              datetime (`...T...Z` or
#                                              `Wed, 15 Jan 2020 10:30:00 +0000`)
#                                              into TW's compact UTC form
#                                              (`YYYYMMDDTHHMMSSZ`). uses
#                                              `date -u -d` from GNU coreutils.
#                                              rc 1 on parse failure
#   notmuch_task::msgid_to_uuid "ID"           print a stable 36-char UUID-shaped
#                                              hex string derived
#                                              deterministically from the bare
#                                              message-id (md5 of
#                                              `namespace|id`). rc 1 when
#                                              md5sum/md5 is missing
#   notmuch_task::state_for_tw_status <status> echo the state tag
#                                              (`$pending_tag`/`$done_tag`/
#                                              `$deleted_tag`) that mirrors the
#                                              given TW status. Used by
#                                              on-modify to set the
#                                              notmuchstate UDA
#   notmuch_task::apply_state_tags <id> <state>  call `notmuch tag +N -M ... -- id:<id>`
#                                              with the +/- list derived from
#                                              `$pending_tag`/`$done_tag`/
#                                              `$deleted_tag`/`$remove_on_*`
#                                              for the target state. Source of
#                                              truth for the state-tag
#                                              convention; hooks stay small.
#                                              rc propagated from `notmuch tag`
#   notmuch_task::in_list "value" "a|b|c"      0 if value matches a '|'-separated
#                                              token (case-insensitive,
#                                              whitespace tolerant)
#   notmuch_task::task "$@"                    run `task` with rc.hooks=off and
#                                              rc.color=no, scoped to the data
#                                              dir resolved (in order) from
#                                              $NOTMUCH_TASK_DATA_DIR, $TASKDATA,
#                                              ${XDG_DATA_HOME:-$HOME/.local/share}/task,
#                                              or $HOME/.task as last-resort
#                                              fallback. Honours rc:$NOTMUCH_TASK_RC

notmuch_task::die() {
  printf 'notmuch-task: %s\n' "$*" >&2
  exit 1
}

notmuch_task::log() {
  [ "${quiet:-0}" = "1" ] && return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Match a value against a pipe-separated list of tokens (case-insensitive,
# tolerant of surrounding whitespace). Returns 0 on match.
notmuch_task::in_list() {
  local value="$1" list="$2"
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  list=$(printf '%s' "$list" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[[:space:]]*|[[:space:]]*/;/g' \
      -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//')
  [ -n "$value" ] && [[ ";$list;" == *";$value;"* ]]
}

# Apply defaults for all known config keys. Called at the top of every
# per-config iteration so an unset key in one config does not bleed values
# from a previous iteration.
notmuch_task::set_config_defaults() {
  project=""
  project_tag_prefix=""
  query="tag:todo"
  notmuchid_uda="notmuchid"
  notmuchthreadid_uda="notmuchthreadid"
  notmuchstate_uda="notmuchstate"
  notmuchmsgid_uda="notmuchmsgid"
  trigger_tag="todo"
  pending_tag="task-pending"
  done_tag="task-done"
  deleted_tag="task-deleted"
  remove_on_pending="todo"
  remove_on_done="todo"
  remove_on_deleted="todo"
  sync_on_modify=1
  sync_tags_on_modify=0
  sync_description_on_launch=1
  notmuch_bin="notmuch"
  quiet=0
  init_age_from_notmuch=1
}

# Source one config file with full defaults applied first. Returns 1 if the
# file is missing or sourcing fails; callers (the on-launch/on-modify hooks)
# log a warning and skip that config rather than abort.
notmuch_task::source_config_file() {
  local config_path="$1"
  [ -n "$config_path" ] || return 1
  notmuch_task::set_config_defaults

  if [ ! -f "$config_path" ]; then
    return 1
  fi

  # Relax `set -u` while sourcing: a stray unset-variable reference in a
  # user's config must not abort the hook mid-flight.
  local rc=0
  if [[ $- == *u* ]]; then
    set +u
    # shellcheck disable=SC1090
    . "$config_path"
    rc=$?
    set -u
  else
    # shellcheck disable=SC1090
    . "$config_path"
    rc=$?
  fi
  [ "$rc" -ne 0 ] && return 1

  # Re-export so per-config values are visible to the calling hook.
  export project project_tag_prefix query
  export notmuchid_uda notmuchthreadid_uda notmuchstate_uda notmuchmsgid_uda
  export trigger_tag pending_tag done_tag deleted_tag
  export remove_on_pending remove_on_done remove_on_deleted
  export sync_on_modify sync_tags_on_modify sync_description_on_launch
  export notmuch_bin quiet init_age_from_notmuch
  return 0
}

# Print config files in a directory, one per line, sorted lexicographically.
# Recognized extensions are `*.conf` and `*.bash` (both shell-sourceable).
# Hidden files (names starting with `.`) are skipped. Returns 1 if the
# directory does not exist.
notmuch_task::list_config_files() {
  local dir="${1:?dir required}"
  [ -d "$dir" ] || return 1
  local f
  # shellcheck disable=SC2045
  for f in $(LC_ALL=C ls -1A "$dir" 2>/dev/null | LC_ALL=C sort); do
    case "$f" in
      *.conf | *.bash) printf '%s/%s\n' "$dir" "$f" ;;
    esac
  done
}

# Verify the configured notmuch binary is usable. Logs a warning and returns
# 1 (not a hard exit) so the hooks stay fail-open when notmuch is missing.
notmuch_task::require_notmuch() {
  if ! command -v "$notmuch_bin" >/dev/null 2>&1; then
    notmuch_task::log "notmuch binary '$notmuch_bin' not found on PATH; skipping sync"
    return 1
  fi
  if ! "$notmuch_bin" --version >/dev/null 2>&1; then
    notmuch_task::log "notmuch binary '$notmuch_bin' failed its --version check (is it really notmuch?)"
    return 1
  fi
  return 0
}

# Run `task` with hooks disabled and colors off, scoped to the data dir the
# outer Taskwarrior actually used. Resolution order:
#   1. data: hook arg (provided by Taskwarrior v2 API; XDG-aware)
#   2. $TASKDATA env var
#   3. ${XDG_DATA_HOME:-$HOME/.local/share}/task (XDG Base Directory Spec)
#   4. $HOME/.task (legacy TW 2.x default)
# Passing rc:$NOTMUCH_TASK_RC keeps the same rc file (UDAs, data location) in
# effect for internal calls. TASKDATA is set explicitly because it takes
# precedence over data.location from the rc file.
notmuch_task::task() {
  local data_dir="${NOTMUCH_TASK_DATA_DIR:-${TASKDATA:-${XDG_DATA_HOME:-$HOME/.local/share}/task}}"
  local rc_args=()
  if [ -n "${NOTMUCH_TASK_RC:-}" ]; then
    rc_args=(rc:"$NOTMUCH_TASK_RC")
  fi
  TASKDATA="$data_dir" task rc.hooks=off rc.color=no "${rc_args[@]}" "$@"
}

# Build a single TW-style JSON task record (compact, no trailing newline)
# from one `flat` notmuch record line. The UUID is the deterministic
# value derived from the THREAD id (one task per matching thread), so
# the same thread-id yields the same UUID on every import even as
# messages arrive, change, or rotate within the thread. The `id` from
# the flat record is the root message-id of that thread and is stored
# in the `notmuchid` UDA so on-modify can run `notmuch tag -- id:` on
# a specific message. The `entry` field is the root message's Date
# header when available (notmuch_task::fetch_messages enriches it),
# otherwise the caller-supplied "now". `modified` is always the import
# moment. Optional fields (project, notmuchid UDA, notmuchthreadid UDA,
# notmuchstate UDA, notmuchmsgid UDA) are added conditionally. Status
# is always "pending": Taskwarrior is authoritative for state, so a
# message's notmuch tags never decide the imported task's status.
# Returns 1 when the thread-id is empty or the UUID derivation fails.
notmuch_task::notmuch_to_task_import_record() {
  local flat="$1" now_ts="$2"
  local id thread_id subject date_iso entry_ts modified_ts proj full_id state_tag uuid_str

  thread_id=$(printf '%s' "$flat" | jq -r '.thread // ""')
  [ -n "$thread_id" ] || return 1

  id=$(printf '%s' "$flat" | jq -r '.id // ""')

  # UUID from the THREAD id so re-imports of the same thread re-bind to
  # the same task even after messages within the thread churn.
  uuid_str=$(notmuch_task::msgid_to_uuid "$thread_id")
  [ -n "$uuid_str" ] || return 1

  subject=$(printf '%s' "$flat" | jq -r '.subject // ""')
  date_iso=$(printf '%s' "$flat" | jq -r '.date // ""')
  # init_age_from_notmuch gates ONLY the date -> entry translation. The
  # show call itself always runs so the Subject (description) is always
  # populated; with init_age_from_notmuch=0 the task's `entry` falls back
  # to the import moment regardless of what `date` was harvested.
  if [ "${init_age_from_notmuch:-1}" = "1" ] && [ -n "$date_iso" ]; then
    entry_ts=$(notmuch_task::iso_to_twdate "$date_iso" 2>/dev/null) || entry_ts="$now_ts"
  else
    entry_ts="$now_ts"
  fi
  modified_ts="$now_ts"

  # Project resolution, in priority order:
  #   1. Derived from <project_tag_prefix>:<X> notmuch tags on the message
  #      (alphabetical first match wins). When project_tag_prefix is set,
  #      this OVERRIDES the per-config literal even if both are configured,
  #      because the email itself declares its project.
  #   2. Per-config $project baked into the flat record at queue time (in
  #      on-launch), so multi-config flows don't all inherit the last loaded
  #      config's literal.
  #   3. The global $project literal (set in the LATEST sourced config).
  proj=""
  if [ -n "${project_tag_prefix:-}" ]; then
    proj=$(printf '%s' "$flat" | jq -r --arg pfx "$project_tag_prefix" \
      '(.tags // []) | map(select(startswith($pfx + ":")))
       | if length == 0 then "" else sort | .[0] | sub("^" + $pfx + ":"; "") end' \
      2>/dev/null) || proj=""
  fi
  if [ -z "$proj" ]; then
    proj=$(printf '%s' "$flat" | jq -r '.project // ""')
    [ -z "$proj" ] && proj="$project"
  fi

  # Full RFC 5322 root-message id (with angle brackets) is informational only.
  full_id=""
  [ -n "$id" ] && full_id="<${id}>"
  state_tag=$(notmuch_task::state_for_tw_status "pending")

  # Compose optional fields with conditional jq additions. The
  # `{($key_uda): $jk}` form sets a dynamic object key.
  jq -c -n \
    --arg uuid "$uuid_str" \
    --arg desc "$subject" \
    --arg entry_ts "$entry_ts" \
    --arg mod_ts "$modified_ts" \
    --arg proj "$proj" \
    --arg mid "$id" \
    --arg tid "$thread_id" \
    --arg full_id "$full_id" \
    --arg state_tag "$state_tag" \
    --arg id_uda "$notmuchid_uda" \
    --arg thread_uda "$notmuchthreadid_uda" \
    --arg state_uda "$notmuchstate_uda" \
    --arg full_uda "$notmuchmsgid_uda" \
    '{
      uuid: $uuid,
      status: "pending",
      description: $desc,
      entry: $entry_ts,
      modified: $mod_ts
    }
    + (if $proj != "" then {project: $proj} else {} end)
    + (if $mid != "" and $id_uda != "" then {($id_uda): $mid} else {} end)
    + (if $tid != "" and $thread_uda != "" then {($thread_uda): $tid} else {} end)
    + (if $full_id != "" and $full_uda != "" then {($full_uda): $full_id} else {} end)
    + (if $state_tag != "" and $state_uda != "" then {($state_uda): $state_tag} else {} end)'
}

# Read newline-delimited flat records on stdin, build a JSON array file, and
# `task import` it. Returns 0 on no-op (zero records) or success; propagated
# from `task import` on failure. The temp file is created inside $TASKDATA
# when possible so existing data-dir cleanup reaches it; otherwise /tmp.
notmuch_task::task_import_records() {
  local records_csv="" item record entry_ts

  entry_ts=$(date -u '+%Y%m%dT%H%M%SZ')
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    record=$(notmuch_task::notmuch_to_task_import_record "$item" "$entry_ts" 2>/dev/null) || continue
    [ -z "$record" ] && continue
    if [ -z "$records_csv" ]; then
      records_csv="$record"
    else
      records_csv="${records_csv},${record}"
    fi
  done

  [ -z "$records_csv" ] && return 0

  local file
  if file=$(mktemp -p "${TASKDATA:-${TMPDIR:-/tmp}}" 2>/dev/null); then
    :
  else
    file=$(mktemp)
  fi
  # Each $record is a compact JSON object (no embedded newlines), so
  # comma-joining them and wrapping in [...] yields a valid `task import`
  # array. Earlier attempts to round-trip through `jq -R -s` produced an
  # array of strings, which `task import` rejects (and on TW 3.x segfaults).
  printf '[%s]\n' "$records_csv" > "$file"

  notmuch_task::task import "$file"
  local rc=$?
  rm -f "$file"
  return "$rc"
}

# Print a flattened JSON array of messages on stdout. The snapshot comes from
# `notmuch search --output=messages --format=json "$query"`, which yields a
# JSON array of bare message-ids. When init_age_from_notmuch=1 (the default)
# each id is enriched with a per-message `notmuch show --format=json id:<id>`
# call that harvests Subject / From / Date (and the message's current tags for
# the on-launch state-mismatch warning). Setting init_age_from_notmuch=0 skips
# that enrichment and returns bare-id records (no Subject/Date). Fails open:
# returns "[]" (rc 0) when jq is missing or the query is empty, rc 1 only when
# the notmuch search itself fails.
notmuch_task::fetch_messages() {
  if ! command -v jq >/dev/null 2>&1; then
    notmuch_task::log "warning: jq not found; cannot parse notmuch output, skipping sync"
    printf '%s\n' "[]"
    return 0
  fi

  if [ -z "$query" ]; then
    notmuch_task::log "warning: no query configured; skipping sync"
    printf '%s\n' "[]"
    return 0
  fi

  local raw
  raw=$("$notmuch_bin" search --output=threads --format=json "$query" 2>/dev/null) || return 1

  local recs=() thread_id rec flat
  # One task per matching THREAD. `notmuch search --output=threads` gives
  # us the thread-id set; `notmuch show thread:<id>` gives us the thread
  # tree. Harvesting the root message object via `..`+`first` lets us
  # ignore reply messages and pick exactly one record per thread (the
  # root carries the Subject, From, Date, and tags). For matched root
  # messages notmuch returns `match: true`; we pick the first message
  # object whose id looks like an email id (`<...>@...`) so a degenerate
  # reply-only thread still resolves to the first message present.
  while IFS= read -r thread_id; do
    [ -z "$thread_id" ] && continue
    rec=""
    local show_json
    show_json=$("$notmuch_bin" show --format=json "thread:$thread_id" 2>/dev/null) || show_json=""
    if [ -n "$show_json" ]; then
      rec=$(printf '%s' "$show_json" | jq -c --arg tid "$thread_id" \
        '[.. | objects | select(((.id|type) == "string") and (.id|contains("@")))] | first // {} |
         {id: .id,
          thread: $tid,
          subject: (.subject // .headers.Subject // ""),
          from: (.authors // .headers.From // ""),
          date: (.headers.Date // ""),
          tags: (.tags // [])}' \
        2>/dev/null) || rec=""
    fi
    # Fall back to a thread-id-only record when the show call failed;
    # the thread still imports (entry=now, no subject) but with no
    # usable root message-id we leave `id` empty so on-modify won't
    # accidentally tag the wrong message.
    if [ -z "$rec" ]; then
      rec=$(jq -c -n --arg tid "$thread_id" '{thread: $tid, id: "", subject: "", from: "", date: "", tags: []}')
    fi
    recs+=("$rec")
  done < <(printf '%s' "$raw" | jq -r '.[]' 2>/dev/null)

  if [ "${#recs[@]}" -eq 0 ]; then
    printf '%s\n' "[]"
  else
    flat=$(printf '%s\n' "${recs[@]}" | jq -s -c '.' 2>/dev/null) || flat="[]"
    printf '%s' "$flat"
  fi
}

# Convert an RFC 5322 / ISO 8601 datetime string (e.g. "Wed, 15 Jan 2020
# 10:30:00 +0000" or "2026-03-31T09:20:42.499-0700") into Taskwarrior's
# compact UTC format ("20200115T103000Z"). Uses `date -u -d` from GNU
# coreutils, which handles RFC 5322 dates, fractional seconds, and POSIX
# timezone offsets correctly. jq's `fromdate` was tried but does not
# consistently accept the `+0000` offset form that email Date headers use.
# macOS/BSD users can install `coreutils` (provides `gdate`) and set
# `notmuch_bin=...` accordingly; this hookset targets Linux first. Returns 1
# on parse failure.
notmuch_task::iso_to_twdate() {
  local iso="$1"
  [ -n "$iso" ] || return 1
  date -u -d "$iso" '+%Y%m%dT%H%M%SZ' 2>/dev/null
}

# Echo the state tag that mirrors the given Taskwarrior status. Used by
# on-modify to set the notmuchstate UDA on status changes.
notmuch_task::state_for_tw_status() {
  case "$1" in
    pending) printf '%s\n' "${pending_tag:-task-pending}" ;;
    completed) printf '%s\n' "${done_tag:-task-done}" ;;
    deleted) printf '%s\n' "${deleted_tag:-task-deleted}" ;;
    *) return 1 ;;
  esac
}

# Source of truth for the state-tag convention: call `notmuch tag +N -M ... --
# id:<id>` with the +/- list that moves a message into the given TW state.
# The state's own tag is added; the other state tags and the state's
# remove_on_* tags (default: the trigger tag, so a message leaves the "import
# me" pool on first import) are removed. rc propagated from `notmuch tag`.
notmuch_task::apply_state_tags() {
  local id="$1" new_state="$2"
  [ -n "$id" ] || return 1

  local add="" remove=""
  case "$new_state" in
    pending)
      add="${pending_tag:-task-pending}"
      remove="${done_tag:-task-done} ${deleted_tag:-task-deleted} ${remove_on_pending:-}"
      ;;
    completed)
      add="${done_tag:-task-done}"
      remove="${pending_tag:-task-pending} ${deleted_tag:-task-deleted} ${remove_on_done:-}"
      ;;
    deleted)
      add="${deleted_tag:-task-deleted}"
      remove="${pending_tag:-task-pending} ${done_tag:-task-done} ${remove_on_deleted:-}"
      ;;
    *) return 1 ;;
  esac

  # Tags are single tokens (notmuch forbids spaces in tag names), so word
  # splitting on the space-joined add/remove lists is deliberate.
  local tag_args=() t
  for t in $add; do
    [ -n "$t" ] && tag_args+=("+$t")
  done
  for t in $remove; do
    [ -n "$t" ] && tag_args+=("-$t")
  done
  [ "${#tag_args[@]}" -eq 0 ] && return 0

  "$notmuch_bin" tag "${tag_args[@]}" -- "id:$id"
}

# Stable namespace discriminator for the deterministic message-id -> task UUID
# mapping. Pinning to a literal keeps the mapping immune to upstream
# changes that might repurpose symbolic UUIDs. (A function, not a variable:
# bash forbids '::' in variable names but allows it in function names, which
# every other notmuch_task::* name here is too.)
notmuch_task::NOTMUCHID_UUID_NS() {
  printf '%s\n' "notmuch-task-msgid-derived-v1"
}

# Print a stable, UUID-shaped 36-char hex string for the given bare
# message-id. Identical inputs always produce identical output, regardless of
# when or where this is called. Returns 1 on failure (e.g. md5sum missing).
notmuch_task::msgid_to_uuid() {
  local id="$1" ns
  ns=$(notmuch_task::NOTMUCHID_UUID_NS) || return 1
  [ -n "$id" ] || return 1

  local md5_cmd=""
  if command -v md5sum >/dev/null 2>&1; then
    md5_cmd="md5sum"
  elif command -v md5 >/dev/null 2>&1; then
    md5_cmd="md5"
  fi
  [ -n "$md5_cmd" ] || return 1

  local md5
  if ! md5=$(printf '%s' "${ns}|${id}" | $md5_cmd 2>/dev/null | awk '{print $1}'); then
    return 1
  fi
  [ "${#md5}" -ge 32 ] || return 1

  printf '%s-%s-%s-%s-%s\n' \
    "${md5:0:8}" "${md5:8:4}" "${md5:12:4}" "${md5:16:4}" "${md5:20:12}"
}