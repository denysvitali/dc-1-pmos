/*
 * Chromium 155's file-patcher sandbox admits legacy positional writes but
 * traps pwritev2. musl 1.2.6 now probes pwritev2(RWF_NOAPPEND) from pwrite
 * and pwritev; SIGSYS prevents its normal ENOSYS fallback from running.
 * Use that fallback for Chromium only, retaining its seccomp policy.
 *
 * Like musl's fallback, refuse O_APPEND descriptors rather than silently
 * appending when the caller requested a positional write. Remove this shim
 * once Chromium's sandbox handles the new musl syscall probe.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#if !defined(__aarch64__) && !defined(__x86_64__)
#error This compatibility shim requires a 64-bit Linux syscall ABI
#endif

static ssize_t
write_at(int fd, const void *data, size_t count, off_t offset, int vector)
{
	pthread_testcancel();
	int flags = fcntl(fd, F_GETFL);
	if (flags < 0)
		return -1;
	if (flags & O_APPEND) {
		errno = EOPNOTSUPP;
		return -1;
	}

	/* Make the syscall a cancellation point, preserving the caller's mode.
	 * There are no owned resources or library locks in the async window. */
	int previous;
	int error = pthread_setcanceltype(PTHREAD_CANCEL_ASYNCHRONOUS, &previous);
	if (error) {
		errno = error;
		return -1;
	}
	ssize_t result;
	if (vector)
		result = syscall(SYS_pwritev, fd, data, count, (long)offset,
		                 (long)((uint64_t)offset >> 32));
	else
		result = syscall(SYS_pwrite64, fd, data, count, offset);
	int saved_errno = errno;
	pthread_setcanceltype(previous, NULL);
	errno = saved_errno;
	return result;
}

ssize_t
pwrite(int fd, const void *data, size_t count, off_t offset)
{
	return write_at(fd, data, count, offset, 0);
}

ssize_t
pwritev(int fd, const struct iovec *iov, int count, off_t offset)
{
	return write_at(fd, iov, (size_t)count, offset, 1);
}
