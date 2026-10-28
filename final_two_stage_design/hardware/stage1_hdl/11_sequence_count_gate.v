/*
 * sequence_count_gate
 * -------------------
 *
 * Implements the MATLAB hard-rule sequence gate:
 *
 *   abnormal_vote_count = sum(last SEQUENCE_LENGTH window decisions)
 *   sequence_abnormal   = abnormal_vote_count >= COUNT_THRESHOLD
 *
 * For the current evaluator:
 *
 *   SEQUENCE_LENGTH = 3
 *
 * COUNT_THRESHOLD is intentionally a parameter because the MATLAB evaluator
 * checks thresholds 1, 2, and 3. The selected thesis operating point is
 * COUNT_THRESHOLD = 2 for a 2-out-of-3 decision.
 */

module sequence_count_gate #(
    parameter integer SEQUENCE_LENGTH = 3,
    parameter integer COUNT_THRESHOLD = 2,
    parameter integer COUNT_WIDTH = $clog2(SEQUENCE_LENGTH + 1)
) (
    input  wire                   clk,
    input  wire                   resetn,

    input  wire                   window_vote,
    input  wire                   window_vote_valid,

    output reg  [COUNT_WIDTH-1:0] abnormal_vote_count,
    output reg                    sequence_abnormal,
    output reg                    sequence_valid,
    output reg  [31:0]            sequence_count
);

    localparam [COUNT_WIDTH-1:0] SEQUENCE_LENGTH_COUNT = SEQUENCE_LENGTH;
    localparam [COUNT_WIDTH-1:0] COUNT_THRESHOLD_COUNT = COUNT_THRESHOLD;

    reg [SEQUENCE_LENGTH-1:0] vote_shift;
    reg [COUNT_WIDTH-1:0] valid_windows;

    function [COUNT_WIDTH-1:0] count_votes;
        input [SEQUENCE_LENGTH-1:0] votes;
        integer i;
        begin
            count_votes = {COUNT_WIDTH{1'b0}};
            for (i = 0; i < SEQUENCE_LENGTH; i = i + 1) begin
                count_votes = count_votes + votes[i];
            end
        end
    endfunction

    wire [SEQUENCE_LENGTH-1:0] next_vote_shift =
        {vote_shift[SEQUENCE_LENGTH-2:0], window_vote};
    wire [COUNT_WIDTH-1:0] next_vote_count = count_votes(next_vote_shift);
    wire sequence_ready = (valid_windows >= (SEQUENCE_LENGTH - 1));

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            vote_shift <= {SEQUENCE_LENGTH{1'b0}};
            valid_windows <= {COUNT_WIDTH{1'b0}};
            abnormal_vote_count <= {COUNT_WIDTH{1'b0}};
            sequence_abnormal <= 1'b0;
            sequence_valid <= 1'b0;
            sequence_count <= 32'd0;
        end else begin
            sequence_valid <= 1'b0;

            if (window_vote_valid) begin
                vote_shift <= next_vote_shift;
                abnormal_vote_count <= next_vote_count;

                if (valid_windows < SEQUENCE_LENGTH_COUNT) begin
                    valid_windows <= valid_windows + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                end

                if (sequence_ready) begin
                    sequence_abnormal <= (next_vote_count >= COUNT_THRESHOLD_COUNT);
                    sequence_valid <= 1'b1;
                    sequence_count <= sequence_count + 32'd1;
                end
            end
        end
    end

endmodule
