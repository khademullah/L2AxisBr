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

The whole file, both ways. `BP=2` stalls `tready` and does not change the counts. Logs: [ci_iperf_1000.log](ci_iperf_1000.log), [ci_iperf_1000_split.log](ci_iperf_1000_split.log).

```bash
make PCAP=ns1_iperf.pcap MAX_PACKETS=1000 BP=2
make PCAP=ns1_iperf.pcap MAX_PACKETS=1000 BP=2 SPLIT=1
```

```
[BR] rx_a=1000  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=999  drop=0  byte_mis=0  mis=0
[BR] rx_a=731  rx_b=269  tx_a=269  tx_b=731  flood=1  fwd=999  filter=0  drop=0  byte_mis=0  mis=0
```

`FILTER='tcp port 5201'` asks libpcap to drop non-matching frames before they reach the bridge; the log reports `BPF matched` and `skipped`.

```bash
make PCAP=ns1_iperf.pcap MAX_PACKETS=64 FILTER='tcp port 5201'
make AXIS_W=64 PCAP=ns1_iperf.pcap MAX_PACKETS=64 SPLIT=1
make PAUSE=1 PCAP=ns1_iperf.pcap MAX_PACKETS=64
```

A replacement capture has to be Ethernet DLT 1, readable by the user running the sim, and, for `SPLIT=1`, use `02:00:00:00:00:01` as the port-A source. The record commands are in the [Readme](../Readme.md).

## Seven-frame regression

Hosts are `02:00:00:00:00:01` / `192.168.1.1` and `02:00:00:00:00:02` / `192.168.1.2`. The seven frames are a TCP handshake, two data segments, an ARP request, and an ARP reply. Logs: [ci_port_a.log](ci_port_a.log), [ci_split.log](ci_split.log).

```bash
python3 scripts/gen_pcap.py ci.pcap
make PCAP=ci.pcap MAX_PACKETS=8 BP=2
make PCAP=ci.pcap MAX_PACKETS=8 BP=2 SPLIT=1
make PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=64
make PCAP=ci.pcap MAX_PACKETS=8 PAUSE=1
make PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=32
make PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=128
make PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=256
```

`AXIS_W` 32, 64, 128, and 256 print the same split line as 8-bit. `PAUSE=1` prints the port A line.

Port A learns both MACs on A. Port B sees the first unknown unicast and the ARP broadcast:

```
[BR] rx_a=7  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=5  drop=0  byte_mis=0  mis=0
```

Split forwards the unicast conversation and still floods the broadcast and the first unknown destination:

```
[BR] rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0
```

## Short frame

`python3 scripts/gen_pcap.py --drop drop.pcap` writes three frames. Frame 1 learns host A and floods. Frame 2 is 8 bytes, under the 12-byte header, so it is a drop and must leave the table alone. Frame 3 is host B to host A and filters, which only holds if the runt did not erase host A. The same summary is required at `AXIS_W=64`. Log: [ci_drop.log](ci_drop.log).

```bash
python3 scripts/gen_pcap.py --drop drop.pcap
make PCAP=drop.pcap MAX_PACKETS=8 BP=2
make PCAP=drop.pcap MAX_PACKETS=8 BP=2 AXIS_W=64
```

```
[BR] rx_a=3  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=1  byte_mis=0  mis=0
```

## 1024-entry table

`python3 scripts/gen_pcap.py --table table.pcap` writes 18 frames. Frames 1–17 are broadcasts from `02:00:00:00:00:01` through `02:00:00:00:00:11`, so each source is learned and each frame floods. Frame 18 is from `02:00:00:00:00:12` to `02:00:00:00:00:01`. That destination is still in the table, so the frame is filtered. A 16-entry table would have replaced the first source and flooded frame 18. Log: [ci_table.log](ci_table.log).

```bash
python3 scripts/gen_pcap.py --table table.pcap
make PCAP=table.pcap MAX_PACKETS=32 BP=2
```

```
[BR] rx_a=18  rx_b=0  tx_a=0  tx_b=17  flood=17  fwd=0  filter=1  drop=0  byte_mis=0  mis=0
```

## Aging

`python3 scripts/gen_pcap.py --age age.pcap` writes three frames. Frame 1 learns `02:00:00:00:00:01` and floods. Frame 2 is still inside the age and filters. Frame 3 waits 2000 clocks, the entry expires, and the same destination floods. Log: [ci_age.log](ci_age.log).

