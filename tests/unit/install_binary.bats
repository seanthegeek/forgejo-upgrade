#!/usr/bin/env bats
# install_binary and require_prev_slot: swapping the binary without losing
# what the operator put on it. This file carries the AGENTS.md fact "cp -p and
# install drop file capabilities and other extended attributes" - the reason
# for cp --preserve=all,xattr on the way out and the --attributes-only copy
# back - and the -T/--remove-destination half of it, which is what keeps a
# directory or a symlink at the .prev name from swallowing the backup or
# overwriting an unrelated file. require_prev_slot is the check that says so
# before the service is stopped rather than after.
#
# Everything here runs as an ordinary user inside the per-test directory: the
# installed file's own uid, gid and mode are what install is asked to
# reproduce, so no root is needed. The stop, backup, start and health check
# around it are not exercised anywhere; they need a Forgejo host.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  D=$BATS_TEST_TMPDIR/inst
  mkdir -p "$D"
  DEST=$D/forgejo
  NEW=$D/forgejo-new
}

# An ACL entry for a uid with no passwd entry, so the case does not depend on
# a "nobody" account existing here.
ACL_UID=65534

# The ACL entry each copy has to carry over. Its own assertion so that a
# failure names the file and shows what getfacl actually said.
assert_has_acl() {  # $1 = file
  # -n keeps the uid numeric: 65534 resolves to a name on most hosts and to
  # nothing on some, and the entry is what matters, not its spelling.
  if ! getfacl -cn "$1" 2>/dev/null | grep -q "^user:$ACL_UID:r-x"; then
    printf 'expected an ACL entry for uid %s on %s; getfacl said:\n%s\n' \
      "$ACL_UID" "$1" "$(getfacl -cn "$1" 2>&1)" >&2
    return 1
  fi
}

@test "install_binary puts the new binary in place and keeps the old mode, xattr and ACL" {
  skip_unless setfacl
  skip_unless getfacl
  printf 'OLD BINARY\n' > "$DEST"
  chmod 750 "$DEST"
  local rc=0
  set_xattr "$DEST" user.test kept || rc=$?
  if [[ $rc -eq 2 ]]; then skip "no setfattr and no python3 to set an extended attribute"; fi
  if [[ $rc -ne 0 ]]; then
    printf 'could not set an extended attribute on %s (status %s)\n' "$DEST" "$rc" >&2
    return 1
  fi
  setfacl -m "u:$ACL_UID:r-x" "$DEST"
  # A date nothing else here could produce, so "the file says when it was
  # installed" is a real observation and not today by accident.
  touch -d 2020-01-02T03:04:05 "$DEST"
  printf 'NEW BINARY\n' > "$NEW"
  chmod 755 "$NEW"

  run --separate-stderr in_script 'install_binary "$1" "$2"' "$NEW" "$DEST"
  assert_status 0
  assert_stderr_contains "Keeping previous binary at $DEST.prev"

  assert_equal "NEW BINARY" "$(cat "$DEST")"
  assert_equal "750" "$(stat -c %a "$DEST")"
  assert_equal "kept" "$(get_xattr "$DEST" user.test)"
  assert_has_acl "$DEST"
  # install gives the new file the current time; --no-preserve=timestamps on
  # the attribute copy leaves it there, so the binary dates from the upgrade.
  assert_equal "$(date +%Y)" "$(date -d "@$(stat -c %Y "$DEST")" +%Y)"

  assert_equal "OLD BINARY" "$(cat "$DEST.prev")"
  assert_equal "750" "$(stat -c %a "$DEST.prev")"
  assert_equal "kept" "$(get_xattr "$DEST.prev" user.test)"
  assert_has_acl "$DEST.prev"
  assert_equal "2020-01-02" "$(date -d "@$(stat -c %Y "$DEST.prev")" +%Y-%m-%d)"
}

