// Replay an offline pcap into pkt_l2br.
// Default: every frame into port A. SPLIT=1 sends source MAC
// 02:00:00:00:00:01 into A and every other source into B.
// Observers sit on the port wires. dpi/l2_model.c is the MAC-table twin.
// Ingress fingerprint is get_fingerprint(); egress must match that sum.

`timescale 1ns/1ps

module tb_l2br #(
    parameter int DATA_W = 8
);

    localparam int KEEP_W = DATA_W / 8;
    localparam int QN     = 32;
    localparam logic [47:0] HOST_A = 48'h02_00_00_00_00_01;

    import "DPI-C" function int open_pcap(input string filename);
    import "DPI-C" function int fetch_next_packet();
    import "DPI-C" function int get_wire_len();
    import "DPI-C" function longint get_ts_sec();
    import "DPI-C" function int get_ts_usec();
    import "DPI-C" function int get_datalink();
    import "DPI-C" function int get_packet_byte();
    import "DPI-C" function int unsigned get_fingerprint();
    import "DPI-C" function void close_pcap();
    import "DPI-C" function int set_pcap_filter(input string filter);
    import "DPI-C" function int get_bpf_match();
    import "DPI-C" function int get_bpf_skip();
    import "DPI-C" function void l2_reset();
    import "DPI-C" function int l2_predict(
        input int     port,
        input longint da,
        input longint sa,
        input int     nbytes
    );

    logic clk;
    logic rst_n;
    logic bp_ready;

    logic [DATA_W-1:0]   a_tdata;
    logic [KEEP_W-1:0]   a_tkeep;
    logic                a_tvalid;
    logic                a_tready;
    logic                a_tstart;
    logic                a_tlast;
    logic [31:0]         a_tuser;
    logic                a_terr;

    logic [DATA_W-1:0]   b_tdata;
    logic [KEEP_W-1:0]   b_tkeep;
    logic                b_tvalid;
    logic                b_tready;
    logic                b_tstart;
    logic                b_tlast;
    logic [31:0]         b_tuser;
    logic                b_terr;

    logic [DATA_W-1:0]   a_m_tdata;
    logic [KEEP_W-1:0]   a_m_tkeep;
    logic                a_m_tvalid;
    logic                a_m_tready;
    logic                a_m_tstart;
    logic                a_m_tlast;
    logic [31:0]         a_m_tuser;
    logic                a_m_terr;

    logic [DATA_W-1:0]   b_m_tdata;
    logic [KEEP_W-1:0]   b_m_tkeep;
    logic                b_m_tvalid;
    logic                b_m_tready;
    logic                b_m_tstart;
    logic                b_m_tlast;
    logic [31:0]         b_m_tuser;
    logic                b_m_terr;

    logic                a_dec_valid;
    logic [1:0]          a_dec_act;
    logic [31:0]         a_dec_bytes;
    logic                b_dec_valid;
    logic [1:0]          b_dec_act;
    logic [31:0]         b_dec_bytes;
    logic                a_busy;
    logic                b_busy;

    logic                a_obs_valid;
    logic [31:0]         a_obs_bytes;
    logic [47:0]         a_obs_da;
    logic [47:0]         a_obs_sa;
    logic [31:0]         a_obs_sum;
    logic                b_obs_valid;
    logic [31:0]         b_obs_bytes;
    logic [47:0]         b_obs_da;
    logic [47:0]         b_obs_sa;
    logic [31:0]         b_obs_sum;
    logic                ae_obs_valid;
    logic [31:0]         ae_obs_bytes;
    logic [47:0]         ae_obs_da;
    logic [47:0]         ae_obs_sa;
    logic [31:0]         ae_obs_sum;
    logic                be_obs_valid;
    logic [31:0]         be_obs_bytes;
    logic [47:0]         be_obs_da;
    logic [47:0]         be_obs_sa;
    logic [31:0]         be_obs_sum;

    logic [7:0] frm [0:2047];

    int bp_arg;
    int pause_arg;
    int split_arg;
    int max_packets;
    int packet_count;
    int cur_len;
    int cur_port;
    int n_rx_a, n_rx_b, n_tx_a, n_tx_b;
    int n_flood, n_fwd, n_filter, n_drop;
    int n_mis, n_byte_mis;
    int unsigned qa_len [0:QN-1];
    int unsigned qa_sum [0:QN-1];
    int unsigned qb_len [0:QN-1];
    int unsigned qb_sum [0:QN-1];
    int qa_h, qa_t, qa_n;
    int qb_h, qb_t, qb_n;
    string pcap_name;
    string pcap_arg;
    string filter_arg;

    pkt_l2br #(.DATA_W(DATA_W)) u_br (
        .clk(clk),
        .rst_n(rst_n),
        .a_s_tdata(a_tdata),
        .a_s_tkeep(a_tkeep),
        .a_s_tvalid(a_tvalid),
        .a_s_tready(a_tready),
        .a_s_tstart(a_tstart),
        .a_s_tlast(a_tlast),
        .a_s_tuser(a_tuser),
        .a_s_tuser_err(a_terr),
        .a_ready_mask(bp_ready),
        .a_pause_en(pause_arg != 0),
        .b_s_tdata(b_tdata),
        .b_s_tkeep(b_tkeep),
        .b_s_tvalid(b_tvalid),
        .b_s_tready(b_tready),
        .b_s_tstart(b_tstart),
        .b_s_tlast(b_tlast),
        .b_s_tuser(b_tuser),
        .b_s_tuser_err(b_terr),
        .b_ready_mask(bp_ready),
        .b_pause_en(pause_arg != 0),
        .a_m_tdata(a_m_tdata),
        .a_m_tkeep(a_m_tkeep),
        .a_m_tvalid(a_m_tvalid),
        .a_m_tready(a_m_tready),
        .a_m_tstart(a_m_tstart),
        .a_m_tlast(a_m_tlast),
        .a_m_tuser(a_m_tuser),
        .a_m_tuser_err(a_m_terr),
        .b_m_tdata(b_m_tdata),
        .b_m_tkeep(b_m_tkeep),
        .b_m_tvalid(b_m_tvalid),
        .b_m_tready(b_m_tready),
        .b_m_tstart(b_m_tstart),
        .b_m_tlast(b_m_tlast),
        .b_m_tuser(b_m_tuser),
        .b_m_tuser_err(b_m_terr),
        .a_dec_valid(a_dec_valid),
        .a_dec_act(a_dec_act),
        .a_dec_bytes(a_dec_bytes),
        .b_dec_valid(b_dec_valid),
        .b_dec_act(b_dec_act),
        .b_dec_bytes(b_dec_bytes),
        .a_busy(a_busy),
        .b_busy(b_busy)
    );

    pkt_l2_obs #(.DATA_W(DATA_W)) u_obs_a (
        .clk(clk), .rst_n(rst_n),
        .tdata(a_tdata), .tkeep(a_tkeep),
        .tvalid(a_tvalid), .tready(a_tready),
        .tstart(a_tstart), .tlast(a_tlast),
        .obs_valid(a_obs_valid), .obs_bytes(a_obs_bytes),
        .obs_da(a_obs_da), .obs_sa(a_obs_sa), .obs_sum(a_obs_sum)
    );
    pkt_l2_obs #(.DATA_W(DATA_W)) u_obs_b (
        .clk(clk), .rst_n(rst_n),
        .tdata(b_tdata), .tkeep(b_tkeep),
        .tvalid(b_tvalid), .tready(b_tready),
        .tstart(b_tstart), .tlast(b_tlast),
        .obs_valid(b_obs_valid), .obs_bytes(b_obs_bytes),
        .obs_da(b_obs_da), .obs_sa(b_obs_sa), .obs_sum(b_obs_sum)
    );
    pkt_l2_obs #(.DATA_W(DATA_W)) u_obs_ae (
        .clk(clk), .rst_n(rst_n),
        .tdata(a_m_tdata), .tkeep(a_m_tkeep),
        .tvalid(a_m_tvalid), .tready(a_m_tready),
        .tstart(a_m_tstart), .tlast(a_m_tlast),
        .obs_valid(ae_obs_valid), .obs_bytes(ae_obs_bytes),
        .obs_da(ae_obs_da), .obs_sa(ae_obs_sa), .obs_sum(ae_obs_sum)
    );
    pkt_l2_obs #(.DATA_W(DATA_W)) u_obs_be (
        .clk(clk), .rst_n(rst_n),
        .tdata(b_m_tdata), .tkeep(b_m_tkeep),
        .tvalid(b_m_tvalid), .tready(b_m_tready),
        .tstart(b_m_tstart), .tlast(b_m_tlast),
        .obs_valid(be_obs_valid), .obs_bytes(be_obs_bytes),
        .obs_da(be_obs_da), .obs_sa(be_obs_sa), .obs_sum(be_obs_sum)
    );

    function automatic string act_name(input int act);
        case (act)
            0: act_name = "FILTER";
            1: act_name = "FWD";
            2: act_name = "FLOOD";
            default: act_name = "DROP";
        endcase
    endfunction

    task automatic note_act(input int act);
        case (act)
            0: n_filter = n_filter + 1;
            1: n_fwd    = n_fwd + 1;
            2: n_flood  = n_flood + 1;
            default: n_drop = n_drop + 1;
        endcase
    endtask

    task automatic q_push_b(input int unsigned len, input int unsigned sum);
        if (qb_n >= QN) begin
            n_byte_mis = n_byte_mis + 1;
        end else begin
            qb_len[qb_t] = len;
            qb_sum[qb_t] = sum;
            qb_t = (qb_t + 1) % QN;
            qb_n = qb_n + 1;
        end
    endtask

    task automatic q_push_a(input int unsigned len, input int unsigned sum);
        if (qa_n >= QN) begin
            n_byte_mis = n_byte_mis + 1;
        end else begin
            qa_len[qa_t] = len;
            qa_sum[qa_t] = sum;
            qa_t = (qa_t + 1) % QN;
            qa_n = qa_n + 1;
        end
    endtask

    task automatic score_ing(
        input int          port,
        input logic        dec_ok,
        input logic [1:0]  dec_act,
        input logic [31:0] dec_bytes,
        input logic [31:0] obytes,
        input logic [47:0] oda,
        input logic [47:0] osa,
        input logic [31:0] osum
    );
        int c_act;
        if (cur_port != port || obytes != 32'(cur_len) || osum != get_fingerprint()) begin
            n_mis = n_mis + 1;
            $display("[BR] %s MIS  obs %0d B fp=%08h  file %0d B fp=%08h",
                     (port != 0) ? "B" : "A", obytes, osum, cur_len, get_fingerprint());
        end
        c_act = l2_predict(port, longint'(oda), longint'(osa), int'(obytes));
        if (!dec_ok || (dec_act != c_act[1:0]) || (dec_bytes != obytes)) begin
            n_mis = n_mis + 1;
            $display("[BR] %s MIS  dut %s %0d B  c %s",
                     (port != 0) ? "B" : "A",
                     dec_ok ? act_name(int'(dec_act)) : "NONE",
                     dec_bytes, act_name(c_act));
        end else begin
            note_act(c_act);
            $display("[BR] %s %s  %0d B  da=%012h sa=%012h",
                     (port != 0) ? "B" : "A", act_name(c_act), obytes, oda, osa);
        end
        if (c_act == 1 || c_act == 2) begin
            if (port == 0)
                q_push_b(obytes, osum);
            else
                q_push_a(obytes, osum);
        end
    endtask

    always #5 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bp_ready <= 1'b1;
        else if (bp_arg == 1)
            bp_ready <= ~bp_ready;
        else if (bp_arg == 2)
            bp_ready <= 1'($urandom_range(0, 1));
        else
            bp_ready <= 1'b1;
    end

    assign a_m_tready = bp_ready;
    assign b_m_tready = bp_ready;

    always @(posedge clk) begin
        if (rst_n && a_obs_valid) begin
            n_rx_a = n_rx_a + 1;
            score_ing(0, a_dec_valid, a_dec_act, a_dec_bytes,
                      a_obs_bytes, a_obs_da, a_obs_sa, a_obs_sum);
        end
        if (rst_n && b_obs_valid) begin
            n_rx_b = n_rx_b + 1;
            score_ing(1, b_dec_valid, b_dec_act, b_dec_bytes,
                      b_obs_bytes, b_obs_da, b_obs_sa, b_obs_sum);
        end
        if (rst_n && ae_obs_valid) begin
            n_tx_a = n_tx_a + 1;
            if (qa_n == 0) begin
                n_byte_mis = n_byte_mis + 1;
                $display("[BR] BYTE_MIS  egress A with empty expect");
            end else begin
                if (qa_len[qa_h] != ae_obs_bytes || qa_sum[qa_h] != ae_obs_sum) begin
                    n_byte_mis = n_byte_mis + 1;
                    $display("[BR] BYTE_MIS  A exp %0d/%08h got %0d/%08h",
                             qa_len[qa_h], qa_sum[qa_h], ae_obs_bytes, ae_obs_sum);
                end
                qa_h = (qa_h + 1) % QN;
                qa_n = qa_n - 1;
            end
        end
        if (rst_n && be_obs_valid) begin
            n_tx_b = n_tx_b + 1;
            if (qb_n == 0) begin
                n_byte_mis = n_byte_mis + 1;
                $display("[BR] BYTE_MIS  egress B with empty expect");
            end else begin
                if (qb_len[qb_h] != be_obs_bytes || qb_sum[qb_h] != be_obs_sum) begin
                    n_byte_mis = n_byte_mis + 1;
                    $display("[BR] BYTE_MIS  B exp %0d/%08h got %0d/%08h",
                             qb_len[qb_h], qb_sum[qb_h], be_obs_bytes, be_obs_sum);
                end
                qb_h = (qb_h + 1) % QN;
                qb_n = qb_n - 1;
            end
        end
    end

    task automatic drive_frame(input int port, input int len);
        int i, k, spins;
        for (i = 0; i < len; i = i + KEEP_W) begin
            @(negedge clk);
            if (port == 0) begin
                a_tdata  = '0;
                a_tkeep  = '0;
                for (k = 0; k < KEEP_W; k = k + 1) begin
                    if ((i + k) < len) begin
                        a_tdata[8*k +: 8] = frm[i + k];
                        a_tkeep[k]        = 1'b1;
                    end
                end
                a_tvalid = 1'b1;
                a_tstart = (i == 0);
                a_tlast  = ((i + KEEP_W) >= len);
                a_tuser  = packet_count;
                a_terr   = 1'b0;
            end else begin
                b_tdata  = '0;
                b_tkeep  = '0;
                for (k = 0; k < KEEP_W; k = k + 1) begin
                    if ((i + k) < len) begin
                        b_tdata[8*k +: 8] = frm[i + k];
                        b_tkeep[k]        = 1'b1;
                    end
                end
                b_tvalid = 1'b1;
                b_tstart = (i == 0);
                b_tlast  = ((i + KEEP_W) >= len);
                b_tuser  = packet_count;
                b_terr   = 1'b0;
            end
            spins = 0;
            do begin
                @(posedge clk);
                spins = spins + 1;
                if (spins > 200000)
                    $fatal(1, "[BR] tready stuck on port %s", (port != 0) ? "B" : "A");
            end while (port == 0 ? !a_tready : !b_tready);
        end
        @(negedge clk);
        if (port == 0) begin
            a_tvalid = 1'b0;
            a_tstart = 1'b0;
            a_tlast  = 1'b0;
            a_tdata  = '0;
            a_tkeep  = '0;
        end else begin
            b_tvalid = 1'b0;
            b_tstart = 1'b0;
            b_tlast  = 1'b0;
            b_tdata  = '0;
            b_tkeep  = '0;
        end
    endtask

    initial begin
        $dumpfile("simulation_trace.vcd");
        $dumpvars(0, tb_l2br);
    end

    initial begin
        int pkt_len;
        int pkt_wire;
        int dlt;
        int port;
        int guard;
        longint ts_sec;
        int ts_usec;
        logic [47:0] src_m;

        clk          = 1'b0;
        rst_n        = 1'b0;
        a_tdata      = '0;
        a_tkeep      = '0;
        a_tvalid     = 1'b0;
        a_tstart     = 1'b0;
        a_tlast      = 1'b0;
        a_tuser      = '0;
        a_terr       = 1'b0;
        b_tdata      = '0;
        b_tkeep      = '0;
        b_tvalid     = 1'b0;
        b_tstart     = 1'b0;
        b_tlast      = 1'b0;
        b_tuser      = '0;
        b_terr       = 1'b0;
        bp_arg       = 0;
        pause_arg    = 0;
        split_arg    = 0;
        max_packets  = 100;
        packet_count = 0;
        cur_len      = 0;
        cur_port     = 0;
        n_rx_a = 0; n_rx_b = 0; n_tx_a = 0; n_tx_b = 0;
        n_flood = 0; n_fwd = 0; n_filter = 0; n_drop = 0;
        n_mis = 0; n_byte_mis = 0;
        qa_h = 0; qa_t = 0; qa_n = 0;
        qb_h = 0; qb_t = 0; qb_n = 0;
        pcap_name = "ns1_iperf.pcap";
        filter_arg = "";
        void'($value$plusargs("MAX_PACKETS=%d", max_packets));
        void'($value$plusargs("BP=%d", bp_arg));
        void'($value$plusargs("PAUSE=%d", pause_arg));
        void'($value$plusargs("SPLIT=%d", split_arg));
        if ($value$plusargs("PCAP=%s", pcap_arg) && pcap_arg.len() != 0)
            pcap_name = pcap_arg;
        void'($value$plusargs("FILTER=%s", filter_arg));

        #20;
        rst_n = 1'b1;
        #10;
        l2_reset();

        $display("[SV] Opening %s", pcap_name);
        if (pcap_name.len() == 0 || open_pcap(pcap_name) != 0) begin
            $display("[SV] Failed to open PCAP file. Exiting.");
            $fatal(1);
        end
        dlt = get_datalink();
        $display("[SV] Datalink DLT=%0d%s", dlt, (dlt == 1) ? " (Ethernet)" : "");
        if (dlt != 1) begin
            $display("[SV] L2AxisBr wants Ethernet DLT=1.");
            close_pcap();
            $fatal(1);
        end
        if (filter_arg.len() != 0) begin
            if (set_pcap_filter(filter_arg) != 0) begin
                $display("[SV] Failed to install BPF filter. Exiting.");
                close_pcap();
                $fatal(1);
            end
        end
        if (DATA_W != 8)
            $display("[SV] AXIS DATA_W=%0d (%0d bytes/beat)", DATA_W, KEEP_W);
        begin
            string banner;
            if (split_arg != 0)
                banner = $sformatf("[SV] Streaming up to %0d packets into port by source MAC", max_packets);
            else
                banner = $sformatf("[SV] Streaming up to %0d packets into port A", max_packets);
            if (bp_arg == 1)
                banner = {banner, " (BP=1, tready 50%)"};
            else if (bp_arg == 2)
                banner = {banner, " (BP=2, random tready)"};
            if (pause_arg != 0)
                banner = {banner, " PAUSE=1"};
            if (filter_arg.len() != 0)
                banner = {banner, " FILTER=", filter_arg};
            $display("%s", banner);
        end

        while (packet_count < max_packets) begin
            pkt_len = fetch_next_packet();
            if (pkt_len == 0) begin
                $display("\n[SV] Reached end of PCAP before hitting the packet cap.");
                break;
            end
            if (pkt_len > 2048) begin
                $display("[SV] Frame %0d B exceeds the bench buffer.", pkt_len);
                close_pcap();
                $fatal(1);
            end
            pkt_wire = get_wire_len();
            ts_sec   = get_ts_sec();
            ts_usec  = get_ts_usec();
            packet_count = packet_count + 1;
            for (int bi = 0; bi < pkt_len; bi = bi + 1)
                frm[bi] = 8'(get_packet_byte());
            if (pkt_len >= 12)
                src_m = {frm[6], frm[7], frm[8], frm[9], frm[10], frm[11]};
            else
                src_m = '0;
            port = (split_arg != 0 && src_m != HOST_A) ? 1 : 0;
            cur_len  = pkt_len;
            cur_port = port;
            $display("[SV] Packet #%0d port %s  %0d B (wire %0d) ts=%0d.%06d",
                     packet_count, (port != 0) ? "B" : "A", pkt_len, pkt_wire, ts_sec, ts_usec);
            drive_frame(port, pkt_len);
            repeat (4) @(posedge clk);
        end

        for (guard = 0; guard < 200000; guard = guard + 1) begin
            @(posedge clk);
            if (!a_busy && !b_busy)
                break;
        end
        repeat (4) @(posedge clk);
        if (a_busy || b_busy) begin
            $display("[BR] timeout waiting for egress");
            n_byte_mis = n_byte_mis + 1;
        end
        if (qa_n != 0 || qb_n != 0) begin
            $display("[BR] BYTE_MIS  %0d egress frame(s) still expected", qa_n + qb_n);
            n_byte_mis = n_byte_mis + qa_n + qb_n;
        end

        close_pcap();
        if (filter_arg.len() != 0)
            $display("[C-DPI] BPF matched=%0d skipped=%0d", get_bpf_match(), get_bpf_skip());
        $display("\n[SV] Simulation finished. File=%s  Streamed %0d packets.",
                 pcap_name, packet_count);
        $display("[BR] rx_a=%0d  rx_b=%0d  tx_a=%0d  tx_b=%0d  flood=%0d  fwd=%0d  filter=%0d  drop=%0d  byte_mis=%0d  mis=%0d",
                 n_rx_a, n_rx_b, n_tx_a, n_tx_b, n_flood, n_fwd, n_filter, n_drop,
                 n_byte_mis, n_mis);
        if (n_mis != 0 || n_byte_mis != 0)
            $fatal(1, "[BR] scoreboard failed");
        $finish;
    end

endmodule
