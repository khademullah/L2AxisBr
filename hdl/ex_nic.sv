// Example NIC for the two-link bench. One instance sits on each bridge port.
// The host pushes a frame in on h_*. The NIC stores it, then drives m_* into
// that port's bridge slave. Frames the bridge sends back arrive on s_* and
// raise rx_pkt_valid. s_* matches nic_rx. A beat is tvalid && tready.
// h_tready falls while m_* is still sending, so the host waits until this
// frame has entered the bridge.

`timescale 1ns/1ps

module ex_nic #(
    parameter int DATA_W = 8,
    parameter int MAX_B  = 9200,
    parameter int DEPTH  = 16
) (
    input  logic                clk,
    input  logic                rst_n,

    input  logic [DATA_W-1:0]   h_tdata,
    input  logic [DATA_W/8-1:0] h_tkeep,
    input  logic                h_tvalid,
    output logic                h_tready,
    input  logic                h_tstart,
    input  logic                h_tlast,
    input  logic [31:0]         h_tuser,
    input  logic                h_tuser_err,

    output logic [DATA_W-1:0]   m_tdata,
    output logic [DATA_W/8-1:0] m_tkeep,
    output logic                m_tvalid,
    input  logic                m_tready,
    output logic                m_tstart,
    output logic                m_tlast,
    output logic [31:0]         m_tuser,
    output logic                m_tuser_err,

    input  logic [DATA_W-1:0]   s_tdata,
    input  logic [DATA_W/8-1:0] s_tkeep,
    input  logic                s_tvalid,
    output logic                s_tready,
    input  logic                s_tstart,
    input  logic                s_tlast,
    input  logic [31:0]         s_tuser,
    input  logic                s_tuser_err,
    input  logic                ready_mask,
    input  logic                pause_en,

    output logic                tx_pkt_valid,
    output logic [31:0]         tx_bytes,
    output logic                rx_pkt_valid,
    output logic [31:0]         rx_bytes,
    output logic [31:0]         rx_hash,
    output logic                rx_err,
    output logic                rx_drop,
    output logic [15:0]         rx_occ
);

    localparam int KEEP_W  = DATA_W / 8;
    localparam int CW      = $clog2(DEPTH + 1);

    logic [7:0]    mem [0:MAX_B-1];
    logic          state; // 0 = idle, 1 = sending m_*
    int            wr_len;
    int            tx_len;
    int            tx_i;
    logic [31:0]   tx_user;
    logic          tx_err;

    logic [CW-1:0] count;
    logic [CW-1:0] count_n;
    logic          wr;
    logic          rd;
    logic          almost_full;
    logic          bubble;
    logic [31:0]   acc;
    logic [31:0]   beat_bytes;
    logic          in_pkt;

    assign h_tready = rst_n && (state == 1'b0);

    always_comb begin
        m_tdata      = '0;
        m_tkeep      = '0;
        m_tvalid     = (state == 1'b1);
        m_tstart     = (tx_i == 0);
        m_tlast      = (tx_len != 0) && ((tx_i + KEEP_W) >= tx_len);
        m_tuser      = tx_user;
        m_tuser_err  = tx_err;
        for (int k = 0; k < KEEP_W; k++) begin
            if ((tx_i + k) < tx_len) begin
                m_tdata[8*k +: 8] = mem[tx_i + k];
                m_tkeep[k]        = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= 1'b0;
            wr_len       <= 0;
            tx_len       <= 0;
            tx_i         <= 0;
            tx_user      <= '0;
            tx_err       <= 1'b0;
            tx_pkt_valid <= 1'b0;
            tx_bytes     <= '0;
        end else begin
            tx_pkt_valid <= 1'b0;
            if ((state == 1'b0) && h_tvalid && h_tready) begin
                int idx;
                int nadd;
                idx  = h_tstart ? 0 : wr_len;
                nadd = 0;
                for (int k = 0; k < KEEP_W; k++) begin
                    if (h_tkeep[k] && ((idx + nadd) < MAX_B)) begin
                        mem[idx + nadd] = h_tdata[8*k +: 8];
                        nadd = nadd + 1;
                    end
                end
                wr_len <= idx + nadd;
                if (h_tstart) begin
                    tx_user <= h_tuser;
                    tx_err  <= h_tuser_err;
                end
                if (h_tlast) begin
                    state  <= 1'b1;
                    tx_len <= idx + nadd;
                    tx_i   <= 0;
                end
            end else if ((state == 1'b1) && m_tready) begin
                if ((tx_i + KEEP_W) >= tx_len) begin
                    state        <= 1'b0;
                    wr_len       <= 0;
                    tx_i         <= 0;
                    tx_pkt_valid <= 1'b1;
                    tx_bytes     <= 32'(tx_len);
                end else begin
                    tx_i <= tx_i + KEEP_W;
                end
            end
        end
    end

    always_comb begin
        beat_bytes = 32'd0;
        for (int i = 0; i < KEEP_W; i++)
            beat_bytes = beat_bytes + {31'd0, s_tkeep[i]};
    end

    assign wr          = s_tvalid && s_tready;
    assign rd          = (count != '0);
    assign almost_full = (count >= CW'(DEPTH - 2));
    assign s_tready    = rst_n && ready_mask && !bubble && !almost_full;

    always_comb begin
        unique case ({wr, rd})
            2'b10:   count_n = count + 1'b1;
            2'b01:   count_n = count - 1'b1;
            default: count_n = count;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count        <= '0;
            bubble       <= 1'b0;
            acc          <= 32'd0;
            in_pkt       <= 1'b0;
            rx_pkt_valid <= 1'b0;
            rx_bytes     <= 32'd0;
            rx_hash      <= 32'd0;
            rx_err       <= 1'b0;
            rx_drop      <= 1'b0;
            rx_occ       <= 16'd0;
        end else begin
            count        <= count_n;
            rx_occ       <= 16'(count_n);
            rx_pkt_valid <= 1'b0;
            rx_drop      <= 1'b0;
            if (pause_en)
                bubble <= ~bubble;
            else
                bubble <= 1'b0;

            if (wr && (count >= CW'(DEPTH)))
                rx_drop <= 1'b1;

            if (wr) begin
                if (s_tstart) begin
                    in_pkt  <= 1'b1;
                    acc     <= beat_bytes;
                    rx_hash <= s_tuser;
                    rx_err  <= s_tuser_err;
                end else if (in_pkt) begin
                    acc <= acc + beat_bytes;
                end

                if (s_tlast) begin
                    rx_pkt_valid <= 1'b1;
                    rx_bytes     <= (s_tstart ? beat_bytes : (acc + beat_bytes));
                    acc          <= 32'd0;
                    in_pkt       <= 1'b0;
                end
            end
        end
    end

endmodule
