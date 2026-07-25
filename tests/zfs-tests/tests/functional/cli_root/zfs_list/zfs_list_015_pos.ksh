#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# Recursive zfs list propagates iterator errors without emitting partial JSON.
#
# STRATEGY:
# 1. Inject an immediate snapshot iterator error and require zfs list to fail.
# 2. Inject an error after the first snapshot and suppress partial JSON output.
# 3. Propagate child-filesystem errors before and after projected batch use.
# 4. Propagate a child snapshot batch error through filesystem recursion.
# 5. Unwind recursion depth after each iterator error so later explicit
#    datasets are visited.
# 6. Propagate projected bookmark iterator errors.
#

verify_runnable "global"
set -o pipefail

DATASET="$TESTPOOL/$TESTFS/list_iterator_errors"
CHILD_DATASET="$DATASET/child"
LATER_DATASET="$TESTPOOL/$TESTFS/list_iterator_errors_later"
INJECTED_OUTPUT="$TEST_BASE_DIR/list_iterator_errors_output.$$"
ERROR_OUTPUT="$TEST_BASE_DIR/list_iterator_errors_error.$$"
MARKER="$TEST_BASE_DIR/list_iterator_errors_marker.$$"

function cleanup
{
	rm -f "$INJECTED_OUTPUT" "$ERROR_OUTPUT" "$MARKER"
	datasetexists "$LATER_DATASET" && zfs destroy -r "$LATER_DATASET"
	datasetexists "$DATASET" && zfs destroy -r "$DATASET"
	log_must restore_tunable SNAPSHOT_LIST_BATCH_SIZE
}

