# TNFSD: a TNFS server that runs on CP/M

`TNFSD` turns a CP/M machine with a FujiNet into a TNFS server. Another machine
with a FujiNet can then list, get and put files on it with `FUJIDIR`, `FUJIGET`
and `FUJIPUT`. That gives you CP/M-to-CP/M file transfer over a LAN.

```
TNFSD                           serve the current drive, current user area
```

Current version: `TNFSD` v0.3.

## Read the limits first

- **No security.** TNFSD has no password. Any machine that can reach the server's
  FujiNet can read every file on the served drive. It can also write new files
  and replace existing files. Use TNFSD only on a network you trust. Stop it
  (Ctrl-C) when you do not need it.
- **The machine does nothing else.** CP/M runs one program at a time. While
  TNFSD runs, the server machine only serves files.
- **One drive, one user area, no folders.** The TNFS root `/` is the drive and
  user area that TNFSD starts from. Clients cannot see other drives or other user
  areas. TNFSD uses BDOS file calls only. BDOS has no safe way to find the other
  drives, and BIOS calls differ between the many home-made BIOSes.
- **TCP only.** A TNFS client that uses only UDP cannot connect. FujiNet's own
  TNFS client tries TCP first, so `FUJIGET`, `FUJIPUT` and `FUJIDIR` work.
- **One client at a time.** TNFSD serves one TCP connection at a time. It was not
  tested with two clients at once.
- **Uploads replace existing files.** CP/M 2.2 has no call to shorten a file. So
  an upload to an existing name deletes the old file and makes a new one.
  `FUJIPUT` asks `Replace? (Y/N)` first. Other clients may not ask.
- **No delete, rename or new folders.** TNFSD answers these requests with "not
  implemented".
- **CP/M file sizes.** Every size is a multiple of 128 bytes (one CP/M record).
  Text files usually end with `^Z` padding. CP/M 2.2 keeps no file dates, so
  every date is 0.
- **CP/M file names.** Names are 8.3 and match without regard to case. TNFSD
  refuses an upload with a name that CP/M cannot use.
- **Directory listings.** TNFSD lists at most 255 files. A listing shows at most
  512 KB for a larger file. A file transfer uses the real size.
- **Changed disks.** TNFSD reads the directory when it starts. If you change the
  disk while it runs, stop TNFSD and start it again.
- **Serial port.** TNFSD talks to the FujiNet through the 88-2SIO, unit b, at
  ports `12H`/`13H`, like the other tools here. To change this, see section 5 of
  the [main README](../README.md).

## Use it

### On the server machine

1. Go to the drive and user area that you want to serve.
2. Type `TNFSD`.
3. Press Ctrl-C to stop. TNFSD closes any open files first.

TNFSD shows what it does on the console:

```
TNFSD v0.3: serving drive A: (user 0) on TCP port 16384.
40 files cached. Ctrl-C quits.
Client connected.
  Directory listed: 40 files.
Client disconnected.
Client connected.
  Sending TCPECHO.COM . 1408 bytes.
Client disconnected.
Client connected.
  NEWUP3.COM: not found.
Client disconnected.
Client connected.
  Receiving NEWUP3.COM . 1408 bytes.
Client disconnected.
```

- A transfer line shows a dot for each KB, then the byte count.
- `FUJIPUT` first checks if the file exists. That shows as `NAME: not found.`
  just before the upload.
- After a failed `FUJIGET`, the client lists the folder to find the cause. That
  shows as an extra `Directory listed` line.

### On the client machine

Use the IP address of the server machine's FujiNet adapter:

```
FUJIDIR N1:TNFS://192.168.1.30/
FUJIGET N1:TNFS://192.168.1.30/NAME.EXT NAME.EXT
FUJIPUT NAME.EXT N1:TNFS://192.168.1.30/NAME.EXT
```

## Build it

Assemble it inside the machine, like the other tools:

```
ASM TNFSD                       -> TNFSD.HEX
LOAD TNFSD                      -> TNFSD.COM
```

`TNFSD.COM` is 4480 bytes.

## How it works

- TNFSD opens FujiNet's `N:` device as a TCP server: `N1:TCP://:16384/`. When a
  client connects, TNFSD accepts it with the `NET_CONTROL` command (`41H`).
- TCP does not keep packet boundaries. TNFSD finds the end of each TNFS request
  from the request's own structure.
- TNFSD answers the ten TNFS commands that a real FujiNet client sends for
  `FUJIGET`, `FUJIDIR` and `FUJIPUT`: MOUNT, UNMOUNT, STAT, OPEN, READ, WRITE,
  CLOSE, OPENDIRX, READDIRX and CLOSEDIR.
- File access uses BDOS random-record reads and writes.
- TNFSD scans the directory once when it starts. It scans again only after a
  client closes a file that it wrote. While TNFSD runs, nothing else can change
  the drive. So a directory listing needs no disk access.
- TNFSD answers a retried request with the same reply again. FujiNet's TNFS
  client retries after 2 seconds with no answer.

Why not UDP, the usual TNFS transport? On the RS232 `N:` device, UDP does not keep
datagram boundaries. Live tests in September 2026 showed this on a real adapter.
TCP works, and FujiNet's TNFS client tries it first.

## What was tested

- **Server:** a real Altair 8800c with a FujiNet RS232 adapter, serving drive A.
  The adapter ran a firmware build from `fujinet-firmware` source, September 2026.
- **Client:** `altairsim` with FujiNet-PC, running `FUJIDIR`, `FUJIGET` and
  `FUJIPUT`.

| Test | Result |
|---|---|
| `FUJIDIR` of the root | all 40 files, with sizes |
| `FUJIGET` of a 76160-byte file (several directory extents) | same data as a direct TNFS read |
| `FUJIPUT` of a 56494-byte file, then a read back | byte-identical, then `^Z` padding |
| `FUJIGET` of a missing file | `not found` on the client |
| Directory listing of 37 files | 42 ms |
| Read speed | about 145 ms for each 512 bytes |

A scripted TNFS client on a Mac also tested each command on its own, and the
error replies.
