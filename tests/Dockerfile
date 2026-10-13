ARG DEBIAN=12

# Stand-in for a fresh Debian VM: systemd as PID 1 and sshd. The test run
# authorizes a real key generated in the outside container.
FROM debian:${DEBIAN} AS server
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv openssh-server \
 && rm -rf /var/lib/apt/lists/* /usr/sbin/policy-rc.d \
 && install -d -m 700 /root/.ssh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

FROM debian:${DEBIAN} AS client
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      wireguard-tools iproute2 nftables procps python3 curl openssh-client \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
