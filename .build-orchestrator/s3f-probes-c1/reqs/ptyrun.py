# Runs a command under a pseudo-terminal (line-buffered output) for at most N seconds, writing output to a log.
import os, pty, subprocess, sys, time, select, signal
limit = float(sys.argv[1]); log = sys.argv[2]; cmd = sys.argv[3:]
master, slave = pty.openpty()
p = subprocess.Popen(cmd, stdout=slave, stderr=slave, stdin=subprocess.DEVNULL, start_new_session=True)
os.close(slave)
start = time.time()
with open(log, "wb") as f:
    while True:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if not data and p.poll() is not None:
                break
            f.write(data); f.flush()
        elif p.poll() is not None:
            break
        if time.time() - start > limit:
            f.write(f"\n[ptyrun] still running after {limit:.0f} s: killing process group\n".encode()); f.flush()
            os.killpg(p.pid, signal.SIGTERM); p.wait(); break
    f.write(f"\n[ptyrun] exit={p.returncode} elapsed={time.time()-start:.1f}s\n".encode())
