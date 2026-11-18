# cfil-repro: UDP sockets hang after a macOS content filter drops held data (golang/go#73919)

A minimal "Little Snitch" for reproducing the case where `net.(*UDPConn).WriteTo*` parks forever
on macOS. It consists of a tiny content-filter network extension plus two small test programs:
one in Go, and one in plain C using raw kqueue, so no Go runtime is involved.

## Findings

Observed on macOS 27.2.1 (26B131, `xnu-13432.41.4`) in an Apple Silicon VM:

1. While a content filter has a UDP flow paused, the datagrams it holds count against the
   socket's send space. The default UDP send buffer is 9216 bytes, so the 5th 1400-byte
   `sendto()` returns EAGAIN.
2. If the filter **allows** the flow, the space is released and `EVFILT_WRITE` fires.
3. If the filter **drops** the flow, the space is **not** released. The whole socket stays
   unwritable, including for destinations the filter never touched.
4. The space comes back about 20s later, but only if the program keeps attempting sends on the
   socket (they fail with EAGAIN until then). Even then, **`EVFILT_WRITE` never fires**: a
   kqueue waiter is never told the socket is writable again.
5. A parked Go write never touches the socket again. The blocked goroutine waits for
   `EVFILT_WRITE`, and other writers wait on the fd's write lock. So in Go the space is never
   released, and the write blocks indefinitely (still stuck after 10 minutes).

IPv4-only and dual-stack sockets behave the same. Little Snitch triggers this naturally: it
pauses a new flow while its "allow connection?" prompt is up, and the user clicks Deny. The
macOS application firewall also uses content filters.

This matches neild's reading of the XNU source in the issue (xnu-12377.1.9). `cfil_action_drop()`
→ `cfil_flush_queues()` frees the held data without updating the counters `sbspace()` subtracts,
and without `sowwakeup()`; the later flow cleanup (`cfil_info_free()`, `socket_flows.c`) doesn't
call `sowwakeup()` either.

### Result matrix

| Filter verdict | Program keeps sending while stuck | Result |
|---|---|---|
| allow | n/a | RECOVERED: `EVFILT_WRITE` after ~2s |
| drop | yes (`kqrepro` default, `gorepro -probe-every 5s`) | REPRODUCED: writable after ~20s, no `EVFILT_WRITE` |
| drop | no (`kqrepro -P`, `gorepro` default, real Go programs) | HUNG: never writable |

## Pieces

| Path | What it does |
|---|---|
| `filter/` | `CFILRepro.app`: a command-line host app with an embedded content-filter system extension. The extension pauses outbound UDP to `--port`, then after `--hold-ms` resolves it with `--verdict drop\|allow\|never`. All other traffic is allowed. |
| `client/kqrepro` | About 150 lines of C. Registers `EVFILT_WRITE\|EV_CLEAR` (as Go does), sends until EAGAIN, then waits for the event while checking the socket with `poll()`. `-m v4` (default) or `-m dual` socket. `-P` turns off its probe sends. This is the version to give Apple. |
| `client/gorepro` | The same check through `net.UDPConn.WriteToUDPAddrPort`. It watches the parked write's socket through `RawConn.Control`, which doesn't take the write lock. `-net udp` (dual-stack, default) or `-net udp4`. `-probe-every 5s` turns on probe sends. |
| `run-all.sh` | Runs every case and saves the output to `results/<timestamp>/`. Takes under a minute. |

## Requirements

- An **Apple Silicon Mac**. The test programs build for the host architecture, and the VM
  route needs Apple Silicon.
- **Xcode** on the build machine, for the filter app; the command-line tools alone aren't enough.
  The Makefile finds `/Applications/Xcode.app` even if `xcode-select` points somewhere else.
- **Go 1.21 or newer.** It downloads the 1.26+ toolchain `golang.org/x/sys` needs automatically.
- One of:
  - **A throwaway macOS VM** where SIP and AMFI can be disabled. No Apple Developer account is
    needed. **This is the tested route.**
  - **A paid Apple Developer account** to sign the filter properly and run it on a normal Mac.
    This route is untested.

## Option A: unsigned, in a VM (tested)

Disabling AMFI turns off code-signing enforcement for the whole OS. Only do this in a
disposable VM, never on your real Mac.

**1. On the host, build everything:**

```sh
(cd filter && make adhoc)                     # -> filter/build-adhoc/Release/CFILRepro.app
(cd client/gorepro && go build -o gorepro .)
(cd client/kqrepro && cc -O2 -Wall -o kqrepro kqrepro.c)
```

