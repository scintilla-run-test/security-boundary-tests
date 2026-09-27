#!/usr/bin/env python3
import os
import socket
import sys


def proc_caps():
    values = {}
    with open("/proc/self/status", "r", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith(("CapEff:", "CapBnd:")):
                key, value = line.split(":", 1)
                values[key] = int(value.strip(), 16)
    return values


path = sys.argv[1]
proof_gid = int(sys.argv[2])

assert os.getuid() == 0, os.getuid()
assert os.getgid() == 0, os.getgid()
assert proof_gid in os.getgroups(), os.getgroups()
caps = proc_caps()
assert caps.get("CapEff") == 0, caps
assert caps.get("CapBnd") == 0, caps

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(2)
client.connect(path)
client.sendall(b"v1 status\n")
response = client.recv(4096)
client.close()
assert response.startswith(b"ok status accepting "), response
print(response.decode("utf-8").strip())
