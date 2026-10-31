#+build !windows
package tests_core_os

import "core:fmt"
import "core:os"
import "core:log"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

// One at a time: each of these opens descriptors, or reads which are open
// and what a number holds, and the runner runs tests in threads of one process.
process_tests: sync.Mutex

@(test)
test_process_exec :: proc(t: ^testing.T) {
	sync.mutex_lock(&process_tests)
	defer sync.mutex_unlock(&process_tests)

	state, stdout, stderr, err := os.process_exec({
		command = {"echo", "hellope"},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)

	if err == .Unsupported {
		log.warn("process_exec unsupported")
		return
	}

	testing.expect_value(t, state.exited,  true)
	testing.expect_value(t, state.success, true)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(stdout), "hellope\n")
	testing.expect_value(t, string(stderr), "")
}

// A child gets the parent's inheritable descriptors and its standard
// streams, nothing of process_start's own: the /dev/null it opens for a
// stream the description leaves out is not passed on through the exec.
// The child shell prints each of the descriptors 3 to 9 that is open in
// it (sh redirects only single-digit ones).
@(test)
test_process_start_leaks_no_descriptor :: proc(t: ^testing.T) {
	sync.mutex_lock(&process_tests)
	defer sync.mutex_unlock(&process_tests)

	want := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&want)
	for fd in 3 ..= 9 {
		flags := posix.fcntl(posix.FD(fd), .GETFD)
		if flags != -1 && flags & posix.FD_CLOEXEC == 0 {
			fmt.sbprintf(&want, "%d\n", fd)
		}
	}
	state, stdout, stderr, err := os.process_exec({
		command = {"/bin/sh", "-c", `for f in 3 4 5 6 7 8 9; do (: <&$f) 2>/dev/null && echo $f; done; true`},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)

	if err == .Unsupported {
		log.warn("process_exec unsupported")
		return
	}

	testing.expect_value(t, err, nil)
	testing.expect_value(t, state.success, true)
	testing.expect_value(t, string(stdout), strings.to_string(want))
}

// A read end whose descriptor was closed under it (by a stray close
// elsewhere) is no empty pipe: pipe_has_data reports an error, so
// process_exec's read loop, which polls until an error, EOF or
// Broken_Pipe, ends instead of spinning.
@(test)
test_pipe_has_data_on_a_closed_descriptor :: proc(t: ^testing.T) {
	sync.mutex_lock(&process_tests)
	defer sync.mutex_unlock(&process_tests)

	// A number no open in another test's thread takes: those get the lowest free.
	null := posix.open("/dev/null", {.CLOEXEC})
	fd := posix.fcntl(null, .DUPFD_CLOEXEC, i32(200))
	posix.close(null)
	if !testing.expect(t, fd != -1, "dup failed") {
		return
	}
	r := os.new_file(uintptr(fd), "closed")
	defer os.close(r)
	posix.close(posix.FD(fd))
	has_data, perr := os.pipe_has_data(r)
	testing.expect_value(t, has_data, false)
	testing.expectf(t, perr != nil, "a closed descriptor reads as an empty pipe (err %v)", perr)
}