function find_shim
{
	typeset helper helper_dir candidate

	helper=$(readlink -f "$(command -v snapshot_list_test)")
	helper_dir=${helper%/*}
	for candidate in \
	    "$helper_dir/.libs/libsnapshot_list_test_shim.so" \
	    "$helper_dir/libsnapshot_list_test_shim.so" \
	    "$STF_SUITE/bin/libsnapshot_list_test_shim.so"; do
		[[ -f "$candidate" ]] && print -- "$candidate" && return 0
	done
	return 1
}

function verify_single_injection
{
	typeset mode="$1"
	typeset -i calls

	calls=$(grep -Fxc "$mode" "$MARKER")
	(( calls == 1 )) ||
	    log_fail "$mode was injected $calls times; expected 1"
}

function run_injected_cli_failure
{
	typeset preload="$SHIM"

	[[ -n "$LD_PRELOAD" ]] && preload="$SHIM:$LD_PRELOAD"
	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='eintr' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "zfs list -H -p -t snapshot -o name '$DATASET' " \
	    "> '$INJECTED_OUTPUT'"
	log_must grep -Fx eintr "$MARKER"
	[[ ! -s "$INJECTED_OUTPUT" ]] ||
	    log_fail "failed projected listing produced snapshot output"
	log_must rm -f "$MARKER"
}

function run_injected_late_json_failure
{
	typeset preload="$SHIM"

	[[ -n "$LD_PRELOAD" ]] && preload="$SHIM:$LD_PRELOAD"
	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='enotsup_after_first' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "zfs list -j -p -t snapshot -o name '$DATASET' " \
	    "> '$INJECTED_OUTPUT'"
	log_must grep -Fx enotsup_after_first "$MARKER"
	[[ ! -s "$INJECTED_OUTPUT" ]] ||
	    log_fail "late batch failure produced partial JSON output"
	log_must rm -f "$MARKER"
}

function run_injected_recursive_errors
{
	typeset mode preload="$SHIM"

	[[ -n "$LD_PRELOAD" ]] && preload="$SHIM:$LD_PRELOAD"
	log_must zfs create "$CHILD_DATASET"
	log_must zfs snapshot "$CHILD_DATASET@only"
	log_must rm -f "$MARKER"
	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='dataset_eio' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "zfs list -j -p -r -t filesystem,snapshot -o name " \
	    "'$DATASET' > '$INJECTED_OUTPUT'"
	log_must grep -Fx dataset_eio "$MARKER"
	[[ ! -s "$INJECTED_OUTPUT" ]] ||
	    log_fail "child-filesystem error produced partial JSON output"
	log_must rm -f "$MARKER"

	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='dataset_eio_after_batch' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "ZFS_SNAPSHOT_LIST_TEST_TARGET='$CHILD_DATASET' " \
	    "zfs list -j -p -r -t filesystem,snapshot -o creation " \
	    "'$DATASET' > '$INJECTED_OUTPUT'"
	log_must grep -Fx dataset_eio_after_batch_batch "$MARKER"
	log_must grep -Fx dataset_eio_after_batch "$MARKER"
	[[ ! -s "$INJECTED_OUTPUT" ]] ||
	    log_fail "post-batch child-filesystem error produced partial JSON"
	log_must rm -f "$MARKER"

	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='child_snapshot_eio' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "ZFS_SNAPSHOT_LIST_TEST_TARGET='$CHILD_DATASET' " \
	    "zfs list -j -p -r -t snapshot -o creation " \
	    "'$DATASET' > '$INJECTED_OUTPUT'"
	log_must grep -Fx child_snapshot_eio "$MARKER"
	[[ ! -s "$INJECTED_OUTPUT" ]] ||
	    log_fail "child snapshot batch error produced partial JSON output"
	log_must rm -f "$MARKER"
	log_must zfs destroy -r "$CHILD_DATASET"

	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='dataset_eio' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "ZFS_SNAPSHOT_LIST_TEST_TARGET='$DATASET' " \
	    "zfs list -H -p -t filesystem,snapshot -d 1 -o name " \
	    "'$DATASET' '$LATER_DATASET' > '$INJECTED_OUTPUT'"
	verify_single_injection dataset_eio
	log_must grep -Fx "$LATER_DATASET@only" "$INJECTED_OUTPUT"
	log_must rm -f "$MARKER"

	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='child_snapshot_eio' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "ZFS_SNAPSHOT_LIST_TEST_TARGET='$DATASET' " \
	    "zfs list -H -p -t snapshot -d 1 -o name " \
	    "'$DATASET' '$LATER_DATASET' > '$INJECTED_OUTPUT'"
	verify_single_injection child_snapshot_eio
	[[ "$(<"$INJECTED_OUTPUT")" == "$LATER_DATASET@only" ]] ||
	    log_fail "snapshot error left later explicit dataset unvisited"
	log_must rm -f "$MARKER"

	log_mustnot eval "LD_PRELOAD='$preload' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MODE='bookmark_batched_eio' " \
	    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
	    "ZFS_SNAPSHOT_LIST_TEST_TARGET='$DATASET' " \
	    "zfs list -H -p -t snapshot,bookmark -d 1 -o name " \
	    "-s creation -s createtxg '$DATASET' '$LATER_DATASET' " \
	    "> '$INJECTED_OUTPUT' 2> '$ERROR_OUTPUT'"
	verify_single_injection bookmark_batched_eio
	log_must grep -Fx "$LATER_DATASET@only" "$INJECTED_OUTPUT"
	log_must rm -f "$MARKER"
	log_must rm -f "$ERROR_OUTPUT"

	for mode in bookmark_batched_enoent bookmark_batched_esrch \
	    bookmark_batched_eio; do
		log_must rm -f "$MARKER" "$ERROR_OUTPUT"
		log_mustnot eval "LD_PRELOAD='$preload' " \
		    "ZFS_SNAPSHOT_LIST_TEST_MODE='$mode' " \
		    "ZFS_SNAPSHOT_LIST_TEST_MARKER='$MARKER' " \
		    "zfs list -j -p -t snapshot,bookmark -d 1 -o creation " \
		    "'$DATASET' > '$INJECTED_OUTPUT' 2> '$ERROR_OUTPUT'"
		log_must grep -Fx "$mode" "$MARKER"
		[[ ! -s "$INJECTED_OUTPUT" ]] ||
		    log_fail "$mode produced partial JSON output"
	done
	log_must rm -f "$MARKER" "$ERROR_OUTPUT"
}

SHIM=$(find_shim) || log_unsupported "snapshot-list test shim not found"
log_onexit cleanup
log_assert "Recursive zfs list propagates iterator errors."

log_must save_tunable SNAPSHOT_LIST_BATCH_SIZE
log_must set_tunable32 SNAPSHOT_LIST_BATCH_SIZE 1024
log_must zfs create "$DATASET"
log_must zfs snapshot "$DATASET@m_oldest"
log_must zfs snapshot "$DATASET@z_middle"
log_must zfs snapshot "$DATASET@a_newest"
log_must zfs bookmark "$DATASET@m_oldest" "$DATASET#normal"
log_must zfs create "$LATER_DATASET"
log_must zfs snapshot "$LATER_DATASET@only"

run_injected_cli_failure
log_must set_tunable32 SNAPSHOT_LIST_BATCH_SIZE 1
run_injected_late_json_failure
log_must set_tunable32 SNAPSHOT_LIST_BATCH_SIZE 1024
run_injected_recursive_errors

log_pass "Recursive zfs list propagates iterator errors."
