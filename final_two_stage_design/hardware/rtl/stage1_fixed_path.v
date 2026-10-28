// Fixed-point Stage 1 path reuses the copied high-pass, sequencer, centered
// replay and difference feature banks; it avoids the legacy FP16 IP path.
module stage1_fixed_feature_bank (
    input wire clk, resetn, sample_valid, bank_enable, window_start, window_end,
    input wire signed [11:0] sample_q8,
    output reg feature_valid,
    output reg signed [31:0] mean_abs_q16_16, zero_q16_16,
    output reg signed [31:0] line_q16_16, threshold_q16_16
);
    wire centered_valid, diff_valid;
    wire signed [11:0] mean_q8;
    wire [7:0] threshold_count, zero_count;
    wire [20:0] diff_sum;
    reg [7:0] zero_latched;
    reg [20:0] diff_latched;
    feature_mean_abs_fix_mean_bank #(.SAMPLE_WIDTH(12),.WINDOW_SAMPLES(240)) center (
        .clk(clk),.resetn(resetn),.sample_in(sample_q8),
        .sample_valid(sample_valid),.bank_enable(bank_enable),
        .window_start(window_start),.window_end(window_end),
        .mean_abs_q8(mean_q8),.threshold_crossing_count(threshold_count),
        .feature_valid(centered_valid)
    );
    feature_line_zero_diff_bank #(.SAMPLE_WIDTH(12),.WINDOW_SAMPLES(240),.WINDOW_SECONDS(2)) diff (
        .clk(clk),.resetn(resetn),.sample_in(sample_q8),
        .sample_valid(sample_valid),.bank_enable(bank_enable),
        .window_start(window_start),.window_end(window_end),
        .diff_abs_sum(diff_sum),.zero_crossing_count(zero_count),
        .feature_valid(diff_valid)
    );
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            zero_latched<=0; diff_latched<=0; feature_valid<=0;
            mean_abs_q16_16<=0; zero_q16_16<=0;
            line_q16_16<=0; threshold_q16_16<=0;
        end else begin
            feature_valid<=0;
            if (diff_valid) begin
                zero_latched<=zero_count;
                diff_latched<=diff_sum;
            end
            if (centered_valid) begin
                mean_abs_q16_16 <= $signed(mean_q8) <<< 8;
                zero_q16_16 <= $signed({1'b0,zero_latched}) <<< 15;
                line_q16_16 <= $signed({1'b0,diff_latched}) <<< 7;
                threshold_q16_16 <= $signed({1'b0,threshold_count}) <<< 16;
                feature_valid<=1;
            end
        end
    end
endmodule

module stage1_fixed_path (
    input wire clk, resetn, sample_valid,
    input wire signed [11:0] sample_q3_8,
    output reg sequence_valid, sequence_abnormal,
    output reg [31:0] sequence_window_id,
    output wire window_overflow
);
    wire signed [11:0] hp_sample, seq_sample;
    wire hp_valid, seq_valid;
    ecg_pthighpass_iir hp (
        .clk(clk),.resetn(resetn),.sample_in(sample_q3_8),
        .sample_valid(sample_valid),.sample_out(hp_sample),
        .sample_out_valid(hp_valid)
    );
    wire [31:0] sample_index, window_count;
    wire [1:0] start, finish, enable, active;
    feature_set #(.SAMPLE_WIDTH(12),.WINDOW_SAMPLES(240),.STEP_SAMPLES(120)) seq (
        .clk(clk),.resetn(resetn),.restart(1'b0),
        .sample_in(hp_sample),.sample_valid(hp_valid),
        .sample_out(seq_sample),.sample_out_valid(seq_valid),
        .sample_index(sample_index),.window_count(window_count),
        .window_start(start),.window_end(finish),
        .feature_bank_enable(enable),.window_active(active),
        .window_overflow(window_overflow)
    );
    wire [1:0] feature_valid;
    wire signed [31:0] mean [0:1], zero [0:1], line [0:1], thresh [0:1];
    genvar b;
    generate for(b=0;b<2;b=b+1) begin: banks
        stage1_fixed_feature_bank bank (
            .clk(clk),.resetn(resetn),.sample_valid(seq_valid),
            .bank_enable(enable[b]),.window_start(start[b]),
            .window_end(finish[b]),.sample_q8(seq_sample),
            .feature_valid(feature_valid[b]),
            .mean_abs_q16_16(mean[b]),.zero_q16_16(zero[b]),
            .line_q16_16(line[b]),.threshold_q16_16(thresh[b])
        );
    end endgenerate
    wire signed [31:0] x0=feature_valid[0]?mean[0]:mean[1];
    wire signed [31:0] x1=feature_valid[0]?zero[0]:zero[1];
    wire signed [31:0] x2=feature_valid[0]?line[0]:line[1];
    wire signed [31:0] x3=feature_valid[0]?thresh[0]:thresh[1];
    // Folded Stage 1 coefficients from stage1/models/pthighpass_svm_cpu_export.mat.
    // Q8.24, rounded from the saved single-precision W/Bhw values.
    localparam signed [31:0] W0=32'sd44266604;
    localparam signed [31:0] W1=-32'sd1368018;
    localparam signed [31:0] W2=-32'sd435043;
    localparam signed [31:0] W3=32'sd1618828;
    localparam signed [63:0] BIAS_Q40=64'sd793979191296;
    wire signed [63:0] score=BIAS_Q40+
        $signed(x0)*$signed(W0)+$signed(x1)*$signed(W1)+
        $signed(x2)*$signed(W2)+$signed(x3)*$signed(W3);
    reg [2:0] votes;
    reg [1:0] valid_count;
    reg [31:0] feature_window_id;
    wire current_abnormal=score>=0;
    wire [2:0] next_votes={votes[1:0],current_abnormal};
    wire [1:0] next_vote_count=next_votes[0]+next_votes[1]+next_votes[2];
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            votes<=0;valid_count<=0;feature_window_id<=0;
            sequence_valid<=0;sequence_abnormal<=0;sequence_window_id<=0;
        end else begin
            sequence_valid<=0;
            if (|feature_valid) begin
                votes<=next_votes;
                if (valid_count<3) valid_count<=valid_count+1'b1;
                if (valid_count>=2) begin
                    sequence_valid<=1;
                    sequence_abnormal<=next_vote_count>=2;
                    sequence_window_id<=feature_window_id;
                end
                feature_window_id<=feature_window_id+1'b1;
            end
        end
    end
endmodule
