// Observer beside an AXI-Stream port. Samples tvalid && tready on the
// wires it is tied to. It does not sit behind the bridge buffer.
// Fingerprint matches dpi/pcap_reader.c: fp = rol1(fp) ^ byte.

`timescale 1ns/1ps

module pkt_l2_obs #(
    parameter int DATA_W = 8
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic [DATA_W-1:0]   tdata,
    input  logic [DATA_W/8-1:0] tkeep,
    input  logic                tvalid,
    input  logic                tready,
    input  logic                tstart,
    input  logic                tlast,

    output logic                obs_valid,
    output logic [31:0]         obs_bytes,
    output logic [47:0]         obs_da,
    output logic [47:0]         obs_sa,
    output logic [31:0]         obs_sum
);

    localparam int KEEP_W = DATA_W / 8;

    logic [15:0] byte_idx;
    logic [47:0] da_r;
    logic [47:0] sa_r;
    logic [31:0] sum_r;

    logic [15:0] idx_w;
    logic [47:0] da_w;
    logic [47:0] sa_w;
    logic [31:0] sum_w;
    logic [7:0]  b_w;
    int          at;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_idx  <= '0;
            da_r      <= '0;
            sa_r      <= '0;
            sum_r     <= '0;
            obs_valid <= 1'b0;
            obs_bytes <= '0;
            obs_da    <= '0;
            obs_sa    <= '0;
            obs_sum   <= '0;
        end else begin
            obs_valid <= 1'b0;
            if (tvalid && tready) begin
                if (tstart) begin
                    idx_w = '0;
                    da_w  = '0;
                    sa_w  = '0;
                    sum_w = '0;
                end else begin
                    idx_w = byte_idx;
                    da_w  = da_r;
                    sa_w  = sa_r;
                    sum_w = sum_r;
                end
                for (int k = 0; k < KEEP_W; k++) begin
                    if (tkeep[k]) begin
                        b_w = tdata[8*k +: 8];
                        at  = int'(idx_w);
                        if (at < 12) begin
                            case (at)
                                0:  da_w[47:40] = b_w;
                                1:  da_w[39:32] = b_w;
                                2:  da_w[31:24] = b_w;
                                3:  da_w[23:16] = b_w;
                                4:  da_w[15:8]  = b_w;
                                5:  da_w[7:0]   = b_w;
                                6:  sa_w[47:40] = b_w;
                                7:  sa_w[39:32] = b_w;
                                8:  sa_w[31:24] = b_w;
                                9:  sa_w[23:16] = b_w;
                                10: sa_w[15:8]  = b_w;
                                11: sa_w[7:0]   = b_w;
                                default: ;
                            endcase
                        end
                        sum_w = {sum_w[30:0], sum_w[31]} ^ {24'd0, b_w};
                        idx_w = idx_w + 16'd1;
                    end
                end
                byte_idx <= idx_w;
                da_r     <= da_w;
                sa_r     <= sa_w;
                sum_r    <= sum_w;
                if (tlast) begin
                    obs_valid <= 1'b1;
                    obs_bytes <= {16'd0, idx_w};
                    obs_da    <= da_w;
                    obs_sa    <= sa_w;
                    obs_sum   <= sum_w;
                end
            end
        end
    end

endmodule
