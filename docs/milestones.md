# Later

Each one is added in both `hdl/pkt_l2br.sv` and `dpi/l2_model.c`. `make ci` still ends at `mis=0` and `byte_mis=0`. STP, LAG, and QinQ stay out.

1. **Aging.** Supported. `AGE=N` expires an entry N clocks after it was learned or refreshed. `AGE=0` is the default. The next unicast to an expired MAC floods.
2. **Station move in the regression.** Supported. A source learned on A and then seen on B is updated. Traffic to that MAC leaves on B. `PORT_TS=1` picks the port from the pcap timestamp, and `make ci` checks the forward.
3. **Both ports in one cycle.** Supported. `BOTH=1` offers a beat on A and B together. The twins still apply A, then B.
4. **More than one frame in the ingress buffer.** Supported. The next frame is accepted while the previous one is still leaving. `make ci` checks that those cycles overlap.
5. **Ethernet lengths.** Supported. `LEN=0` is 12 to 2048. `LEN=1` is 64 to 1518. `LEN=2` is 64 to 9000.
6. **One VLAN.** Supported. A source is learned with its 802.1Q VID. Untagged frames stay on VID 0. Flood and filter stay inside that VID.
7. **Slot compare.** Supported. After the pcap, every valid bit, MAC, VID, and port is checked against the C table. A mismatch adds to `mis`.
8. **The whole capture.** Supported. `make ci` replays all 1000 frames of `ns1_iperf.pcap`, once into port A and once with `SPLIT=1`.
9. **Other widths.** Supported. The same split pcap passes at `AXIS_W` 32, 128, and 256, along with 8 and 64.
10. **A static multicast table.** Supported. `MCAST=1` installs `01:00:5e:00:00:01` on port B. That group is forwarded from A and filtered on B. An unknown group still floods.
