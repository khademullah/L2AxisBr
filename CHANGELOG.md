# Changelog

## 0.1.0

- `pkt_l2br`: two `nic_rx`-shaped AXI-Stream slaves, two masters, 1024-entry MAC table.
- Learn unicast SA, then filter, forward, or flood. Drop under 12 bytes or over 2048.
- Offline pcap and BPF in C. `dpi/l2_model.c` scores the same rules (`mis=0`).
- Observers on the port wires. Egress length and fingerprint must match ingress (`byte_mis=0`).
- `scripts/gen_pcap.py`: seven-frame two-host trace. `SPLIT=1` drives the second host into port B.
