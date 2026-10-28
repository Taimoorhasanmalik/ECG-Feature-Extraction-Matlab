// One bank owns a 240-sample window. Its stored samples are replayed once
// after completion while the bank starts accepting its next window.
module stage2_feature_bank_q #(
    parameter integer N = 240
) (
    input wire clk, resetn,
    input wire signed [13:0] sample_q8,
    input wire sample_valid, bank_enable, window_start, window_end,
    output reg features_valid,
    output reg signed [11:0] mean_abs_q3_8,
    output reg signed [16:0] line_length_q8_8,
    output reg signed [8:0] derivative_zc,
    output reg signed [8:0] threshold_crossings,
    output reg signed [11:0] local_amp_mean_q3_8,
    output reg signed [11:0] local_amp_range_q3_8,
    output reg signed [11:0] amp_transition_q3_8,
    output reg overflow
);
    reg signed [13:0] memory [0:N-1];
    reg [7:0] write_index, replay_index;
    reg replay_active;
    reg signed [31:0] sum_acc, frozen_sum;
    reg signed [13:0] min_acc, max_acc, frozen_min, frozen_max;
    reg [31:0] diff_abs_acc, frozen_diff_abs;
    reg signed [13:0] prev_input;
    reg [31:0] line_acc, frozen_line;
    reg [31:0] abs_acc, block_acc, block_min, block_max, transition_acc;
    reg [8:0] zc_acc, crossing_acc;
    reg prev_deriv_sign, deriv_seen, prev_above, above_seen;
    reg [31:0] prev_block;
    reg [3:0] completed_blocks;
    reg signed [13:0] prev_replay;

    wire signed [31:0] sum_next = window_start ? $signed(sample_q8) :
        sum_acc + $signed(sample_q8);
    wire signed [13:0] min_next = window_start || sample_q8 < min_acc ? sample_q8 : min_acc;
    wire signed [13:0] max_next = window_start || sample_q8 > max_acc ? sample_q8 : max_acc;
    wire signed [14:0] input_diff = $signed(sample_q8) - $signed(prev_input);
    wire [14:0] input_diff_abs = input_diff < 0 ? -input_diff : input_diff;
    wire [31:0] diff_abs_next = window_start ? 0 : diff_abs_acc + input_diff_abs;
    wire [31:0] line_next = window_start ? 0 : line_acc + input_diff_abs;

    wire signed [13:0] replay_sample = memory[replay_index];
    // centered_num / 240 is the exact centered sample in Q8 units.
    wire signed [31:0] centered_num = $signed(replay_sample) * 32'sd240 - frozen_sum;
    wire [31:0] abs_centered = centered_num < 0 ? -centered_num : centered_num;
    wire signed [31:0] min_centered = $signed(frozen_min) * 32'sd240 - frozen_sum;
    wire signed [31:0] max_centered = $signed(frozen_max) * 32'sd240 - frozen_sum;
    wire [31:0] min_magnitude = min_centered < 0 ? -min_centered : min_centered;
    wire [31:0] max_magnitude = max_centered < 0 ? -max_centered : max_centered;
    wire [31:0] peak = min_magnitude > max_magnitude ? min_magnitude : max_magnitude;
    wire above = peak != 0 && (32'd5 * abs_centered >= peak);
    wire signed [14:0] replay_diff = $signed(replay_sample) - $signed(prev_replay);
    wire [14:0] replay_diff_abs = replay_diff < 0 ? -replay_diff : replay_diff;
    // |diff| > 0.05 * mean(|diff|), with 239 differences per window.
    wire keep_deriv = replay_index != 0 &&
        (32'd4780 * replay_diff_abs > frozen_diff_abs);
    wire [31:0] block_next = block_acc + abs_centered;
    wire block_last = replay_index % 30 == 29;
    wire [31:0] block_min_next = completed_blocks == 0 || block_next < block_min ? block_next : block_min;
    wire [31:0] block_max_next = completed_blocks == 0 || block_next > block_max ? block_next : block_max;
    wire [31:0] transition_next = completed_blocks == 0 ? transition_acc :
        transition_acc + (block_next >= prev_block ? block_next-prev_block : prev_block-block_next);
    wire [31:0] total_abs_next = abs_acc + abs_centered;
    wire [8:0] crossing_next = crossing_acc +
        ((above_seen && above != prev_above) ? 9'd1 : 9'd0);
    wire [8:0] zc_next = zc_acc +
        ((keep_deriv && deriv_seen && (replay_diff < 0) != prev_deriv_sign) ? 9'd1 : 9'd0);
    wire [31:0] mean_units = total_abs_next / 32'd57600;
    wire [31:0] range_units = (block_max_next - block_min_next) / 32'd7200;
    wire [31:0] transition_units = transition_next / 32'd50400;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            write_index <= 0; replay_index <= 0; replay_active <= 0;
            sum_acc <= 0; frozen_sum <= 0; min_acc <= 0; max_acc <= 0;
            frozen_min <= 0; frozen_max <= 0;
            diff_abs_acc <= 0; frozen_diff_abs <= 0; prev_input <= 0;
            line_acc <= 0; frozen_line <= 0; abs_acc <= 0; block_acc <= 0;
            block_min <= 0; block_max <= 0; transition_acc <= 0;
            zc_acc <= 0; crossing_acc <= 0; prev_deriv_sign <= 0;
            deriv_seen <= 0; prev_above <= 0; above_seen <= 0;
            prev_block <= 0; completed_blocks <= 0; prev_replay <= 0;
            mean_abs_q3_8 <= 0; line_length_q8_8 <= 0;
            derivative_zc <= 0; threshold_crossings <= 0;
            local_amp_mean_q3_8 <= 0; local_amp_range_q3_8 <= 0;
            amp_transition_q3_8 <= 0; features_valid <= 0; overflow <= 0;
        end else begin
            features_valid <= 0;
            if (sample_valid && bank_enable) begin
                memory[write_index] <= sample_q8;
                sum_acc <= sum_next; min_acc <= min_next; max_acc <= max_next;
                diff_abs_acc <= diff_abs_next; line_acc <= line_next;
                prev_input <= sample_q8;
                if (window_start) write_index <= 8'd1;
                else if (window_end) write_index <= 0;
                else write_index <= write_index + 1'b1;
                if (window_end) begin
                    if (replay_active) overflow <= 1;
                    frozen_sum <= sum_next;
                    frozen_min <= min_next; frozen_max <= max_next;
                    frozen_diff_abs <= diff_abs_next;
                    frozen_line <= line_next;
                    replay_index <= 0; replay_active <= 1;
                    abs_acc <= 0; block_acc <= 0; block_min <= 0;
                    block_max <= 0; transition_acc <= 0;
                    zc_acc <= 0; crossing_acc <= 0;
                    deriv_seen <= 0; above_seen <= 0;
                    prev_block <= 0; completed_blocks <= 0;
                end
            end
            if (replay_active) begin
                abs_acc <= total_abs_next;
                crossing_acc <= crossing_next;
                zc_acc <= zc_next;
                prev_above <= above; above_seen <= 1;
                if (keep_deriv) begin
                    prev_deriv_sign <= replay_diff < 0;
                    deriv_seen <= 1;
                end
                prev_replay <= replay_sample;
                if (block_last) begin
                    block_acc <= 0;
                    block_min <= block_min_next; block_max <= block_max_next;
                    transition_acc <= transition_next;
                    prev_block <= block_next;
                    completed_blocks <= completed_blocks + 1'b1;
                end else block_acc <= block_next;
                if (replay_index == N-1) begin
                    replay_active <= 0; replay_index <= 0;
                    features_valid <= 1;
                    mean_abs_q3_8 <= mean_units > 32'd2047 ? 12'sd2047 : mean_units[11:0];
                    local_amp_mean_q3_8 <= mean_units > 32'd2047 ? 12'sd2047 : mean_units[11:0];
                    line_length_q8_8 <= frozen_line > 32'd65535 ? 17'sd65535 : frozen_line[16:0];
                    derivative_zc <= zc_next;
                    threshold_crossings <= crossing_next;
                    local_amp_range_q3_8 <= range_units > 32'd2047 ? 12'sd2047 : range_units[11:0];
                    amp_transition_q3_8 <= transition_units > 32'd2047 ? 12'sd2047 : transition_units[11:0];
                end else replay_index <= replay_index + 1'b1;
            end
        end
    end
endmodule

module stage2_features_q (
    input wire clk, resetn, sample_valid,
    input wire signed [13:0] sample_q8,
    output wire features_valid,
    output reg [31:0] window_id,
    output wire signed [11:0] mean_abs_q3_8, local_amp_mean_q3_8,
    output wire signed [16:0] line_length_q8_8,
    output wire signed [8:0] derivative_zc, threshold_crossings,
    output wire signed [11:0] local_amp_range_q3_8, amp_transition_q3_8,
    output wire overflow
);
    wire signed [13:0] seq_sample;
    wire seq_valid;
    wire [1:0] start, finish, enable, active;
    wire seq_overflow;
    wire [31:0] sample_index, window_count;
    feature_set #(.SAMPLE_WIDTH(14), .WINDOW_SAMPLES(240), .STEP_SAMPLES(120)) seq (
        .clk(clk), .resetn(resetn), .restart(1'b0),
        .sample_in(sample_q8), .sample_valid(sample_valid),
        .sample_out(seq_sample), .sample_out_valid(seq_valid),
        .sample_index(sample_index), .window_count(window_count),
        .window_start(start), .window_end(finish),
        .feature_bank_enable(enable), .window_active(active),
        .window_overflow(seq_overflow)
    );
    wire [1:0] valid, bank_overflow;
    wire signed [11:0] f0 [0:1], f4 [0:1], f5 [0:1], f6 [0:1];
    wire signed [16:0] f1 [0:1];
    wire signed [8:0] f2 [0:1], f3 [0:1];
    genvar b;
    generate for (b=0; b<2; b=b+1) begin: banks
        stage2_feature_bank_q bank (
            .clk(clk), .resetn(resetn), .sample_q8(seq_sample),
            .sample_valid(seq_valid), .bank_enable(enable[b]),
            .window_start(start[b]), .window_end(finish[b]),
            .features_valid(valid[b]), .mean_abs_q3_8(f0[b]),
            .line_length_q8_8(f1[b]), .derivative_zc(f2[b]),
            .threshold_crossings(f3[b]), .local_amp_mean_q3_8(f4[b]),
            .local_amp_range_q3_8(f5[b]), .amp_transition_q3_8(f6[b]),
            .overflow(bank_overflow[b])
        );
    end endgenerate
    assign features_valid = |valid;
    assign mean_abs_q3_8 = valid[0] ? f0[0] : f0[1];
    assign line_length_q8_8 = valid[0] ? f1[0] : f1[1];
    assign derivative_zc = valid[0] ? f2[0] : f2[1];
    assign threshold_crossings = valid[0] ? f3[0] : f3[1];
    assign local_amp_mean_q3_8 = valid[0] ? f4[0] : f4[1];
    assign local_amp_range_q3_8 = valid[0] ? f5[0] : f5[1];
    assign amp_transition_q3_8 = valid[0] ? f6[0] : f6[1];
    assign overflow = seq_overflow | (|bank_overflow) | (&valid);
    always @(posedge clk or negedge resetn)
        if (!resetn) window_id <= 0;
        else if (features_valid) window_id <= window_id + 1'b1;
endmodule
