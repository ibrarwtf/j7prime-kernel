#!/usr/bin/env python3
"""QEMU virt smoke test: did the kernel reach /init?

usage: qemu-smoke.py <Image> <initrd.cpio> <timeout-s> <console 0|1>

The phone config has no PL011/virtio console, so the serial line may stay empty.
Evidence is taken from guest RAM instead: QEMU runs with -action shutdown=pause and
-action reboot=shutdown; on the guest's power-off/reset (or on timeout) the RAM is
saved over QMP and searched for the marker that only a running /init can create
(the init binary stores it reversed and builds it at run time, then writes it to
/dev/kmsg). Kernel log lines found in the RAM image are printed for diagnosis.
"""
import json, os, re, select, socket, subprocess, sys, time

image, initrd, timeout, console = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"
MARKER = b"J7CI-INIT-REACHED"
MEM_MB = 512
sock_path = "/tmp/qmp.sock"
append = ("console=ttyAMA0 earlycon " if console else "") + "panic=0 rdinit=/init"
cmd = ["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a53", "-smp", "2", "-m", str(MEM_MB),
       "-kernel", image, "-initrd", initrd, "-append", append,
       "-display", "none", "-monitor", "none", "-serial", "file:serial.log",
       "-qmp", f"unix:{sock_path},server=on,wait=off",
       "-action", "shutdown=pause", "-action", "reboot=shutdown", "-action", "panic=pause"]
print(" ".join(cmd), flush=True)
t0 = time.time()
q = subprocess.Popen(cmd)

s = None
for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(sock_path); break
    except OSError:
        time.sleep(0.1)
buf = b""

def readline(wait=None):
    """one QMP line, or b"" if nothing arrives within `wait` seconds (None = block)"""
    global buf
    while b"\n" not in buf:
        r, _, _ = select.select([s], [], [], wait)
        if not r:
            return b""
        d = s.recv(65536)
        if not d:
            return b""
        buf += d
    line, buf = buf.split(b"\n", 1)
    return line

def send(execute, **args):
    s.sendall(json.dumps({"execute": execute, "arguments": args}).encode() + b"\n")
    while True:
        line = readline(60)
        if not line:
            return None
        m = json.loads(line)
        if "event" in m:
            events.append(m); continue
        return m

events = []
json.loads(readline())  # greeting
send("qmp_capabilities")
reason = None
while time.time() - t0 < timeout and reason is None:
    line = readline(1.0)
    if line:
        m = json.loads(line)
        events.append(m)
        if m.get("event") in ("SHUTDOWN", "GUEST_PANICKED"):
            reason = m.get("data", {}).get("reason", m["event"])
    if q.poll() is not None:
        reason = reason or f"qemu exited rc={q.returncode}"
        break
dt = time.time() - t0
if q.poll() is None:
    send("stop")
    send("pmemsave", val=0x40000000, size=MEM_MB << 20, filename=os.path.abspath("mem.bin"))
    send("quit")
q.wait(timeout=30)

found = False
if os.path.exists("mem.bin"):
    mem = open("mem.bin", "rb").read()
    found = MARKER in mem
    # printable kernel-log-ish strings for diagnosis
    pat = re.compile(rb"(Linux version [ -~]{10,200}|Kernel panic[ -~]{0,200}|Run [ -~]{1,40} as init process|"
                     rb"Unable to [ -~]{5,150}|Internal error[ -~]{0,150}|Kernel command line:[ -~]{0,200}|"
                     rb"Freeing unused kernel memory[ -~]{0,80}|No working init found[ -~]{0,80}|"
                     rb"Unpacking initramfs[ -~]{0,80}|Initramfs unpacking failed[ -~]{0,80}|J7CI-INIT-REACHED)")
    seen = []
    for m in pat.finditer(mem):
        t = m.group(0).decode("ascii", "replace")
        if t not in seen:
            seen.append(t)
    print("--- strings from guest RAM (kernel log fragments):")
    for t in seen[:40]:
        print("  " + t)
serial = open("serial.log", "rb").read() if os.path.exists("serial.log") else b""
if serial:
    print("--- serial (tail):\n" + serial[-3000:].decode("utf-8", "replace"))
ok = found and (not console or MARKER in serial)
how = "marker found in guest RAM" + (" and on ttyAMA0" if console and MARKER in serial else "")
res = (f"PASS: /init ran ({how}); stop reason: {reason or 'timeout'} after {dt:.0f}s" if ok else
       f"FAIL: marker not found; stop reason: {reason or 'timeout'} after {dt:.0f}s "
       f"(see the RAM strings in the log)")
if not console:
    res += " [no PL011 console in this config; serial empty by design]"
print(res)
with open(os.environ.get("GITHUB_STEP_SUMMARY", "/dev/null"), "a") as out:
    out.write(f"### QEMU smoke: {res}\n")
sys.exit(0 if ok else 1)