```bash
python3 scripts/gen_pcap.py --age age.pcap
make PCAP=age.pcap MAX_PACKETS=8 AGE=1000 TS_GAP=1
```

```
[BR] rx_a=3  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=1  drop=0  byte_mis=0  mis=0
```

## Station move

`python3 scripts/gen_pcap.py --move move.pcap` writes three frames. `PORT_TS=1` takes the ingress port from the pcap seconds field (`0` is A). Frame 1 learns `02:00:00:00:00:01` on A and floods. Frame 2 is that same source on B, so the entry moves, and the unknown destination floods out A. Frame 3 looks that MAC up from A and is forwarded to B. Log: [ci_move.log](ci_move.log).

```bash
python3 scripts/gen_pcap.py --move move.pcap
make PCAP=move.pcap MAX_PACKETS=8 PORT_TS=1
```

```
[BR] rx_a=2  rx_b=1  tx_a=1  tx_b=2  flood=2  fwd=1  filter=0  drop=0  byte_mis=0  mis=0
```

## Both ports in one cycle

`python3 scripts/gen_pcap.py --both both.pcap` writes two frames of the same length. `BOTH=1` drives them on A and B in the same cycles. A learns `02:00:00:00:00:01` before B looks it up, so B is forwarded. Log: [ci_both.log](ci_both.log).

```bash
python3 scripts/gen_pcap.py --both both.pcap
make PCAP=both.pcap MAX_PACKETS=8 BOTH=1
```

```
[BR] rx_a=1  rx_b=1  tx_a=1  tx_b=1  flood=1  fwd=1  filter=0  drop=0  byte_mis=0  mis=0
```

## Two frames in the buffer

`python3 scripts/gen_pcap.py --queue queue.pcap` writes two broadcasts. The second is accepted while the first is still leaving, so the log's `overlap` count is not zero. Log: [ci_queue.log](ci_queue.log).

```bash
python3 scripts/gen_pcap.py --queue queue.pcap
make PCAP=queue.pcap MAX_PACKETS=8
```

```
[BR] rx_a=2  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=0  drop=0  byte_mis=0  mis=0
```

## Lengths

`LEN=0` is the default, 12 to 2048 bytes. `LEN=1` accepts 64 to 1518. `LEN=2` accepts 64 to 9000. Logs: [ci_len64.log](ci_len64.log), [ci_jumbo.log](ci_jumbo.log).

```bash
python3 scripts/gen_pcap.py --len64 len64.pcap
make PCAP=len64.pcap MAX_PACKETS=8 LEN=1
python3 scripts/gen_pcap.py --jumbo jumbo.pcap
make PCAP=jumbo.pcap MAX_PACKETS=8 LEN=2
```

`LEN=1` drops a 63-byte frame and a 1519-byte frame, and still filters the MAC learned by the 64-byte frame:

```
[BR] rx_a=4  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=2  byte_mis=0  mis=0
```

`LEN=2` forwards a 3000-byte frame, drops 9001 bytes, and filters the learned MAC:

```
[BR] rx_a=3  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=1  byte_mis=0  mis=0
```

## One VLAN

`python3 scripts/gen_pcap.py --vlan vlan.pcap` learns `02:00:00:00:00:01` on VID 5, misses that MAC untagged, then filters it on VID 5. Log: [ci_vlan.log](ci_vlan.log).

```bash
python3 scripts/gen_pcap.py --vlan vlan.pcap
make PCAP=vlan.pcap MAX_PACKETS=8
```

```
[BR] rx_a=3  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=1  drop=0  byte_mis=0  mis=0
```

## Static multicast

`python3 scripts/gen_pcap.py --mcast mcast.pcap` writes the group `01:00:5e:00:00:01`, an unknown group, and the known group on port B. `MCAST=1` installs that group on B. `PORT_TS=1` takes the port from the pcap seconds field. Log: [ci_mcast.log](ci_mcast.log).

```bash
python3 scripts/gen_pcap.py --mcast mcast.pcap
make PCAP=mcast.pcap MAX_PACKETS=8 PORT_TS=1 MCAST=1
```

```
[BR] rx_a=2  rx_b=1  tx_a=0  tx_b=2  flood=1  fwd=1  filter=1  drop=0  byte_mis=0  mis=0
```
