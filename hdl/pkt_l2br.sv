// Two-port MAC-learning Ethernet bridge.
// Port A and port B ingress pins match nic_rx's s_* list (plus ready_mask
// and pause_en). Egress is an AXI-Stream master on each port: a frame
// accepted on A leaves on B, and the other way around.
//
// Beat = s_tvalid && s_tready. s_tready is low while this port's buffer is
// committed to the other master, and while ready_mask or pause_en says so.
// Learn unicast SA, then look up DA. Broadcast and I/G multicast flood the
// other port. DA on this port is filtered. DA on the other port is forwarded.
// A miss floods. Under 12 bytes or over MAX_B is a drop (no learn).
// The C twin is dpi/l2_model.c (CAM_N = 1024, MAX_B = 2048).

`timescale 1ns/1ps

module pkt_l2br #(
    parameter int DATA_W = 8,
    parameter int CAM_N  = 1024,
    parameter int MAX_B  = 2048
) (
    input  logic                clk,
    input  logic                rst_n,

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
    logic [31:0]       a_user;
    logic [31:0]       b_user;
    logic              a_err;
    logic              b_err;
    logic [31:0]       eg_b_user;
    logic              eg_b_err;
    logic [31:0]       eg_a_user;
    logic              eg_a_err;
    logic [7:0]        a_mem [0:MAX_B-1];
    logic [7:0]        b_mem [0:MAX_B-1];

    logic              cam_v   [0:CAM_N-1];
    logic [47:0]       cam_mac [0:CAM_N-1];
    logic              cam_prt [0:CAM_N-1];
    int                cam_vic;

    logic              cam_v_w   [0:CAM_N-1];
    logic [47:0]       cam_mac_w [0:CAM_N-1];
    logic              cam_prt_w [0:CAM_N-1];
    int                vic_w;

    wire a_fire = a_s_tvalid && a_s_tready;
    wire b_fire = b_s_tvalid && b_s_tready;

    assign a_s_tready = rst_n && a_ready_mask && !a_bubble && !a_hold;
    assign b_s_tready = rst_n && b_ready_mask && !b_bubble && !b_hold;
    assign a_busy = (a_st == ST_RECV) || a_hold || b_m_tvalid;
    assign b_busy = (b_st == ST_RECV) || b_hold || a_m_tvalid;

    task automatic cam_learn(input logic [47:0] sa, input logic prt);
        bit found;
        if (sa[40])
            return;
        found = 1'b0;
        for (int i = 0; i < CAM_N; i++) begin
            if (!found && cam_v_w[i] && (cam_mac_w[i] == sa)) begin
                cam_prt_w[i] = prt;
                found = 1'b1;
            end
        end
        if (found)
            return;
        for (int i = 0; i < CAM_N; i++) begin
            if (!found && !cam_v_w[i]) begin
                cam_v_w[i]   = 1'b1;
                cam_mac_w[i] = sa;
                cam_prt_w[i] = prt;
                found = 1'b1;
            end
        end
        if (!found) begin
            cam_v_w[vic_w]   = 1'b1;
            cam_mac_w[vic_w] = sa;
            cam_prt_w[vic_w] = prt;
            vic_w = (vic_w + 1) % CAM_N;
        end
    endtask

    function automatic logic [1:0] cam_act(input logic [47:0] da, input logic prt);
        bit hit;
        logic hp;
        hit = 1'b0;
        hp  = 1'b0;
        if ((&da) || da[40])
            return ACT_FLOOD;
        for (int i = 0; i < CAM_N; i++) begin
            if (!hit && cam_v_w[i] && (cam_mac_w[i] == da)) begin
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
            for (int i = 0; i < CAM_N; i++) begin
                cam_v[i]   <= 1'b0;
                cam_mac[i] <= '0;
                cam_prt[i] <= 1'b0;
            end
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

            for (int i = 0; i < CAM_N; i++) begin
                cam_v_w[i]   = cam_v[i];
                cam_mac_w[i] = cam_mac[i];
                cam_prt_w[i] = cam_prt[i];
            end
            vic_w = cam_vic;

            if (a_fire) begin
                int          a_at;
                logic [47:0] a_da_w;
                logic [47:0] a_sa_w;
                logic        a_cap_w;
                logic [31:0] a_user_w;
                logic        a_err_w;
                logic [7:0]  a_bv;
                logic [1:0]  a_act_w;
                if (a_s_tstart || (a_st == ST_IDLE)) begin
                    a_at     = 0;
                    a_da_w   = '0;
                    a_sa_w   = '0;
                    a_cap_w  = 1'b0;
                    a_user_w = a_s_tuser;
                    a_err_w  = a_s_tuser_err;
                end else begin
                    a_at     = int'(a_nbyte);
                    a_da_w   = a_da;
                    a_sa_w   = a_sa;
                    a_cap_w  = a_cap;
                    a_user_w = a_user;
                    a_err_w  = a_err;
                end
                for (int k = 0; k < KEEP_W; k++) begin
                    if (a_s_tkeep[k]) begin
                        a_bv = a_s_tdata[8*k +: 8];
                        if (!a_cap_w && (a_at < MAX_B)) begin
                            a_mem[a_at] <= a_bv;
                            take_mac(a_bv, a_at, a_da_w, a_sa_w);
                        end else begin
                            a_cap_w = 1'b1;
                        end
                        a_at = a_at + 1;
                    end
                end
                a_nbyte <= 16'(a_at);
                a_da    <= a_da_w;
                a_sa    <= a_sa_w;
                a_cap   <= a_cap_w;
                a_user  <= a_user_w;
                a_err   <= a_err_w;
                if (a_s_tlast) begin
                    a_dec_valid <= 1'b1;
                    a_dec_bytes <= a_at;
                    a_st        <= ST_IDLE;
                    if ((a_at < 12) || (a_at > MAX_B) || a_cap_w) begin
                        a_dec_act <= ACT_DROP;
                    end else begin
                        cam_learn(a_sa_w, 1'b0);
                        a_act_w   = cam_act(a_da_w, 1'b0);
                        a_dec_act <= a_act_w;
                        if ((a_act_w == ACT_FWD) || (a_act_w == ACT_FLOOD)) begin
                            a_hold    <= 1'b1;
                            a_len     <= 16'(a_at);
                            a_rd      <= '0;
                            eg_b_user <= a_user_w;
                            eg_b_err  <= a_err_w;
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
                if (b_s_tstart || (b_st == ST_IDLE)) begin
                    b_at     = 0;
                    b_da_w   = '0;
                    b_sa_w   = '0;
                    b_cap_w  = 1'b0;
                    b_user_w = b_s_tuser;
                    b_err_w  = b_s_tuser_err;
                end else begin
                    b_at     = int'(b_nbyte);
                    b_da_w   = b_da;
                    b_sa_w   = b_sa;
                    b_cap_w  = b_cap;
                    b_user_w = b_user;
                    b_err_w  = b_err;
                end
                for (int k = 0; k < KEEP_W; k++) begin
                    if (b_s_tkeep[k]) begin
                        b_bv = b_s_tdata[8*k +: 8];
                        if (!b_cap_w && (b_at < MAX_B)) begin
                            b_mem[b_at] <= b_bv;
                            take_mac(b_bv, b_at, b_da_w, b_sa_w);
                        end else begin
                            b_cap_w = 1'b1;
                        end
                        b_at = b_at + 1;
                    end
                end
                b_nbyte <= 16'(b_at);
                b_da    <= b_da_w;
                b_sa    <= b_sa_w;
                b_cap   <= b_cap_w;
                b_user  <= b_user_w;
                b_err   <= b_err_w;
                if (b_s_tlast) begin
                    b_dec_valid <= 1'b1;
                    b_dec_bytes <= b_at;
                    b_st        <= ST_IDLE;
                    if ((b_at < 12) || (b_at > MAX_B) || b_cap_w) begin
                        b_dec_act <= ACT_DROP;
                    end else begin
                        cam_learn(b_sa_w, 1'b1);
                        b_act_w   = cam_act(b_da_w, 1'b1);
                        b_dec_act <= b_act_w;
                        if ((b_act_w == ACT_FWD) || (b_act_w == ACT_FLOOD)) begin
                            b_hold    <= 1'b1;
                            b_len     <= 16'(b_at);
                            b_rd      <= '0;
                            eg_a_user <= b_user_w;
                            eg_a_err  <= b_err_w;
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
                            td[8*k +: 8] = a_mem[rd_i + n_i];
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
                    a_rd          <= 16'(rd_i + n_i);
                    if ((rd_i + n_i) >= int'(a_len))
                        a_hold <= 1'b0;
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
                            td[8*k +: 8] = b_mem[rd_i + n_i];
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
                    b_rd          <= 16'(rd_i + n_i);
                    if ((rd_i + n_i) >= int'(b_len))
                        b_hold <= 1'b0;
                end
            end

            for (int i = 0; i < CAM_N; i++) begin
                cam_v[i]   <= cam_v_w[i];
                cam_mac[i] <= cam_mac_w[i];
                cam_prt[i] <= cam_prt_w[i];
            end
            cam_vic <= vic_w;
        end
    end

endmodule
