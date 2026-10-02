# Contributing

`pkt_l2br` is a two-port learning bridge. Pcap2HDL remains the pcap fixture; do not fold a live TAP or a Linux `br0` into this repo.

## Gates

```bash
make ci
```

That replays the seven-frame pcap into port A (`mis=0`, `tx_b=2`), then split across both ports (`tx_a=3`, `tx_b=4`), then `AXIS_W=64` and `PAUSE=1`. A change to the learn / flood / filter rules has to land in both `hdl/pkt_l2br.sv` and `dpi/l2_model.c`. `CAM_N` is 1024 and `MAX_B` is 2048 on both sides.

Sample a beat only when `tvalid && tready`. Keep `pkt_l2_obs` on the port pins.

## Out of scope for the first cut

STP, LAG, QinQ, and a live capture path. A FIFO that copies A to B with no table is a loopback; the table is the point.
