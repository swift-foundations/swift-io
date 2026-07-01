// CUring.h — minimal C shim exposing liburing to Swift.
//
// Only the operations this experiment uses: queue setup, prep_read,
// submit, wait_cqe, peek_cqe, cqe_seen, and a minimal ASYNC_CANCEL.

#ifndef CURING_H
#define CURING_H

#ifdef __linux__

#include <liburing.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

// Re-export for Swift consumers.

static inline int curing_queue_init(unsigned entries, struct io_uring *ring) {
    return io_uring_queue_init(entries, ring, 0);
}

static inline void curing_queue_exit(struct io_uring *ring) {
    io_uring_queue_exit(ring);
}

static inline struct io_uring_sqe *curing_get_sqe(struct io_uring *ring) {
    return io_uring_get_sqe(ring);
}

static inline void curing_prep_read(struct io_uring_sqe *sqe, int fd, void *buf, unsigned nbytes, long long offset) {
    io_uring_prep_read(sqe, fd, buf, nbytes, offset);
}

static inline void curing_prep_cancel(struct io_uring_sqe *sqe, void *user_data_to_cancel, unsigned flags) {
    io_uring_prep_cancel(sqe, user_data_to_cancel, flags);
}

static inline void curing_sqe_set_data(struct io_uring_sqe *sqe, void *data) {
    io_uring_sqe_set_data(sqe, data);
}

static inline int curing_submit(struct io_uring *ring) {
    return io_uring_submit(ring);
}

static inline int curing_wait_cqe(struct io_uring *ring, struct io_uring_cqe **cqe) {
    return io_uring_wait_cqe(ring, cqe);
}

static inline int curing_peek_cqe(struct io_uring *ring, struct io_uring_cqe **cqe) {
    return io_uring_peek_cqe(ring, cqe);
}

static inline void curing_cqe_seen(struct io_uring *ring, struct io_uring_cqe *cqe) {
    io_uring_cqe_seen(ring, cqe);
}

static inline int curing_cqe_res(struct io_uring_cqe *cqe) {
    return cqe->res;
}

static inline void *curing_cqe_data(struct io_uring_cqe *cqe) {
    return io_uring_cqe_get_data(cqe);
}

// Pipe helpers (avoid importing Glibc in Swift just for pipe).
static inline int curing_pipe(int fds[2]) {
    return pipe(fds);
}

static inline long curing_write(int fd, const void *buf, unsigned long count) {
    return write(fd, buf, count);
}

static inline int curing_close(int fd) {
    return close(fd);
}

static inline int curing_errno(void) {
    return errno;
}

// Sleep helper (to let the write side land before resuming)
static inline void curing_usleep(unsigned int us) {
    usleep(us);
}

#endif /* __linux__ */

#endif /* CURING_H */
