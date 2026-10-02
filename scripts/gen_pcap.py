#!/usr/bin/env python3
"""Two-host Ethernet pcap for the L2AxisBr gate.

Host A  02:00:00:00:00:01 / 192.168.1.1
Host B  02:00:00:00:00:02 / 192.168.1.2

Seven frames: TCP handshake, two data segments, ARP request, ARP reply.
Stdlib only. Output is local (gitignored *.pcap).

    python3 scripts/gen_pcap.py ci.pcap
    python3 scripts/gen_pcap.py --drop drop.pcap
    python3 scripts/gen_pcap.py --table table.pcap

With every frame replayed into port A the bridge learns both MACs on A:
unknown unicast and the later ARP broadcast leave on port B (tx_b=2);
the other five are filtered.

With SPLIT=1, host A frames enter port A and host B frames enter port B,
so unicast after the first learn is forwarded the other way.
"""
from __future__ import annotations

import argparse
import struct
import sys

H1 = bytes.fromhex("020000000001")
H2 = bytes.fromhex("020000000002")
IP1 = bytes.fromhex("c0a80101")
IP2 = bytes.fromhex("c0a80102")


def ip_csum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def pcap_hdr() -> bytes:
    return struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)


def rec(raw: bytes, ts: int) -> bytes:
    return struct.pack("<IIII", ts, 0, len(raw), len(raw)) + raw


def eth(dst: bytes, src: bytes, etype: int, payload: bytes) -> bytes:
    return dst + src + struct.pack("!H", etype) + payload


def ipv4(src: bytes, dst: bytes, proto: int, payload: bytes) -> bytes:
    total = 20 + len(payload)
    hdr = bytearray(
        struct.pack(
            "!BBHHHBBH4s4s",
            0x45,
            0,
            total,
            0,
            0,
            64,
            proto,
            0,
            src,
            dst,
        )
    )
    struct.pack_into("!H", hdr, 10, ip_csum(bytes(hdr)))
    return bytes(hdr) + payload


def tcp(sport: int, dport: int, seq: int, ack: int, flags: int, payload: bytes = b"") -> bytes:
    return struct.pack("!HHIIBBHHH", sport, dport, seq, ack, (5 << 4), flags, 65535, 0, 0) + payload


def tcp_frame(
    src_m: bytes,
    dst_m: bytes,
    src_ip: bytes,
    dst_ip: bytes,
    sport: int,
    dport: int,
    seq: int,
    ack: int,
    flags: int,
    payload: bytes = b"",
) -> bytes:
    return eth(dst_m, src_m, 0x0800, ipv4(src_ip, dst_ip, 6, tcp(sport, dport, seq, ack, flags, payload)))


def arp(oper: int, src_m: bytes, dst_m: bytes, spa: bytes, tpa: bytes, tha: bytes) -> bytes:
    body = struct.pack("!HHBBH", 1, 0x0800, 6, 4, oper) + src_m + spa + tha + tpa
    return eth(dst_m, src_m, 0x0806, body)


def frames() -> list[bytes]:
    syn = 0x02
    synack = 0x12
    ack = 0x10
    psh = 0x18
    return [
        tcp_frame(H1, H2, IP1, IP2, 34612, 5201, 1, 0, syn),
        tcp_frame(H2, H1, IP2, IP1, 5201, 34612, 1, 2, synack),
        tcp_frame(H1, H2, IP1, IP2, 34612, 5201, 2, 2, ack),
        tcp_frame(H1, H2, IP1, IP2, 34612, 5201, 2, 2, psh, b"iperf-h1"),
        tcp_frame(H2, H1, IP2, IP1, 5201, 34612, 2, 10, psh, b"iperf-h2"),
        arp(1, H1, bytes.fromhex("ffffffffffff"), IP1, IP2, bytes(6)),
        arp(2, H2, H1, IP2, IP1, H1),
    ]


def table_frames() -> list[bytes]:
    """Seventeen broadcasts, then a lookup of the first source.

    Each broadcast learns a distinct unicast source on one port. The last
    frame is destined to the first of those sources. A 16-entry table would
    have replaced that source; a 1024-entry table still filters it.
    """
    bcast = bytes.fromhex("ffffffffffff")
    frames_out = []
    for n in range(1, 18):
        sa = bytes.fromhex(f"0200000000{n:02x}")
        frames_out.append(eth(bcast, sa, 0x0800, b"\x00" * 20))
    sa = bytes.fromhex("020000000012")
    da = bytes.fromhex("020000000001")
    frames_out.append(eth(da, sa, 0x0800, b"\x00" * 20))
    return frames_out


def drop_frames() -> list[bytes]:
    """Flood, then an 8-byte runt, then a frame that must still filter.

    The runt is shorter than 12 bytes, so it is dropped and must not change
    the MAC table. The third frame is H2 -> H1 after H1 was learned on the
    same port.
    """
    syn = 0x02
    synack = 0x12
    runt = bytes.fromhex("0200000000020200")
    return [
        tcp_frame(H1, H2, IP1, IP2, 34612, 5201, 1, 0, syn),
        runt,
        tcp_frame(H2, H1, IP2, IP1, 5201, 34612, 1, 2, synack),
    ]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("out", nargs="?", default="ci.pcap")
    p.add_argument(
        "--drop",
        action="store_true",
        help="write flood, 8-byte drop, filter (3 frames)",
    )
    p.add_argument(
        "--table",
        action="store_true",
        help="write 17 learns and a lookup of the first MAC (18 frames)",
    )
    args = p.parse_args()
    if args.drop and args.table:
        p.error("choose one of --drop or --table")
    if args.table:
        chosen = table_frames()
    elif args.drop:
        chosen = drop_frames()
    else:
        chosen = frames()
    blob = pcap_hdr()
    for i, raw in enumerate(chosen, start=1):
        blob += rec(raw, i)
    with open(args.out, "wb") as f:
        f.write(blob)
    print(f"wrote {args.out} ({len(chosen)} frames)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
