"""Dual-stack TCP (HTTP) and UDP server on PORT that replies "<hostname> <caller's source IP>"."""
import http.server
import socket
import sys
import threading

PORT = int(sys.argv[1])


def reply(addr):
    return f"{socket.gethostname()} {addr[0].removeprefix('::ffff:')}".encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = reply(self.client_address)
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def serve_udp():
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", PORT))
    while True:
        _, addr = sock.recvfrom(512)
        sock.sendto(reply(addr), addr)


threading.Thread(target=serve_udp, daemon=True).start()
Server(("::", PORT), Handler).serve_forever()
