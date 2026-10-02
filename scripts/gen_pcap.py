#!/usr/bin/env python3
"""Two-host Ethernet pcap for the L2AxisBr gate.

Host A  02:00:00:00:00:01 / 192.168.1.1
Host B  02:00:00:00:00:02 / 192.168.1.2

Seven frames: TCP handshake, two data segments, ARP request, ARP reply.
Stdlib only. Output is local (gitignored *.pcap).

    python3 scripts/gen_pcap.py ci.pcap
    python3 scripts/gen_pcap.py --drop drop.pcap
    python3 scripts/gen_pcap.py --table table.pcap
    python3 scripts/gen_pcap.py --age age.pcap
    python3 scripts/gen_pcap.py --move move.pcap
    python3 scripts/gen_pcap.py --both both.pcap
    python3 scripts/gen_pcap.py --queue queue.pcap
    python3 scripts/gen_pcap.py --len64 len64.pcap
    python3 scripts/gen_pcap.py --jumbo jumbo.pcap
    python3 scripts/gen_pcap.py --vlan vlan.pcap
    python3 scripts/gen_pcap.py --mcast mcast.pcap

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


def rec(raw: bytes, ts: int, usec: int = 0) -> bytes:
    return struct.pack("<IIII", ts, usec, len(raw), len(raw)) + raw


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


def sized(dst: bytes, src: bytes, n: int) -> bytes:
    if n < 14:
        raise ValueError(n)
    return eth(dst, src, 0x0800, b"\x00" * (n - 14))


def len64_frames() -> list[bytes]:
    """64-byte learn, 63-byte drop, 1519-byte drop, then a filter.

    LEN=1 accepts 64 through 1518. The drops must not disturb the learned MAC.
    """
    return [
        sized(H2, H1, 64),
        sized(H2, bytes.fromhex("020000000003"), 63),
        sized(H2, H1, 1519),
        sized(H1, H2, 80),
    ]


def jumbo_frames() -> list[bytes]:
    """A 3000-byte learn, a 9001-byte drop, then a filter.

    LEN=2 accepts 64 through 9000. The default 2048 limit would drop the first.
    """
    return [
        sized(H2, H1, 3000),
        sized(H2, bytes.fromhex("020000000003"), 9001),
        sized(H1, H2, 64),
    ]


def vlan(dst: bytes, src: bytes, vid: int, payload: bytes) -> bytes:
    return dst + src + struct.pack("!HHH", 0x8100, vid & 0xFFF, 0x0800) + payload


def mcast_frames() -> tuple[list[bytes], list[int]]:
    """Known group 01:00:5e:00:00:01, an unknown group, then the known group on B.

    Seconds are the port under PORT_TS=1. With MCAST=1 the known group is
    installed on port B: it is forwarded from A and filtered on B.
    """
    g1 = bytes.fromhex("01005e000001")
    g2 = bytes.fromhex("01005e000002")
    pad = b"\x00" * 20
    raw = [
        eth(g1, H1, 0x0800, pad),
        eth(g2, H1, 0x0800, pad),
        eth(g1, H2, 0x0800, pad),
    ]
    return raw, [0, 0, 1]


def vlan_frames() -> list[bytes]:
    """Learn H1 on VID 5, miss that MAC untagged, then filter it on VID 5."""
    pad = b"\x00" * 20
    return [
        vlan(H2, H1, 5, pad),
        eth(H1, H2, 0x0800, pad),
        vlan(H1, H2, 5, pad),
    ]


def queue_frames() -> list[bytes]:
    """Two broadcasts on one port.

    The second frame has to be accepted while the first is still leaving.
    """
    bcast = bytes.fromhex("ffffffffffff")
    pad = b"\x00" * 20
    return [
        eth(bcast, H1, 0x0800, pad),
        eth(bcast, H2, 0x0800, pad),
    ]


def both_frames() -> list[bytes]:
    """One broadcast on A and, in the same cycles, a lookup of that source on B.

    The bench pairs these two frames when BOTH=1. A is learned before B's
    destination is looked up, so B is forwarded rather than flooded.
    """
    bcast = bytes.fromhex("ffffffffffff")
    pad = b"\x00" * 20
    return [
        eth(bcast, H1, 0x0800, pad),
        eth(H1, H2, 0x0800, pad),
    ]


def move_frames() -> tuple[list[bytes], list[int]]:
    """H1 is learned on A, then seen on B, then looked up from A.

    The seconds field is the ingress port when the bench runs with
    PORT_TS=1: 0 is port A, any other value is port B. Frame 3 must be
    forwarded to B. A table that ignored the move would filter it.
    """
    bcast = bytes.fromhex("ffffffffffff")
    pad = b"\x00" * 20
    raw = [
        eth(bcast, H1, 0x0800, pad),
        eth(H2, H1, 0x0800, pad),
        eth(H1, H2, 0x0800, pad),
    ]
    return raw, [0, 1, 0]


def age_frames() -> tuple[list[bytes], list[int]]:
    """Learn H1, confirm it still filters, then idle 2000 clocks and flood.

    The usec field is idle clocks before that frame when the bench is run
    with TS_GAP=1. AGE=1000 expires H1 before the third frame's decision.
    """
    pad = b"\x00" * 20
    raw = [
        eth(H2, H1, 0x0800, pad),
        eth(H1, H2, 0x0800, pad),
        eth(H1, H2, 0x0800, pad),
    ]
    return raw, [0, 0, 2000]


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
    p.add_argument(
        "--age",
        action="store_true",
        help="write learn, still-valid filter, then a flood after 2000 idle clocks",
    )
    p.add_argument(
        "--move",
        action="store_true",
        help="write a source learned on A, seen on B, then looked up from A",
    )
    p.add_argument(
        "--both",
        action="store_true",
        help="write two frames for the bench to drive on A and B in the same cycles",
    )
    p.add_argument(
        "--queue",
        action="store_true",
        help="write two broadcasts that must overlap ingress and egress",
    )
    p.add_argument(
        "--len64",
        action="store_true",
        help="write 64-byte learn, 63-byte drop, 1519-byte drop, filter",
    )
    p.add_argument(
        "--jumbo",
        action="store_true",
        help="write a 3000-byte learn, a 9001-byte drop, and a filter",
    )
    p.add_argument(
        "--vlan",
        action="store_true",
        help="write a VID 5 learn, an untagged miss, and a VID 5 filter",
    )
    p.add_argument(
        "--mcast",
        action="store_true",
        help="write a known multicast group, an unknown group, and the known group on B",
    )
    args = p.parse_args()
    modes = sum(
        1
        for flag in (
            args.drop,
            args.table,
            args.age,
            args.move,
            args.both,
            args.queue,
            args.len64,
            args.jumbo,
            args.vlan,
            args.mcast,
        )
        if flag
    )
    if modes > 1:
        p.error("choose only one frame-set flag")
    usecs = None
    secs = None
    if args.table:
        chosen = table_frames()
    elif args.drop:
        chosen = drop_frames()
    elif args.age:
        chosen, usecs = age_frames()
    elif args.move:
        chosen, secs = move_frames()
    elif args.both:
        chosen = both_frames()
    elif args.queue:
        chosen = queue_frames()
    elif args.len64:
        chosen = len64_frames()
    elif args.jumbo:
        chosen = jumbo_frames()
    elif args.vlan:
        chosen = vlan_frames()
    elif args.mcast:
        chosen, secs = mcast_frames()
    else:
        chosen = frames()
    blob = pcap_hdr()
    for i, raw in enumerate(chosen, start=1):
        blob += rec(
            raw,
            i if secs is None else secs[i - 1],
            0 if usecs is None else usecs[i - 1],
        )
    with open(args.out, "wb") as f:
        f.write(blob)
    print(f"wrote {args.out} ({len(chosen)} frames)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