@test "a directory at .prev makes install_binary fail with nothing touched" {
  # cp -T refuses to replace a directory with a file, so the backup can never
  # end up inside it as .prev/<name> with the rollback finding nothing.
  printf 'OLD\n' > "$DEST"
  chmod 750 "$DEST"
  printf 'NEW\n' > "$NEW"
  mkdir "$DEST.prev"
  run --separate-stderr in_script 'export LC_ALL=C; install_binary "$1" "$2"' "$NEW" "$DEST"
  if [[ $status -eq 0 ]]; then
    printf 'expected install_binary to fail with a directory at %s.prev\n' "$DEST" >&2
    return 1
  fi
  assert_stderr_contains "cannot overwrite directory"
  assert_equal "OLD" "$(cat "$DEST")"
  assert_equal "" "$(ls -A "$DEST.prev")"
}

@test "a symlink at .prev is replaced, and the file it pointed at is left alone" {
  # --remove-destination unlinks the link itself first. Without it cp would
  # write through the link and overwrite an unrelated file.
  printf 'OLD\n' > "$DEST"
  chmod 750 "$DEST"
  printf 'NEW\n' > "$NEW"
  printf 'VICTIM\n' > "$D/victim"
  ln -s "$D/victim" "$DEST.prev"
  run --separate-stderr in_script 'install_binary "$1" "$2"' "$NEW" "$DEST"
  assert_status 0
  assert_equal "VICTIM" "$(cat "$D/victim")"
  assert_equal "regular file" "$(stat -c %F "$DEST.prev")"
  assert_equal "OLD" "$(cat "$DEST.prev")"
  assert_equal "NEW" "$(cat "$DEST")"
}

# --- require_prev_slot -------------------------------------------------------

@test "require_prev_slot passes when there is no .prev at all" {
  : > "$DEST"
  run --separate-stderr in_script 'require_prev_slot "$1"' "$DEST"
  assert_status 0
  assert_equal "" "$stderr"
}

@test "require_prev_slot passes for a plain file at .prev" {
  : > "$DEST"
  : > "$DEST.prev"
  run --separate-stderr in_script 'require_prev_slot "$1"' "$DEST"
  assert_status 0
  assert_equal "" "$stderr"
}

@test "require_prev_slot dies on a directory at .prev, naming the type it found" {
  : > "$DEST"
  mkdir "$DEST.prev"
  run --separate-stderr in_script 'export LC_ALL=C; require_prev_slot "$1"' "$DEST"
  assert_status 1
  assert_stderr_contains "$DEST.prev is a directory, not a plain file"
  assert_stderr_contains "Move whatever is at $DEST.prev out of the way and rerun. Nothing has been stopped"
}

@test "require_prev_slot dies on a symlink at .prev" {
  : > "$DEST"
  printf 'VICTIM\n' > "$D/victim"
  ln -s "$D/victim" "$DEST.prev"
  run --separate-stderr in_script 'export LC_ALL=C; require_prev_slot "$1"' "$DEST"
  assert_status 1
  assert_stderr_contains "$DEST.prev is a symbolic link, not a plain file"
  assert_stderr_contains "Nothing has been stopped"
}

@test "require_prev_slot dies on a dangling symlink at .prev" {
  # stat is asked about the link, not about what it points at, so a link with
  # no target still reports "symbolic link" rather than failing to describe it.
  : > "$DEST"
  ln -s "$D/no-such-file" "$DEST.prev"
  run --separate-stderr in_script 'export LC_ALL=C; require_prev_slot "$1"' "$DEST"
  assert_status 1
  assert_stderr_contains "$DEST.prev is a symbolic link, not a plain file"
}

@test "a symlink at .prev pointing at an executable file is refused although -x passes on it" {
  # This is the case a bare [[ -x $bin.prev ]] waves through, and rollback's
  # mv -fT would then install the link itself in front of the service. The
  # control below shows -x passing on the very same link.
  : > "$DEST"
  printf '#!/bin/sh\necho "forgejo version 16.0.5"\n' > "$D/target"
  chmod 755 "$D/target"
  ln -s "$D/target" "$DEST.prev"
  run --separate-stderr in_script '
    export LC_ALL=C
    if [[ -x $1.prev ]]; then printf "CONTROL: -x passes on the link\n"; fi
    printf "CONTROL: stat says %s\n" "$(stat -c %F "$1.prev")"
    require_prev_slot "$1"
  ' "$DEST"
  assert_status 1
  assert_output_contains "CONTROL: -x passes on the link"
  assert_output_contains "CONTROL: stat says symbolic link"
  assert_stderr_contains "$DEST.prev is a symbolic link, not a plain file"
}
