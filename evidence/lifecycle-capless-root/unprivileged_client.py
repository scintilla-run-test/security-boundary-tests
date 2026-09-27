#!/usr/bin/env python3
import os
import socket
import sys

path = sys.argv[1]
assert os.getuid() != 0, "unauthorized client must not run as root"

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(2)
client.connect(path)
try:
    client.sendall(b"v1 status\n")
    try:
        response = client.recv(4096)
    except ConnectionResetError:
        response = b""
finally:
    client.close()

assert response == b"", response
print("unauthorized peer received no lifecycle protocol bytes")
