// Two-port MAC-learning Ethernet bridge.
// Port A and port B ingress pins match nic_rx's s_* list (plus ready_mask
// and pause_en). Egress is an AXI-Stream master on each port: a frame
// accepted on A leaves on B, and the other way around.
//
// Beat = s_tvalid && s_tready. Each port holds two frames. s_tready stays
// high while one frame is leaving, and falls when both slots are full.
// ready_mask and pause_en can still pull it low.
// Learn unicast SA, then look up DA. Broadcast and I/G multicast flood the
// other port. DA on this port is filtered. DA on the other port is forwarded.
// A miss floods. len_mode 0 drops under 12 or over 2048. len_mode 1
// drops under 64 or over 1518. len_mode 2 drops under 64 or over 9000.
// The stored buffer is MAX_B bytes either way. A drop does not learn.
// age_limit == 0 keeps an entry until it is replaced. A nonzero age_limit
// expires the entry that many clocks after it was learned or refreshed.
// The C twin is dpi/l2_model.c (CAM_N = 1024, MAX_B = 2048).

`timescale 1ns/1ps

module pkt_l2br #(
    parameter int DATA_W = 8,
    parameter int CAM_N  = 1024,
    parameter int MAX_B  = 9000
) (
    input  logic                clk,
    input  logic                rst_n,
    input  int                  age_limit,
    input  int                  len_mode,
    input  logic                mc_en,

    input  logic [DATA_W-1:0]   a_s_tdata,
    input  logic [DATA_W/8-1:0] a_s_tkeep,
    input  logic                a_s_tvalid,
    output logic                a_s_tready,
    input  logic                a_s_tstart,
    input  logic                a_s_tlast,
    input  logic [31:0]         a_s_tuser,
    input  logic                a_s_tuser_err,
    input  logic                a_ready_mask,
    input  logic                a_pause_en,

    input  logic [DATA_W-1:0]   b_s_tdata,
    input  logic [DATA_W/8-1:0] b_s_tkeep,
    input  logic                b_s_tvalid,
    output logic                b_s_tready,
    input  logic                b_s_tstart,
    input  logic                b_s_tlast,
    input  logic [31:0]         b_s_tuser,
    input  logic                b_s_tuser_err,
    input  logic                b_ready_mask,
    input  logic                b_pause_en,

    output logic [DATA_W-1:0]   a_m_tdata,
    output logic [DATA_W/8-1:0] a_m_tkeep,
    output logic                a_m_tvalid,
    input  logic                a_m_tready,
    output logic                a_m_tstart,
    output logic                a_m_tlast,
    output logic [31:0]         a_m_tuser,
    output logic                a_m_tuser_err,

    output logic [DATA_W-1:0]   b_m_tdata,
    output logic [DATA_W/8-1:0] b_m_tkeep,
    output logic                b_m_tvalid,
    input  logic                b_m_tready,
    output logic                b_m_tstart,
    output logic                b_m_tlast,
    output logic [31:0]         b_m_tuser,
    output logic                b_m_tuser_err,

    output logic                a_dec_valid,
    output logic [1:0]          a_dec_act,
    output logic [31:0]         a_dec_bytes,
    output logic                b_dec_valid,
    output logic [1:0]          b_dec_act,
    output logic [31:0]         b_dec_bytes,
    output logic                a_busy,
    output logic                b_busy
);

    localparam int KEEP_W = DATA_W / 8;
    localparam logic [1:0] ACT_FILTER = 2'd0;
    localparam logic [1:0] ACT_FWD    = 2'd1;
    localparam logic [1:0] ACT_FLOOD  = 2'd2;
    localparam logic [1:0] ACT_DROP   = 2'd3;
    localparam logic ST_IDLE = 1'b0;
    localparam logic ST_RECV = 1'b1;

    logic              a_st;
    logic              b_st;
    logic              a_hold;
    logic              b_hold;
    logic              a_bubble;
    logic              b_bubble;
    logic              a_cap;
    logic              b_cap;
    logic [15:0]       a_nbyte;
    logic [15:0]       b_nbyte;
    logic [15:0]       a_len;
    logic [15:0]       b_len;
    logic [15:0]       a_rd;
    logic [15:0]       b_rd;
    logic [47:0]       a_da;
    logic [47:0]       a_sa;
    logic [47:0]       b_da;
    logic [47:0]       b_sa;
    logic [15:0]       a_et;
    logic [15:0]       a_tci;
    logic [15:0]       b_et;
    logic [15:0]       b_tci;
    logic [31:0]       a_user;
    logic [31:0]       b_user;
    logic              a_err;
    logic              b_err;
    logic [31:0]       eg_b_user;
    logic              eg_b_err;
    logic [31:0]       eg_a_user;
    logic              eg_a_err;
    logic [7:0]        a_mem [0:1][0:MAX_B-1];
    logic [7:0]        b_mem [0:1][0:MAX_B-1];
    logic              a_wr_bank;
    logic              b_wr_bank;
    logic              a_rd_bank;
    logic              b_rd_bank;
    logic [1:0]        a_q;
    logic [1:0]        b_q;
    logic [15:0]       a_slen [0:1];
    logic [15:0]       b_slen [0:1];
    logic [31:0]       a_suser [0:1];
    logic [31:0]       b_suser [0:1];
    logic              a_serr [0:1];
    logic              b_serr [0:1];

    logic              cam_v   [0:CAM_N-1];
    logic [47:0]       cam_mac [0:CAM_N-1];
    logic [11:0]       cam_vid [0:CAM_N-1];
    logic              cam_prt [0:CAM_N-1];
    logic [31:0]       cam_age [0:CAM_N-1];
    logic [31:0]       cam_time;
    int                cam_vic;

    logic              cam_v_w   [0:CAM_N-1];
    logic [47:0]       cam_mac_w [0:CAM_N-1];
    logic [11:0]       cam_vid_w [0:CAM_N-1];
    logic              cam_prt_w [0:CAM_N-1];
    logic [31:0]       cam_age_w [0:CAM_N-1];
    logic [31:0]       time_w;
    int                vic_w;

    wire a_fire = a_s_tvalid && a_s_tready;
    wire b_fire = b_s_tvalid && b_s_tready;

    assign a_s_tready = rst_n && a_ready_mask && !a_bubble && (a_q < 2);
    assign b_s_tready = rst_n && b_ready_mask && !b_bubble && (b_q < 2);
    assign a_busy = (a_st == ST_RECV) || a_hold || b_m_tvalid;
    assign b_busy = (b_st == ST_RECV) || b_hold || a_m_tvalid;

    function automatic int len_min();
        if (len_mode == 0)
            return 12;
        return 64;
    endfunction

    function automatic int len_max();
        if (len_mode == 1)
            return 1518;
        if (len_mode == 2)
            return 9000;
        return 2048;
    endfunction

    function automatic bit cam_live(input int i);
        if (!cam_v_w[i])
            return 1'b0;
        if (age_limit <= 0)
            return 1'b1;
        return (time_w - cam_age_w[i]) < 32'(age_limit);
    endfunction

    function automatic logic [11:0] vid_of(input logic [15:0] et, input logic [15:0] tci);
        if (et == 16'h8100)
            return tci[11:0];
        return 12'd0;
    endfunction

    task automatic cam_learn(input logic [47:0] sa, input logic [11:0] vid, input logic prt);
        bit found;
        if (sa[40])
            return;
        found = 1'b0;
        for (int i = 0; i < CAM_N; i++) begin
            if (!found && cam_live(i) && (cam_mac_w[i] == sa) && (cam_vid_w[i] == vid)) begin
                cam_prt_w[i] = prt;
                cam_age_w[i] = time_w;
                found = 1'b1;
            end
        end
        if (found)
            return;
        for (int i = 0; i < CAM_N; i++) begin
            if (!found && !cam_live(i)) begin
                cam_v_w[i]   = 1'b1;
                cam_mac_w[i] = sa;
                cam_vid_w[i] = vid;
                cam_prt_w[i] = prt;
                cam_age_w[i] = time_w;
                found = 1'b1;
            end
        end
        if (!found) begin
            cam_v_w[vic_w]   = 1'b1;
            cam_mac_w[vic_w] = sa;
            cam_vid_w[vic_w] = vid;
            cam_prt_w[vic_w] = prt;
            cam_age_w[vic_w] = time_w;
            vic_w = (vic_w + 1) % CAM_N;
        end
    endtask

    function automatic logic [1:0] cam_act(input logic [47:0] da, input logic [11:0] vid, input logic prt);
        bit hit;
        logic hp;
        hit = 1'b0;
        hp  = 1'b0;
        if (&da)
            return ACT_FLOOD;
        if (da[40]) begin
            if (mc_en && (da == 48'h01_00_5e_00_00_01)) begin
                if (prt == 1'b1)
                    return ACT_FILTER;
                return ACT_FWD;
            end
            return ACT_FLOOD;
        end
        for (int i = 0; i < CAM_N; i++) begin
            if (!hit && cam_live(i) && (cam_mac_w[i] == da) && (cam_vid_w[i] == vid)) begin
                hit = 1'b1;
                hp  = cam_prt_w[i];
            end
        end
        if (!hit)
            return ACT_FLOOD;
        if (hp == prt)
            return ACT_FILTER;
        return ACT_FWD;
    endfunction

    task automatic take_mac(
        input  logic [7:0]  bv,
        input  int          at,
        inout  logic [47:0] da,
        inout  logic [47:0] sa
    );
        if (at < 12) begin
            case (at)
                0:  da[47:40] = bv;
                1:  da[39:32] = bv;
                2:  da[31:24] = bv;
                3:  da[23:16] = bv;
                4:  da[15:8]  = bv;
                5:  da[7:0]   = bv;
                6:  sa[47:40] = bv;
                7:  sa[39:32] = bv;
                8:  sa[31:24] = bv;
                9:  sa[23:16] = bv;
                10: sa[15:8]  = bv;
                11: sa[7:0]   = bv;
                default: ;
            endcase
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_st         <= ST_IDLE;
            b_st         <= ST_IDLE;
            a_hold       <= 1'b0;
            b_hold       <= 1'b0;
            a_wr_bank    <= 1'b0;
            b_wr_bank    <= 1'b0;
            a_rd_bank    <= 1'b0;
            b_rd_bank    <= 1'b0;
            a_q          <= '0;
            b_q          <= '0;
            a_bubble     <= 1'b0;
            b_bubble     <= 1'b0;
            a_cap        <= 1'b0;
            b_cap        <= 1'b0;
            a_nbyte      <= '0;
            b_nbyte      <= '0;
            a_len        <= '0;
            b_len        <= '0;
            a_rd         <= '0;
            b_rd         <= '0;
            a_da         <= '0;
            a_sa         <= '0;
            b_da         <= '0;
            b_sa         <= '0;
            a_user       <= '0;
            b_user       <= '0;
            a_err        <= 1'b0;
            b_err        <= 1'b0;
            eg_b_user    <= '0;
            eg_b_err     <= 1'b0;
            eg_a_user    <= '0;
            eg_a_err     <= 1'b0;
            a_m_tdata    <= '0;
            a_m_tkeep    <= '0;
            a_m_tvalid   <= 1'b0;
            a_m_tstart   <= 1'b0;
            a_m_tlast    <= 1'b0;
            a_m_tuser    <= '0;
            a_m_tuser_err<= 1'b0;
            b_m_tdata    <= '0;
            b_m_tkeep    <= '0;
            b_m_tvalid   <= 1'b0;
            b_m_tstart   <= 1'b0;
            b_m_tlast    <= 1'b0;
            b_m_tuser    <= '0;
            b_m_tuser_err<= 1'b0;
            a_dec_valid  <= 1'b0;
            a_dec_act    <= ACT_FILTER;
            a_dec_bytes  <= '0;
            b_dec_valid  <= 1'b0;
            b_dec_act    <= ACT_FILTER;
            b_dec_bytes  <= '0;
            cam_vic      <= 0;
            cam_time     <= '0;
            cam_v        <= '{default: '0};
            cam_mac      <= '{default: '0};
            cam_vid      <= '{default: '0};
            cam_prt      <= '{default: '0};
            cam_age      <= '{default: '0};
        end else begin
            a_dec_valid <= 1'b0;
            b_dec_valid <= 1'b0;
            if (a_pause_en)
                a_bubble <= ~a_bubble;
            else
                a_bubble <= 1'b0;
            if (b_pause_en)
                b_bubble <= ~b_bubble;
            else
                b_bubble <= 1'b0;

            time_w = cam_time;
            for (int i = 0; i < CAM_N; i++) begin
                cam_v_w[i]   = cam_v[i];
                cam_mac_w[i] = cam_mac[i];
                cam_vid_w[i] = cam_vid[i];
                cam_prt_w[i] = cam_prt[i];
                cam_age_w[i] = cam_age[i];
            end
            vic_w = cam_vic;

            begin
                logic [1:0] aq;
                logic [1:0] bq;
                logic       ah;
                logic       bh;
                logic       arb;
                logic       brb;
                logic [15:0] a_slen_w [0:1];
                logic [15:0] b_slen_w [0:1];
                logic [31:0] a_suser_w [0:1];
                logic [31:0] b_suser_w [0:1];
                logic        a_serr_w [0:1];
                logic        b_serr_w [0:1];
                aq  = a_q;
                bq  = b_q;
                ah  = a_hold;
                bh  = b_hold;
                arb = a_rd_bank;
                brb = b_rd_bank;
                a_slen_w[0]  = a_slen[0];
                a_slen_w[1]  = a_slen[1];
                b_slen_w[0]  = b_slen[0];
                b_slen_w[1]  = b_slen[1];
                a_suser_w[0] = a_suser[0];
                a_suser_w[1] = a_suser[1];
                b_suser_w[0] = b_suser[0];
                b_suser_w[1] = b_suser[1];
                a_serr_w[0]  = a_serr[0];
                a_serr_w[1]  = a_serr[1];
                b_serr_w[0]  = b_serr[0];
                b_serr_w[1]  = b_serr[1];

            if (a_fire) begin
                int          a_at;
                logic [47:0] a_da_w;
                logic [47:0] a_sa_w;
                logic        a_cap_w;
                logic [31:0] a_user_w;
                logic        a_err_w;
                logic [7:0]  a_bv;
                logic [1:0]  a_act_w;
                logic [15:0] a_et_w;
                logic [15:0] a_tci_w;
                logic [11:0] a_vid_w;
                if (a_s_tstart || (a_st == ST_IDLE)) begin
                    a_at     = 0;
                    a_da_w   = '0;
                    a_sa_w   = '0;
                    a_et_w   = '0;
                    a_tci_w  = '0;
                    a_cap_w  = 1'b0;
                    a_user_w = a_s_tuser;
                    a_err_w  = a_s_tuser_err;
                end else begin
                    a_at     = int'(a_nbyte);
                    a_da_w   = a_da;
                    a_sa_w   = a_sa;
                    a_et_w   = a_et;
                    a_tci_w  = a_tci;
                    a_cap_w  = a_cap;
                    a_user_w = a_user;
                    a_err_w  = a_err;
                end
                for (int k = 0; k < KEEP_W; k++) begin
                    if (a_s_tkeep[k]) begin
                        a_bv = a_s_tdata[8*k +: 8];
                        if (!a_cap_w && (a_at < MAX_B)) begin
                            a_mem[a_wr_bank][a_at] <= a_bv;
                            take_mac(a_bv, a_at, a_da_w, a_sa_w);
                            if (a_at == 12)
                                a_et_w[15:8] = a_bv;
                            else if (a_at == 13)
                                a_et_w[7:0] = a_bv;
                            else if (a_at == 14)
                                a_tci_w[15:8] = a_bv;
                            else if (a_at == 15)
                                a_tci_w[7:0] = a_bv;
                        end else begin
                            a_cap_w = 1'b1;
                        end
                        a_at = a_at + 1;
                    end
                end
                a_nbyte <= 16'(a_at);
                a_da    <= a_da_w;
                a_sa    <= a_sa_w;
                a_et    <= a_et_w;
                a_tci   <= a_tci_w;
                a_cap   <= a_cap_w;
                a_user  <= a_user_w;
                a_err   <= a_err_w;
                if (a_s_tlast) begin
                    a_dec_valid <= 1'b1;
                    a_dec_bytes <= a_at;
                    a_st        <= ST_IDLE;
                    if ((a_at < len_min()) || (a_at > len_max()) || a_cap_w) begin
                        a_dec_act <= ACT_DROP;
                    end else begin
                        a_vid_w   = vid_of(a_et_w, a_tci_w);
                        cam_learn(a_sa_w, a_vid_w, 1'b0);
                        a_act_w   = cam_act(a_da_w, a_vid_w, 1'b0);
                        a_dec_act <= a_act_w;
                        if ((a_act_w == ACT_FWD) || (a_act_w == ACT_FLOOD)) begin
                            a_slen_w[a_wr_bank]  = 16'(a_at);
                            a_suser_w[a_wr_bank] = a_user_w;
                            a_serr_w[a_wr_bank]  = a_err_w;
                            if (aq == 0) begin
                                ah        = 1'b1;
                                a_len     <= 16'(a_at);
                                a_rd      <= '0;
                                eg_b_user <= a_user_w;
                                eg_b_err  <= a_err_w;
                            end
                            a_wr_bank <= ~a_wr_bank;
                            aq = aq + 2'd1;
                        end
                    end
                end else begin
                    a_st <= ST_RECV;
                end
            end

            if (b_fire) begin
                int          b_at;
                logic [47:0] b_da_w;
                logic [47:0] b_sa_w;
                logic        b_cap_w;
                logic [31:0] b_user_w;
                logic        b_err_w;
                logic [7:0]  b_bv;
                logic [1:0]  b_act_w;
                logic [15:0] b_et_w;
                logic [15:0] b_tci_w;
                logic [11:0] b_vid_w;
                if (b_s_tstart || (b_st == ST_IDLE)) begin
                    b_at     = 0;
                    b_da_w   = '0;
                    b_sa_w   = '0;
                    b_et_w   = '0;
                    b_tci_w  = '0;
                    b_cap_w  = 1'b0;
                    b_user_w = b_s_tuser;
                    b_err_w  = b_s_tuser_err;
                end else begin
                    b_at     = int'(b_nbyte);
                    b_da_w   = b_da;
                    b_sa_w   = b_sa;
                    b_et_w   = b_et;
                    b_tci_w  = b_tci;
                    b_cap_w  = b_cap;
                    b_user_w = b_user;
                    b_err_w  = b_err;
                end
                for (int k = 0; k < KEEP_W; k++) begin
                    if (b_s_tkeep[k]) begin
                        b_bv = b_s_tdata[8*k +: 8];
                        if (!b_cap_w && (b_at < MAX_B)) begin
                            b_mem[b_wr_bank][b_at] <= b_bv;
                            take_mac(b_bv, b_at, b_da_w, b_sa_w);
                            if (b_at == 12)
                                b_et_w[15:8] = b_bv;
                            else if (b_at == 13)
                                b_et_w[7:0] = b_bv;
                            else if (b_at == 14)
                                b_tci_w[15:8] = b_bv;
                            else if (b_at == 15)
                                b_tci_w[7:0] = b_bv;
                        end else begin
                            b_cap_w = 1'b1;
                        end
                        b_at = b_at + 1;
                    end
                end
                b_nbyte <= 16'(b_at);
                b_da    <= b_da_w;
                b_sa    <= b_sa_w;
                b_et    <= b_et_w;
                b_tci   <= b_tci_w;
                b_cap   <= b_cap_w;
                b_user  <= b_user_w;
                b_err   <= b_err_w;
                if (b_s_tlast) begin
                    b_dec_valid <= 1'b1;
                    b_dec_bytes <= b_at;
                    b_st        <= ST_IDLE;
                    if ((b_at < len_min()) || (b_at > len_max()) || b_cap_w) begin
                        b_dec_act <= ACT_DROP;
                    end else begin
                        b_vid_w   = vid_of(b_et_w, b_tci_w);
                        cam_learn(b_sa_w, b_vid_w, 1'b1);
                        b_act_w   = cam_act(b_da_w, b_vid_w, 1'b1);
                        b_dec_act <= b_act_w;
                        if ((b_act_w == ACT_FWD) || (b_act_w == ACT_FLOOD)) begin
                            b_slen_w[b_wr_bank]  = 16'(b_at);
                            b_suser_w[b_wr_bank] = b_user_w;
                            b_serr_w[b_wr_bank]  = b_err_w;
                            if (bq == 0) begin
                                bh        = 1'b1;
                                b_len     <= 16'(b_at);
                                b_rd      <= '0;
                                eg_a_user <= b_user_w;
                                eg_a_err  <= b_err_w;
                            end
                            b_wr_bank <= ~b_wr_bank;
                            bq = bq + 2'd1;
                        end
                    end
                end else begin
                    b_st <= ST_RECV;
                end
            end

            // Port B master drains port A's buffer. Port A master drains B.
            if (b_m_tvalid && !b_m_tready) begin
            end else begin
                int          rd_i;
                int          n_i;
                logic [DATA_W-1:0] td;
                logic [KEEP_W-1:0] tk;
                b_m_tvalid <= 1'b0;
                if (a_hold && (a_rd < a_len)) begin
                    rd_i = int'(a_rd);
                    n_i  = 0;
                    td   = '0;
                    tk   = '0;
                    for (int k = 0; k < KEEP_W; k++) begin
                        if ((rd_i + n_i) < int'(a_len)) begin
                            td[8*k +: 8] = a_mem[a_rd_bank][rd_i + n_i];
                            tk[k]        = 1'b1;
                            n_i          = n_i + 1;
                        end
                    end
                    b_m_tdata     <= td;
                    b_m_tkeep     <= tk;
                    b_m_tvalid    <= 1'b1;
                    b_m_tstart    <= (rd_i == 0);
                    b_m_tlast     <= ((rd_i + n_i) >= int'(a_len));
                    b_m_tuser     <= eg_b_user;
                    b_m_tuser_err <= eg_b_err;
                    if ((rd_i + n_i) >= int'(a_len)) begin
                        arb = ~a_rd_bank;
                        aq  = aq - 2'd1;
                        if (aq == 0) begin
                            ah = 1'b0;
                        end else begin
                            ah        = 1'b1;
                            a_len     <= a_slen_w[arb];
                            a_rd      <= '0;
                            eg_b_user <= a_suser_w[arb];
                            eg_b_err  <= a_serr_w[arb];
                        end
                    end else begin
                        a_rd <= 16'(rd_i + n_i);
                    end
                end
            end

            if (a_m_tvalid && !a_m_tready) begin
            end else begin
                int          rd_i;
                int          n_i;
                logic [DATA_W-1:0] td;
                logic [KEEP_W-1:0] tk;
                a_m_tvalid <= 1'b0;
                if (b_hold && (b_rd < b_len)) begin
                    rd_i = int'(b_rd);
                    n_i  = 0;
                    td   = '0;
                    tk   = '0;
                    for (int k = 0; k < KEEP_W; k++) begin
                        if ((rd_i + n_i) < int'(b_len)) begin
                            td[8*k +: 8] = b_mem[b_rd_bank][rd_i + n_i];
                            tk[k]        = 1'b1;
                            n_i          = n_i + 1;
                        end
                    end
                    a_m_tdata     <= td;
                    a_m_tkeep     <= tk;
                    a_m_tvalid    <= 1'b1;
                    a_m_tstart    <= (rd_i == 0);
                    a_m_tlast     <= ((rd_i + n_i) >= int'(b_len));
                    a_m_tuser     <= eg_a_user;
                    a_m_tuser_err <= eg_a_err;
                    if ((rd_i + n_i) >= int'(b_len)) begin
                        brb = ~b_rd_bank;
                        bq  = bq - 2'd1;
                        if (bq == 0) begin
                            bh = 1'b0;
                        end else begin
                            bh        = 1'b1;
                            b_len     <= b_slen_w[brb];
                            b_rd      <= '0;
                            eg_a_user <= b_suser_w[brb];
                            eg_a_err  <= b_serr_w[brb];
                        end
                    end else begin
                        b_rd <= 16'(rd_i + n_i);
                    end
                end
            end

            a_q       <= aq;
            b_q       <= bq;
            a_hold    <= ah;
            b_hold    <= bh;
            a_rd_bank <= arb;
            b_rd_bank <= brb;
            a_slen[0] <= a_slen_w[0];
            a_slen[1] <= a_slen_w[1];
            b_slen[0] <= b_slen_w[0];
            b_slen[1] <= b_slen_w[1];
            a_suser[0] <= a_suser_w[0];
            a_suser[1] <= a_suser_w[1];
            b_suser[0] <= b_suser_w[0];
            b_suser[1] <= b_suser_w[1];
            a_serr[0] <= a_serr_w[0];
            a_serr[1] <= a_serr_w[1];
            b_serr[0] <= b_serr_w[0];
            b_serr[1] <= b_serr_w[1];
            end

            cam_v    <= cam_v_w;
            cam_mac  <= cam_mac_w;
            cam_vid  <= cam_vid_w;
            cam_prt  <= cam_prt_w;
            cam_age  <= cam_age_w;
            cam_time <= time_w + 32'd1;
            cam_vic  <= vic_w;
        end
    end

endmodule