**2. Create a macOS VM.** These steps were tested with
[VirtualBuddy](https://github.com/insidegui/VirtualBuddy) (`brew install --cask virtualbuddy`):
- Create a new macOS VM and finish macOS setup inside it.
- In the VM's settings, add this checkout as a **shared folder**, and make sure it isn't
  read-only. `run-all.sh` writes its results there.

[Tart](https://github.com/openai/tart) should also work but is untested. Its commands are
`tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest cfil`, then
`tart run cfil --recovery`, then `tart run cfil --dir=cfil-repro:$PWD`.

**3. Disable SIP.** Boot the VM into recovery mode (in VirtualBuddy, it's a boot option). Open
Utilities → Terminal, run `csrutil disable`, and shut down.

**4. Disable AMFI.** Boot normally, then in the VM's Terminal:

```sh
sudo nvram boot-args="amfi_get_out_of_my_way=1"
sudo reboot
```

**5. Install and activate the filter**, in the VM after the reboot:

```sh
csrutil status; nvram boot-args       # expect "disabled" and amfi_get_out_of_my_way=1
systemextensionsctl developer on
S="/Volumes/My Shared Files/cfil-repro"   # adjust to your shared folder's name
cp -R "$S/filter/build-adhoc/Release/CFILRepro.app" /Applications/
/Applications/CFILRepro.app/Contents/MacOS/CFILRepro activate
```

Approve the extension in System Settings → General → Login Items & Extensions → Network
Extensions; `activate` prints `done` when it's approved.

**6. Run:**

```sh
"$S/run-all.sh"
```

Click **Allow** if asked whether CFILRepro may filter network content. See
[Reading the results](#reading-the-results).

## Option B: signed, on a normal Mac (untested)

Free "Personal Team" accounts can't use Network Extensions. With a paid team signed into Xcode
(Xcode → Settings → Accounts shows the 10-character team ID):

```sh
cd filter
make TEAM=ABCDE12345   # first build: saves your team to Local.xcconfig
make install           # copies CFILRepro.app to /Applications
```

Automatic signing (`-allowProvisioningUpdates`) registers this Mac with your team. The first
time, it creates an Apple Development certificate, the App IDs `dev.<TEAM>.cfilrepro` and
`dev.<TEAM>.cfilrepro.filter`, and their profiles. Then build the clients as in Option A step 1,
activate as in step 5 (skip the `csrutil`/`nvram`/`developer` lines), and run `./run-all.sh`.

## Reading the results

Each file in `results/<timestamp>/` is one program run and ends with its exit code:

| Exit | Result | Meaning |
|---|---|---|
| 0 | RECOVERED | The write stalled, then `EVFILT_WRITE` fired. |
| 1 | REPRODUCED | The socket polls writable, but `EVFILT_WRITE` never fired (lost wakeup). |
| 2 | error | Bad arguments, or `sendto` failed with something other than EAGAIN. |
| 3 | HUNG | The socket stayed unwritable for the give-up time (45s; `GIVE_UP=600 ./run-all.sh` for longer). |
| 4 | NOT HELD | Nothing stalled within 10s: the filter isn't holding the flow. |

Every `allow-*` run should report RECOVERED. If they report NOT HELD, the filter isn't active:
check `systemextensionsctl list` and `CFILRepro status`. `filter-log.txt` shows each `PAUSE` and
`RESUME` the filter performed; `env.txt` records the macOS version. Results may differ on other
macOS versions, so please include `env.txt` when you report them.

## Running pieces by hand

```sh
R=/Applications/CFILRepro.app/Contents/MacOS/CFILRepro
$R enable --port 4242 --hold-ms 2000 --verdict drop   # or allow / never
log stream --predicate 'subsystem == "net.example.cfilrepro"' &

./client/kqrepro/kqrepro -m v4 192.0.2.1 4242         # or -m dual, -P
./client/gorepro/gorepro -net udp -held 192.0.2.1:4242  # or -net udp4, -probe-every 5s
```

Use a non-loopback destination; `192.0.2.1` is TEST-NET-1, and nothing is sent anyway while it's
held or dropped. `$R disable` turns the filter off; `$R deactivate` removes the extension.

To try JoTurk's proposed Go fix (CL 848585), build `gorepro` with
`go run golang.org/dl/gotip@latest download 848585` and `gotip build`. Its timed retry after
EAGAIN should act like the probe sends and let the write complete after about 20s; this is untested.
