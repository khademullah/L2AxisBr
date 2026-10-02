# L2AxisBr — two-port learning bridge. Pcap replay is the stimulus.

VERILATOR = verilator
TOP_MODULE = tb_l2br
WAVE_VIEWER = gtkwave

HDL_DIR = hdl
DPI_DIR = dpi
SV_SOURCES = \
	$(HDL_DIR)/tb_l2br.sv \
	$(HDL_DIR)/pkt_l2br.sv \
	$(HDL_DIR)/pkt_l2_obs.sv
C_SOURCES = \
	$(DPI_DIR)/pcap_reader.c \
	$(DPI_DIR)/l2_model.c
WAVE_FILE = simulation_trace.vcd
LOG_FILE  = simulation.log

MAX_PACKETS ?= 100
PCAP ?= ns1_iperf.pcap
BP ?= 0
PAUSE ?= 0
SPLIT ?= 0
AGE ?= 0
TS_GAP ?= 0
PORT_TS ?= 0
BOTH ?= 0
LEN ?= 0
MCAST ?= 0
FILTER ?=
AXIS_W ?= 8

VERILATOR_FLAGS = --binary --timing --trace -j 0 --top-module $(TOP_MODULE) -GDATA_W=$(AXIS_W)
LDFLAGS = -LDFLAGS "-lpcap"

.PHONY: all
all: run

.PHONY: compile
compile: $(SV_SOURCES) $(C_SOURCES)
	@if [ -f obj_dir/.axis_w ] && [ "$$(cat obj_dir/.axis_w)" != "$(AXIS_W)" ]; then \
		echo "[MAKE] AXIS_W changed ($(AXIS_W)); rebuilding..."; \
		rm -rf obj_dir; \
	fi
	@if [ -f obj_dir/.src_w ] && [ "$$(cat obj_dir/.src_w)" != "$(C_SOURCES) $(SV_SOURCES)" ]; then \
		echo "[MAKE] sources changed; rebuilding..."; \
		rm -rf obj_dir; \
	fi
	@echo "[MAKE] Verilating pkt_l2br..."
	$(VERILATOR) $(VERILATOR_FLAGS) $(SV_SOURCES) $(C_SOURCES) $(LDFLAGS)
	@echo $(AXIS_W) > obj_dir/.axis_w
	@echo "$(C_SOURCES) $(SV_SOURCES)" > obj_dir/.src_w

.PHONY: run
run: compile
	@echo "[MAKE] Replaying $(PCAP)..."
	@set -o pipefail; ./obj_dir/V$(TOP_MODULE) \
		+MAX_PACKETS=$(MAX_PACKETS) +PCAP="$(PCAP)" \
		+BP=$(BP) +PAUSE=$(PAUSE) +SPLIT=$(SPLIT) \
		+AGE=$(AGE) +TS_GAP=$(TS_GAP) +PORT_TS=$(PORT_TS) +BOTH=$(BOTH) \
		+LEN=$(LEN) +MCAST=$(MCAST) \
		$(if $(FILTER),+FILTER="$(FILTER)",) | tee $(LOG_FILE)

