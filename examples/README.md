# Examples

Two traces. `ns1_iperf.pcap` in the repository root is iperf3 on two NICs, and the file `make demo` replays. `ci.pcap` is produced by `scripts/gen_pcap.py` when you run `make ci` and is not committed.

## iperf3 on two NICs

`ns1_iperf.pcap` is iperf3 between two NICs, classic pcap, Ethernet (DLT 1), 1000 frames, snaplen 2048.

| Endpoint | Address | MAC | NIC |
|---|---|---|---|
| Host A | `192.168.1.1` | `02:00:00:00:00:01` | NIC A |
| Host B | `192.168.1.2` | `ba:dc:18:c5:a2:89` | NIC B |

tcpdump ran on NIC A, so both directions are in one file. iperf3 was TCP from host A to host B. Frames whose on-wire length is larger than 2048 were cut by the snaplen (TSO bursts). The log prints both lengths, for example `2048 B (wire 65226)`. The bridge and the C model use the stored 2048 bytes. That length equals `MAX_B`, so those frames are learned and forwarded or filtered, not dropped.

`make demo` checks the first 64 frames. Full logs:

| Log | Command | Result |
|---|---|---|
| [ns1_iperf_64.log](ns1_iperf_64.log) | `make PCAP=ns1_iperf.pcap MAX_PACKETS=64 BP=2` | both hosts arrive on port A |
| [ns1_iperf_64_split.log](ns1_iperf_64_split.log) | `make PCAP=ns1_iperf.pcap MAX_PACKETS=64 BP=2 SPLIT=1` | host A on port A, host B on port B |

Port A only. Packet 1 is an unknown unicast to `ba:dc:18:c5:a2:89` and floods out port B. Packet 2 learns that MAC on port A. Every later unicast in this window is filtered:

```
[BR] rx_a=64  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=63  drop=0  byte_mis=0  mis=0
```

Split. `02:00:00:00:00:01` enters A (38 frames) and `ba:dc:18:c5:a2:89` enters B (26 frames). Packet 1 still floods, because B’s MAC is not installed yet. The other 63 frames are forwarded, and each egress length matches the ingress frame:

```
[BR] rx_a=38  rx_b=26  tx_a=26  tx_b=38  flood=1  fwd=63  filter=0  drop=0  byte_mis=0  mis=0
```

`tx_b` equals `rx_a` and `tx_a` equals `rx_b`: on this window every accepted frame leaves the other port.

Replay the whole file with `make PCAP=ns1_iperf.pcap MAX_PACKETS=1000`. `BP=2` stalls `tready` and does not change these counts. `FILTER='tcp port 5201'` asks libpcap to drop non-matching frames before they reach the bridge; the log reports `BPF matched` and `skipped`.

A replacement capture has to be Ethernet DLT 1, readable by the user running the sim, and, for `SPLIT=1`, use `02:00:00:00:00:01` as the port-A source. The record commands are in the [Readme](../Readme.md).

## Seven-frame regression

`make ci` writes `ci.pcap` and checks four runs: port A, split, `AXIS_W=64`, and `PAUSE=1`. Hosts are `02:00:00:00:00:01` / `192.168.1.1` and `02:00:00:00:00:02` / `192.168.1.2`. The seven frames are a TCP handshake, two data segments, an ARP request, and an ARP reply.

| Log | Command |
|---|---|
| [ci_port_a.log](ci_port_a.log) | `make PCAP=ci.pcap MAX_PACKETS=8 BP=2` |
| [ci_split.log](ci_split.log) | `make PCAP=ci.pcap MAX_PACKETS=8 BP=2 SPLIT=1` |

Port A learns both MACs on A. Port B sees the first unknown unicast and the ARP broadcast:

```
[BR] rx_a=7  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=5  drop=0  byte_mis=0  mis=0
```

Split forwards the unicast conversation and still floods the broadcast and the first unknown destination:

```
[BR] rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0
```

## Short frame

`python3 scripts/gen_pcap.py --drop drop.pcap` writes three frames, and `make ci` replays them. Frame 1 learns host A and floods. Frame 2 is 8 bytes, under the 12-byte header, so it is a drop and must leave the table alone. Frame 3 is host B to host A and filters, which only holds if the runt did not erase host A. The same summary is required at `AXIS_W=64`. Log: [ci_drop.log](ci_drop.log).

```
[BR] rx_a=3  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=1  byte_mis=0  mis=0
```

## 1024-entry table

`python3 scripts/gen_pcap.py --table table.pcap` writes 18 frames, and `make ci` replays them into port A. Frames 1–17 are broadcasts from `02:00:00:00:00:01` through `02:00:00:00:00:11`, so each source is learned and each frame floods. Frame 18 is from `02:00:00:00:00:12` to `02:00:00:00:00:01`. That destination is still in the table, so the frame is filtered. A 16-entry table would have replaced the first source and flooded frame 18. Log: [ci_table.log](ci_table.log).

```
[BR] rx_a=18  rx_b=0  tx_a=0  tx_b=17  flood=17  fwd=0  filter=1  drop=0  byte_mis=0  mis=0
```
