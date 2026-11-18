// kqrepro: the same check as gorepro with no Go runtime involved.
//
// It registers EVFILT_WRITE with EV_CLEAR (as Go's netpoller does), sends to a
// destination the content filter holds until sendto() returns EAGAIN, then
// waits for a write edge. Once a second it also polls the socket. If poll()
// says writable but kqueue never delivers EVFILT_WRITE, the wakeup was lost.
//
// Socket modes (-m), because they behave differently after a drop verdict:
//   v4    AF_INET socket (the default)
//   dual  AF_INET6 socket with IPV6_V6ONLY=0 bound to [::], like Go's net.ListenUDP("udp", ...)
//         and Nebula. An IPv4 host is sent to as ::ffff:a.b.c.d; an IPv6 host is used as-is.
//
//   cc -O2 -Wall -o kqrepro kqrepro.c
// -P disables the periodic probe sendto to 127.0.0.1:9 while the socket is stuck. Those
// probes fail with EAGAIN, but they appear to be what gets the dropped flow's space released.
//
//   ./kqrepro [-m v4|dual] [-P] [host [port [give-up-seconds]]]     # defaults: v4 192.0.2.1 4242 45
//
// Exit codes (same as gorepro):
//   0 RECOVERED   EVFILT_WRITE fired after the stall
//   1 REPRODUCED  socket polls writable but EVFILT_WRITE never fired (lost wakeup)
//   2 error       bad arguments, or sendto failed with something other than EAGAIN
//   3 HUNG        socket stayed unwritable for give-up-seconds (send space never released)
//   4 NOT HELD    no EAGAIN within 10s: the filter isn't holding this flow

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

#define LOG(...) do { printf("[%7.3f] ", now() - t0); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

// Fill *ss with host:port for a socket of family `af`. IPv4 hosts become v4-mapped on AF_INET6.
static socklen_t mkaddr(int af, const char *host, int port, struct sockaddr_storage *ss) {
    memset(ss, 0, sizeof *ss);
    struct in_addr a4;
    if (af == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)ss;
        if (inet_pton(AF_INET, host, &a4) != 1) return 0;
        *sin = (struct sockaddr_in){.sin_len = sizeof *sin, .sin_family = AF_INET, .sin_port = htons(port), .sin_addr = a4};
        return sizeof *sin;
    }
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ss;
    *sin6 = (struct sockaddr_in6){.sin6_len = sizeof *sin6, .sin6_family = AF_INET6, .sin6_port = htons(port)};
    if (inet_pton(AF_INET, host, &a4) == 1) {
        sin6->sin6_addr.s6_addr[10] = sin6->sin6_addr.s6_addr[11] = 0xff;
        memcpy(&sin6->sin6_addr.s6_addr[12], &a4, 4);
    } else if (inet_pton(AF_INET6, host, &sin6->sin6_addr) != 1) {
        return 0;
    }
    return sizeof *sin6;
}

