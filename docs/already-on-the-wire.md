# Already on the wire

It wins as a checkable RTL block. It loses as a switch you would ship against the parts that already exist.

The difference is the scoreboard. `pkt_l2br` and `dpi/l2_model.c` run the same 1K table on the same pcap bytes, and the gate is `mis=0`. A KSZ8863, a top-of-rack switch, and a ConnectX eSwitch will forward the frames. None of them hands you the RTL and a C twin that have to print the same flood, forward, filter, and drop counts.

| | L2AxisBr | KSZ8863 | ToR switch | ConnectX / BlueField eSwitch | Open MAC |
|---|---|---|---|---|---|
| What you get | Verilog you can simulate | A chip with two PHYs | A rack switch | A NIC that offloads a Linux bridge | AXI-Stream MAC only |
| Table | 1K, move, clock aging | 1K, move, ~200 s aging | Hundreds of thousands | Kernel learns, hardware installs the entry | None |
| Where it sits | Verilator, two AXI-Stream ports | Two 10/100 jacks | Datacenter row | GPU server NIC, RoCE, GPUDirect | Beside a bridge, not instead of one |
| Check | pcap in, C and HDL agree | Datasheet and a lab | Vendor tests | Driver and kernel bridge | MAC loopback |

Against a KSZ8863 it does not win on aging, PHYs, or price. Against a Spectrum or Tomahawk switch it does not win on table size, ports, or management. Against ConnectX it does not win on RoCE or GPUDirect: that NIC already sits on the path beside the GPUs. Against the open MACs there is nothing to beat; those cores are the two ends this bridge would plug into.

The place it matches a win is an FPGA packet pipeline where the forwarding decision has to be yours and reviewable. You keep `make demo` as the gate, attach those open MACs or AMD AXI Ethernet on `a_s_*` and `b_m_*`, and every change to learn or filter still has to stay `mis=0` in both files. That is the win over a black-box switch chip.
