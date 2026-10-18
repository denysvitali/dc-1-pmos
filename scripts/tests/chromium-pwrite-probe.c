#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <unistd.h>

static pthread_barrier_t barrier;
static int descriptor;

static void *cancelled_writer(void *unused)
{
	(void)unused;
	pthread_barrier_wait(&barrier);
	pwrite(descriptor, "BAD", 3, 0);
	return NULL;
}

int main(int argc, char **argv)
{
	(void)argv;
	FILE *file = tmpfile();
	assert(file);
	descriptor = fileno(file);
	struct sock_filter filter[] = {
		BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_pwritev2, 0, 1),
		BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP),
		BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
	};
	struct sock_fprog policy = {sizeof(filter) / sizeof(filter[0]), filter};
	assert(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0);
	assert(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &policy) == 0);
	assert(prctl(PR_GET_SECCOMP, 0, 0, 0, 0) == SECCOMP_MODE_FILTER);
	if (argc > 1) {
		struct iovec iov = {.iov_base = "x", .iov_len = 1};
		syscall(SYS_pwritev2, descriptor, &iov, 1, 0, 0, 0);
		return 99; /* The negative control must die with SIGSYS. */
	}

	assert(write(descriptor, "abcdef", 6) == 6);
	assert(lseek(descriptor, 2, SEEK_SET) == 2);
	assert(pwrite(descriptor, "XY", 2, 1) == 2);
	struct iovec iov[] = {{"1", 1}, {"23", 2}};
	assert(pwritev(descriptor, iov, 2, 3) == 3);
	assert(lseek(descriptor, 0, SEEK_CUR) == 2);
	char data[7] = {0};
	assert(pread(descriptor, data, 6, 0) == 6);
	assert(strcmp(data, "aXY123") == 0);
	assert(pwrite(descriptor, "z", 1, ((off_t)1 << 32) + 17) == 1);
	assert(pread(descriptor, data, 1, ((off_t)1 << 32) + 17) == 1);
	assert(data[0] == 'z');
	assert(pwritev(descriptor, iov, 2, ((off_t)1 << 32) + 32) == 3);
	assert(pread(descriptor, data, 3, ((off_t)1 << 32) + 32) == 3);
	assert(memcmp(data, "123", 3) == 0);
	assert(pwrite(descriptor, "x", 1, -1) == -1 && errno == EINVAL);
	assert(pwrite(-1, "x", 1, 0) == -1 && errno == EBADF);
	assert(pwritev(descriptor, iov, -1, 0) == -1 && errno == EINVAL);
	int flags = fcntl(descriptor, F_GETFL);
	assert(fcntl(descriptor, F_SETFL, flags | O_APPEND) == 0);
	assert(pwrite(descriptor, "x", 1, 0) == -1 && errno == EOPNOTSUPP);
	assert(pwritev(descriptor, iov, 2, 0) == -1 && errno == EOPNOTSUPP);
	assert(fcntl(descriptor, F_SETFL, flags) == 0);

	int previous;
	assert(pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED, &previous) == 0);
	assert(pwrite(descriptor, "a", 1, 0) == 1);
	assert(pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED, &previous) == 0);
	assert(previous == PTHREAD_CANCEL_DEFERRED);
	assert(pthread_barrier_init(&barrier, NULL, 2) == 0);
	pthread_t worker;
	assert(pthread_create(&worker, NULL, cancelled_writer, NULL) == 0);
	assert(pthread_cancel(worker) == 0);
	pthread_barrier_wait(&barrier);
	void *result;
	assert(pthread_join(worker, &result) == 0 && result == PTHREAD_CANCELED);
	assert(pread(descriptor, data, 3, 0) == 3 && memcmp(data, "aXY", 3) == 0);
	pthread_barrier_destroy(&barrier);
	fclose(file);
	puts("PASS: sandbox retained; positional writes, large offsets, errors and cancellation");
	return 0;
}
