"""Send one UDP datagram from SRC to HOST:PORT and print the reply. Usage: udp_probe.py HOST PORT SRC"""
import socket
import sys

host, port, src = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sock = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3)
sock.bind((src, 0))
sock.sendto(b"ping", (host, port))
print(sock.recvfrom(512)[0].decode())