.PHONY: ci
ci:
	mkdir -p examples
	python3 scripts/gen_pcap.py ci.pcap
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 BP=2
	grep -q "Streamed 7 packets" $(LOG_FILE)
	grep -q "rx_a=7  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=5  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_port_a.log
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 BP=2 SPLIT=1
	grep -q "rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_split.log
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=64
	grep -q "rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 PAUSE=1
	grep -q "rx_a=7  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=5  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	python3 scripts/gen_pcap.py --drop drop.pcap
	$(MAKE) run PCAP=drop.pcap MAX_PACKETS=8 BP=2
	grep -q "Streamed 3 packets" $(LOG_FILE)
	grep -q "rx_a=3  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=1  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_drop.log
	$(MAKE) run PCAP=drop.pcap MAX_PACKETS=8 BP=2 AXIS_W=64
	grep -q "rx_a=3  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=1  byte_mis=0  mis=0" $(LOG_FILE)
	python3 scripts/gen_pcap.py --table table.pcap
	$(MAKE) run PCAP=table.pcap MAX_PACKETS=32 BP=2
	grep -q "Streamed 18 packets" $(LOG_FILE)
	grep -q "rx_a=18  rx_b=0  tx_a=0  tx_b=17  flood=17  fwd=0  filter=1  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_table.log
	python3 scripts/gen_pcap.py --age age.pcap
	$(MAKE) run PCAP=age.pcap MAX_PACKETS=8 AGE=1000 TS_GAP=1
	grep -q "Streamed 3 packets" $(LOG_FILE)
	grep -q "rx_a=3  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=1  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_age.log
	python3 scripts/gen_pcap.py --move move.pcap
	$(MAKE) run PCAP=move.pcap MAX_PACKETS=8 PORT_TS=1
	grep -q "Streamed 3 packets" $(LOG_FILE)
	grep -q "rx_a=2  rx_b=1  tx_a=1  tx_b=2  flood=2  fwd=1  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_move.log
	python3 scripts/gen_pcap.py --both both.pcap
	$(MAKE) run PCAP=both.pcap MAX_PACKETS=8 BOTH=1
	grep -q "Streamed 2 packets" $(LOG_FILE)
	grep -q "rx_a=1  rx_b=1  tx_a=1  tx_b=1  flood=1  fwd=1  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_both.log
	python3 scripts/gen_pcap.py --queue queue.pcap
	$(MAKE) run PCAP=queue.pcap MAX_PACKETS=8
	grep -q "Streamed 2 packets" $(LOG_FILE)
	grep -q "rx_a=2  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	grep -E -q "overlap=[1-9]" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_queue.log
	python3 scripts/gen_pcap.py --len64 len64.pcap
	$(MAKE) run PCAP=len64.pcap MAX_PACKETS=8 LEN=1
	grep -q "Streamed 4 packets" $(LOG_FILE)
	grep -q "rx_a=4  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=2  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_len64.log
	python3 scripts/gen_pcap.py --jumbo jumbo.pcap
	$(MAKE) run PCAP=jumbo.pcap MAX_PACKETS=8 LEN=2
	grep -q "Streamed 3 packets" $(LOG_FILE)
	grep -q "rx_a=3  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=1  drop=1  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_jumbo.log
	python3 scripts/gen_pcap.py --vlan vlan.pcap
	$(MAKE) run PCAP=vlan.pcap MAX_PACKETS=8
	grep -q "Streamed 3 packets" $(LOG_FILE)
	grep -q "rx_a=3  rx_b=0  tx_a=0  tx_b=2  flood=2  fwd=0  filter=1  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_vlan.log
	python3 scripts/gen_pcap.py --mcast mcast.pcap
	$(MAKE) run PCAP=mcast.pcap MAX_PACKETS=8 PORT_TS=1 MCAST=1
	grep -q "Streamed 3 packets" $(LOG_FILE)
	grep -q "rx_a=2  rx_b=1  tx_a=0  tx_b=2  flood=1  fwd=1  filter=1  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_mcast.log
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=32
	grep -q "rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=128
	grep -q "rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	$(MAKE) run PCAP=ci.pcap MAX_PACKETS=8 SPLIT=1 AXIS_W=256
	grep -q "rx_a=4  rx_b=3  tx_a=3  tx_b=4  flood=2  fwd=5  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	$(MAKE) run PCAP=ns1_iperf.pcap MAX_PACKETS=1000 BP=2
	grep -q "Streamed 1000 packets" $(LOG_FILE)
	grep -q "rx_a=1000  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=999  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_iperf_1000.log
	$(MAKE) run PCAP=ns1_iperf.pcap MAX_PACKETS=1000 BP=2 SPLIT=1
	grep -q "rx_a=731  rx_b=269  tx_a=269  tx_b=731  flood=1  fwd=999  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ci_iperf_1000_split.log

.PHONY: demo
demo:
	$(MAKE) run PCAP=ns1_iperf.pcap MAX_PACKETS=64 BP=2
	grep -q "Streamed 64 packets" $(LOG_FILE)
	grep -q "rx_a=64  rx_b=0  tx_a=0  tx_b=1  flood=1  fwd=0  filter=63  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ns1_iperf_64.log
	$(MAKE) run PCAP=ns1_iperf.pcap MAX_PACKETS=64 BP=2 SPLIT=1
	grep -q "rx_a=38  rx_b=26  tx_a=26  tx_b=38  flood=1  fwd=63  filter=0  drop=0  byte_mis=0  mis=0" $(LOG_FILE)
	cp $(LOG_FILE) examples/ns1_iperf_64_split.log

.PHONY: wave
wave:
	@if [ ! -f $(WAVE_FILE) ]; then \
		echo "[ERROR] $(WAVE_FILE) not found. Run make first."; \
		exit 1; \
	fi
	$(WAVE_VIEWER) $(WAVE_FILE) > /dev/null 2>&1 &

.PHONY: clean
clean:
	rm -rf obj_dir/
	rm -f $(WAVE_FILE) $(LOG_FILE)

.PHONY: help
help:
	@echo "  make demo                       - ns1_iperf.pcap, port A then SPLIT=1"
	@echo "  make PCAP=ns1_iperf.pcap MAX_PACKETS=64 BP=2"
	@echo "  make PCAP=ns1_iperf.pcap MAX_PACKETS=64 BP=2 SPLIT=1"
	@echo "  make ci                         - regression, including an 8-byte drop"
	@echo "  make PAUSE=1                    - bubble on s_tready"
	@echo "  make AXIS_W=64"
	@echo "  make FILTER='tcp port 5201'"
	@echo "  make wave"
	@echo "  make clean"
