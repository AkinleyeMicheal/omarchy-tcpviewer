# Capture Fixtures

These `.pcap` and `.pcapng` samples are synthetic test fixtures, not real local
traffic captures. They contain one UDP payload packet and one DNS response packet
using private/example addresses so the parser tests can safely assert stable
packet data in an open source repo.

`tls13-rfc8446.pcap` and `tls12-chacha20poly1305.pcap` come from the Wireshark
repository's own test suite (`test/captures/`, Wireshark license) and are used to
exercise encrypted-record stream following. Upstream loaded them from its
vendored Wireshark checkout; we keep copies here because we build against the
system Wireshark instead.
