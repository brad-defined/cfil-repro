// gorepro sends UDP datagrams to a destination that the cfilrepro content
// filter holds, and reports what happens to the WriteTo call that hits EAGAIN
// and parks in internal/poll.(*pollDesc).waitWrite.
//
// It exits as soon as the outcome is clear (exit codes match kqrepro):
//
//	0 RECOVERED   the write stalled, then completed: the kernel delivered EVFILT_WRITE
//	1 REPRODUCED  the socket polls writable but the write stays parked: lost wakeup
//	3 HUNG        the socket stayed unwritable for -give-up: send space never released
//	4 NOT HELD    no write stalled within -engage: the filter isn't holding this flow
package main

import (
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"runtime/pprof"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func main() {
	held := flag.String("held", "192.0.2.1:4242", "destination the filter pauses (must match the filter's --port)")
	network := flag.String("net", "udp", `"udp" = dual-stack [::] socket (Go's default, like Nebula); "udp4" = IPv4-only socket`)
	size := flag.Int("size", 1400, "datagram size")
	interval := flag.Duration("interval", 10*time.Millisecond, "delay between writes")
	engage := flag.Duration("engage", 10*time.Second, "exit 4 if no write has stalled by then")
	writableFor := flag.Duration("writable-for", 3*time.Second, "exit 1 once a parked write's socket has polled writable this long")
	probeEvery := flag.Duration("probe-every", 0, "while parked and unwritable, do a direct sendto on the same fd this often (0 = never), like kqrepro does")
	giveUp := flag.Duration("give-up", 45*time.Second, "exit 3 once a write has been parked this long without the socket ever polling writable")
	flag.Parse()

	if *network != "udp" && *network != "udp4" {
		fmt.Fprintln(os.Stderr, `-net must be "udp" or "udp4"`)
		os.Exit(2)
	}
	dst := netip.MustParseAddrPort(*held)
	conn, err := net.ListenUDP(*network, &net.UDPAddr{})
	check(err)
	rc, err := conn.SyscallConn()
	check(err)
	dual := *network == "udp"

	// A local listener used to prove the socket can really send while Go is parked.
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	check(err)
	probePort := probe.LocalAddr().(*net.UDPAddr).Port
	go func() {
		buf := make([]byte, 64)
		for {
			n, _, err := probe.ReadFromUDP(buf)
			if err != nil {
				return
			}
			logf("probe listener received %q", buf[:n])
		}
	}()

	logf("%s; -net %s, local %s -> held %s, -probe-every %v", runtime.Version(), *network, conn.LocalAddr(), dst, *probeEvery)

	var inFlight atomic.Int64 // unix nanos when the current write started, 0 if none
	var sent atomic.Int64
	stallDone := make(chan time.Duration, 1)
	go func() {
		buf := make([]byte, *size)
		for {
			start := time.Now()
			inFlight.Store(start.UnixNano())
			_, err := conn.WriteToUDPAddrPort(buf, dst)
			inFlight.Store(0)
			n := sent.Add(1)
			d := time.Since(start)
			if err != nil {
				logf("write #%d err=%v", n, err)
			}
			if d > 500*time.Millisecond {
				logf("write #%d completed after %v", n, d.Round(time.Millisecond))
				select {
				case stallDone <- d:
				default:
				}
			}
			time.Sleep(*interval)
		}
	}()

	// pollState reports whether the fd polls writable, without touching Go's poller.
	// RawConn.Control only takes a reference on the fd, not the write lock, so it
	// runs while the writer goroutine is parked.
	pollState := func() (writable bool, nwrite int) {
		check(rc.Control(func(fd uintptr) {
			fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLOUT}}
			_, _ = unix.Poll(fds, 0)
			writable = fds[0].Revents&unix.POLLOUT != 0
			nwrite, _ = unix.GetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_NWRITE)
		}))
		return
	}
	// probeSend does a direct non-blocking sendto on the same fd to an unfiltered destination.
	probeSend := func() error {
		var sa syscall.Sockaddr = &syscall.SockaddrInet4{Port: probePort, Addr: [4]byte{127, 0, 0, 1}}
		if dual {
			sa = &syscall.SockaddrInet6{Port: probePort, Addr: netip.MustParseAddr("::ffff:127.0.0.1").As16()}
		}
		var err error
		check(rc.Control(func(fd uintptr) { err = syscall.Sendto(int(fd), []byte("probe"), 0, sa) }))
		return err
	}

	start := time.Now()
	stalled := false
	var writableSince time.Time
	lastLog, lastProbe := time.Time{}, time.Time{}
	tick := time.NewTicker(250 * time.Millisecond)
	for {
		select {
		case d := <-stallDone:
			done(0, "RECOVERED: write #%d stalled %v, then completed. The kernel delivered EVFILT_WRITE.",
				sent.Load(), d.Round(time.Millisecond))
		case <-tick.C:
		}

		startNs := inFlight.Load()
		blocked := time.Duration(0)
		if startNs != 0 {
			blocked = time.Since(time.Unix(0, startNs))
		}
		if blocked < time.Second {
			if !stalled && time.Since(start) > *engage {
				done(4, "NOT HELD: %d writes in %v and none stalled. Is the filter enabled with a matching --port?",
					sent.Load(), engage.Round(time.Second))
			}
			continue
		}
		if !stalled {
			stalled = true
			logf("write #%d parked (EAGAIN); watching the socket", sent.Load()+1)
		}

		writable, nwrite := pollState()
		if !writable && *probeEvery > 0 && time.Since(lastProbe) >= *probeEvery {
			lastProbe = time.Now()
			logf("  probe sendto on same fd (unfiltered dst) -> err=%v", probeSend())
		}
		switch {
		case writable && writableSince.IsZero():
			writableSince = time.Now()
			logf("socket polls writable after %v parked; probe sendto on same fd -> err=%v",
				blocked.Round(time.Millisecond), probeSend())
		case !writable && !writableSince.IsZero():
			writableSince = time.Time{}
			logf("socket unwritable again")
		case time.Since(lastLog) >= 5*time.Second:
			lastLog = time.Now()
			logf("write #%d parked %v; poll writable=%v SO_NWRITE=%d", sent.Load()+1, blocked.Round(time.Second), writable, nwrite)
		}

		if !writableSince.IsZero() && time.Since(writableSince) >= *writableFor {
			done(1, "REPRODUCED: WriteToUDPAddrPort parked %v; the socket has polled writable for %v.\n"+
				"The kernel never delivered EVFILT_WRITE after EAGAIN (lost wakeup).",
				blocked.Round(time.Millisecond), time.Since(writableSince).Round(time.Millisecond))
		}
		if writableSince.IsZero() && blocked >= *giveUp {
			done(3, "HUNG: write #%d parked %v and the socket never polled writable.\n"+
				"The kernel never released the send-buffer space; any program would block (not a Go bug).",
				sent.Load()+1, blocked.Round(time.Second))
		}
	}
}

func done(code int, format string, args ...any) {
	fmt.Printf("\n*** "+format+"\n", args...)
	if code == 1 || code == 3 {
		fmt.Println()
		_ = pprof.Lookup("goroutine").WriteTo(os.Stdout, 1)
	}
	os.Exit(code)
}

func logf(format string, args ...any) {
	fmt.Printf("%s "+format+"\n", append([]any{time.Now().Format("15:04:05.000")}, args...)...)
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}