int main(int argc, char **argv) {
    const char *mode = "v4";
    int probes = 1, opt;
    while ((opt = getopt(argc, argv, "m:P")) != -1) {
        if (opt == 'm' && (!strcmp(optarg, "v4") || !strcmp(optarg, "dual"))) mode = optarg;
        else if (opt == 'P') probes = 0;
        else { fprintf(stderr, "usage: %s [-m v4|dual] [-P] [host [port [give-up]]]\n", argv[0]); return 2; }
    }
    argc -= optind; argv += optind;
    const char *host = argc > 0 ? argv[0] : "192.0.2.1";
    int port = argc > 1 ? atoi(argv[1]) : 4242;
    int timeout = argc > 2 ? atoi(argv[2]) : 45;
    double t0 = now();

    int af = strcmp(mode, "dual") ? AF_INET : AF_INET6;
    int fd = socket(af, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 2; }
    if (af == AF_INET6) {
        int off = 0;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off) < 0) { perror("IPV6_V6ONLY"); return 2; }
    }
    struct sockaddr_storage local, dst, lo;
    socklen_t locallen = mkaddr(af, af == AF_INET ? "0.0.0.0" : "::", 0, &local);
    if (bind(fd, (struct sockaddr *)&local, locallen) < 0) { perror("bind"); return 2; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

    socklen_t dstlen = mkaddr(af, host, port, &dst);
    if (!dstlen) { fprintf(stderr, "bad host %s for mode %s\n", host, mode); return 2; }
    socklen_t lolen = mkaddr(af, "127.0.0.1", 9, &lo);
    LOG("mode=%s (%s socket) -> %s:%d, probes %s", mode, af == AF_INET ? "AF_INET" : "AF_INET6 dual-stack", host, port, probes ? "on" : "off");

    int kq = kqueue();
    struct kevent ch, ev;
    EV_SET(&ch, fd, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, 0, NULL);
    struct timespec zero = {0, 0}, one = {1, 0};
    int n = kevent(kq, &ch, 1, &ev, 1, &zero);
    LOG("registered EVFILT_WRITE|EV_CLEAR; initial edge=%d space=%ld", n, n > 0 ? (long)ev.data : 0L);

    char buf[1400] = {0};
    int sent = 0;
    for (;;) {
        // Write until the socket pushes back.
        while (sendto(fd, buf, sizeof buf, 0, (struct sockaddr *)&dst, dstlen) >= 0) {
            if (++sent % 100 == 0 && now() - t0 > 10) {
                printf("\n*** NOT HELD: %d sends in 10s, never EAGAIN. Is the filter enabled with a matching --port?\n", sent);
                return 4;
            }
            usleep(1000);
        }
        if (errno != EAGAIN) { LOG("sendto #%d failed: %s (need a destination the host can route to)", sent + 1, strerror(errno)); return 2; }
        LOG("sendto #%d -> EAGAIN; waiting for EVFILT_WRITE", sent + 1);

        double waitStart = now(), writableSince = 0;
        for (;;) {
            n = kevent(kq, NULL, 0, &ev, 1, &one);
            if (n > 0) {
                LOG("EVFILT_WRITE edge after %.3fs, space=%ld", now() - waitStart, (long)ev.data);
                printf("\n*** RECOVERED: EVFILT_WRITE fired %.1fs after EAGAIN.\n", now() - waitStart);
                return 0;
            }

            struct pollfd p = {.fd = fd, .events = POLLOUT};
            poll(&p, 1, 0);
            int nwrite = 0; socklen_t l = sizeof nwrite;
            getsockopt(fd, SOL_SOCKET, SO_NWRITE, &nwrite, &l);
            int writable = (p.revents & POLLOUT) != 0;
            LOG("no edge after %.1fs; poll writable=%d SO_NWRITE=%d", now() - waitStart, writable, nwrite);
            if (writable && writableSince == 0) writableSince = now();
            if (probes && !writable && (int)(now() - waitStart) % 5 == 0) {
                // Is the whole socket stuck, or only the held flow? Try an unfiltered destination.
                int r = sendto(fd, "probe", 5, 0, (struct sockaddr *)&lo, lolen);
                LOG("  probe sendto 127.0.0.1:9 (not filtered) -> %s", r >= 0 ? "ok" : strerror(errno));
            }
            if (writable && now() - writableSince >= 3) {
                int r = sendto(fd, "probe", 5, 0, (struct sockaddr *)&lo, lolen);
                LOG("direct sendto 127.0.0.1:9 now -> %s", r >= 0 ? "ok" : strerror(errno));
                printf("\n*** REPRODUCED: socket writable for %.1fs after EAGAIN, but EVFILT_WRITE (EV_CLEAR) never fired.\n", now() - writableSince);
                return 1;
            }
            if (!writableSince && now() - waitStart >= timeout) {
                printf("\n*** HUNG: socket unwritable for %ds after EAGAIN; send space never released.\n", timeout);
                return 3;
            }
        }
    }
}
