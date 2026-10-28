// One caller-supplied processing clock: fixed wrappers use 100 kHz for the
// 240-entry shared-model mode or 1 kHz for either 512-entry mode. The adaptive
// wrapper uses 500 Hz idle / 100 kHz during Stage 2 and drain. Stage 1 advances on
// alternate cycles; Stage 2 replay advances every cycle when triggered.
// The two causal filters remain independent and process every input sample.
module two_stage_shared_replay_top #(
    parameter SHARED_HP1_MODEL = 0,
    parameter DEEP_HISTORY = 0,
    parameter CLOCK_GATING = 1,
    parameter STAGE1_FULL_RATE = 0
) (
    input wire clk, resetn, sample_valid,
    input wire signed [31:0] sample_q16_16,
    output reg class_valid,
    output reg [31:0] class_window_id,
    output reg [1:0] class_code,
    output reg class_is_stage2,
    output wire classifier_clock_enabled,
    output wire stage1_window_overflow, stage2_window_overflow,
    output wire classifier_overflow,
    output wire processing_fast_request
);
    localparam IDLE=4'd0, REPLAY_1=4'd1, DECIDE_1=4'd2;
    localparam REPLAY_2=4'd3, SEND_2=4'd4, WAIT_2=4'd5;
    localparam PREFETCH_1=4'd6, PREFETCH_2=4'd7;
    localparam SCORE_1_REQ=4'd8, SCORE_1_WAIT=4'd9;
    localparam integer RAM_DEPTH=SHARED_HP1_MODEL && !DEEP_HISTORY ? 240 : 512;
    function [8:0] advance_ptr;
        input [8:0] ptr;
        begin
            if (RAM_DEPTH==240 && ptr==9'd239) advance_ptr=0;
            else advance_ptr=ptr+9'd1;
        end
    endfunction
    reg [3:0] state;
    reg slow_phase;
    always @(posedge clk or negedge resetn)
        if (!resetn) slow_phase <= 0;
        else slow_phase <= ~slow_phase;
    wire stage1_replay_step=STAGE1_FULL_RATE || !slow_phase;

    wire signed [63:0] raw_wide={{32{sample_q16_16[31]}},sample_q16_16};
    wire signed [63:0] raw_q8=raw_wide>=0 ? raw_wide>>>8 : -((-raw_wide)>>>8);
    wire signed [11:0] s1_input=raw_q8>64'sd2047 ? 12'sd2047 :
        raw_q8< -64'sd2048 ? -12'sd2048 : raw_q8[11:0];
    wire signed [11:0] hp_sample;
    wire hp_valid;
    ecg_pthighpass_iir hp (
        .clk(clk),.resetn(resetn),.sample_in(s1_input),
        .sample_valid(sample_valid),.sample_out(hp_sample),
        .sample_out_valid(hp_valid)
    );
    wire signed [13:0] s2_sample;
    wire s2_valid;
    // Both filter paths see the same clipped Q3.8 raw sample. The Stage 2
    // filter's Q16.16 port receives the exact sign-extended Q3.8 value.
    wire signed [31:0] shared_raw_q16_16=$signed(s1_input)<<<8;
    generate if (SHARED_HP1_MODEL) begin: shared_stage2_filter
        stage2_shared_hp1_q29 filter2 (
            .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
            .sample_q3_8(s1_input),.output_valid(s2_valid),
            .output_q5_8(s2_sample)
        );
    end else begin: original_stage2_filter
        stage2_filter_q29 filter2 (
            .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
            .sample_q16_16(shared_raw_q16_16),.output_valid(s2_valid),
            .output_q5_8(s2_sample)
        );
    end endgenerate
    reg signed [11:0] hp_d1,hp_d2,hp_d3,hp_d4,hp_seq;
    reg [3:0] hp_valid_delay;
    reg hp_seq_valid;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            hp_d1<=0;hp_d2<=0;hp_d3<=0;hp_d4<=0;hp_seq<=0;
            hp_valid_delay<=0;hp_seq_valid<=0;
        end else begin
            hp_d1<=hp_sample;hp_d2<=hp_d1;hp_d3<=hp_d2;hp_d4<=hp_d3;
            hp_seq<=hp_d4;
            hp_valid_delay<={hp_valid_delay[2:0],hp_valid};
            hp_seq_valid<=hp_valid_delay[3];
        end
    end
    wire signed [11:0] hp_aligned = SHARED_HP1_MODEL ? hp_d1 : hp_seq;
    wire hp_aligned_valid = SHARED_HP1_MODEL ? hp_valid_delay[0] : hp_seq_valid;
    wire signed [13:0] seq_sample;
    wire seq_valid,seq_overflow;
    wire [1:0] start,finish,enable,active;
    wire [31:0] sample_index,window_count;
    reg restart_pending;
    reg [31:0] restart_target,raw_sample_count;
    wire seq_restart=restart_pending && s2_valid &&
        sample_index==restart_target;
    always @(posedge clk or negedge resetn)
        if (!resetn) raw_sample_count<=0;
        else if (sample_valid) raw_sample_count<=raw_sample_count+32'd1;
    feature_set #(.SAMPLE_WIDTH(14),.WINDOW_SAMPLES(240),.STEP_SAMPLES(120)) seq (
        .clk(clk),.resetn(resetn),.restart(seq_restart),
        .sample_in(s2_sample),.sample_valid(s2_valid),
        .sample_out(seq_sample),.sample_out_valid(seq_valid),
        .sample_index(sample_index),.window_count(window_count),
        .window_start(start),.window_end(finish),
        .feature_bank_enable(enable),.window_active(active),
        .window_overflow(seq_overflow)
    );

    // Two 16-bit write lanes in a RAM_DEPTH x 32 logical history. In the
    // shared-model modes, Stage 2's lane stops writing when no started Stage 2
    // window is collecting. It remains readable for pending replay. Vivado
    // maps the independently write-enabled lanes to two RAMB18s.
    (* ram_style="block" *) reg [31:0] window_history [0:RAM_DEPTH-1];
    reg [8:0] write_ptr;
    reg alignment_overflow;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            write_ptr<=0;alignment_overflow<=0;
        end else if (seq_valid) begin
            write_ptr<=advance_ptr(write_ptr);
            if (!hp_aligned_valid) alignment_overflow<=1;
        end
    end
    reg [8:0] read_ptr;
    reg [7:0] replay_index;
    reg [31:0] replay_word;
    wire replay_fetch=state==PREFETCH_1 || state==PREFETCH_2 ||
        (state==REPLAY_1 && stage1_replay_step && replay_index!=8'd239) ||
        (state==REPLAY_2 && replay_index!=8'd239);
    wire [1:0] s2_enable_mask;
    always @(posedge clk) begin
        if (seq_valid) begin
            window_history[write_ptr][15:0] <=
                {{4{hp_aligned[11]}},hp_aligned};
            if (!SHARED_HP1_MODEL || |s2_enable_mask)
                window_history[write_ptr][31:16] <=
                    {{2{s2_sample[13]}},s2_sample};
        end
        if (replay_fetch) replay_word<=window_history[read_ptr];
    end
    wire signed [11:0] replay_hp=replay_word[11:0];
    wire signed [13:0] replay_s2=replay_word[29:16];
    wire [8:0] completed_start_ptr=RAM_DEPTH==240 ?
        advance_ptr(write_ptr) : write_ptr-9'd239;

    // Both paths share their 240-sample boundaries. An arm rephases the
    // sequencer so their first new window starts on the next valid sample.
    reg stage2_armed;
    reg [1:0] s2_started;
    reg [31:0] s2_start_id [0:1];
    reg [31:0] s1_start_id [0:1];
    wire [1:0] s2_start_mask=start & {2{stage2_armed}};
    wire [1:0] s2_end_mask=finish & s2_started;
    assign s2_enable_mask=enable & (s2_started|s2_start_mask);
    // The Stage 2 IIR filter stays warm on clk. Only the per-window
    // statistics clock can sleep between Stage 2 episodes.
    wire s2_stats_clk;
    wire s2_stats_clock_enabled=resetn &&
        (!CLOCK_GATING || stage2_armed || |s2_started);
    BUFGCE #(.CE_TYPE("SYNC"),.SIM_DEVICE("7SERIES")) stage2_stats_gate (
        .I(clk),.CE(s2_stats_clock_enabled),.O(s2_stats_clk));
    reg s2_timing_overflow;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            s2_started<=0;
            s2_start_id[0]<=0;s2_start_id[1]<=0;
            s1_start_id[0]<=0;s1_start_id[1]<=0;
            s2_timing_overflow<=0;
        end else begin
            if (seq_restart && |s2_started) s2_timing_overflow<=1;
            if (seq_valid) begin
                s2_started<=(s2_started|s2_start_mask)&~s2_end_mask;
                if (start[0]) s1_start_id[0]<=sample_index-32'd1;
                if (start[1]) s1_start_id[1]<=sample_index-32'd1;
                if (s2_start_mask[0])
                    s2_start_id[0]<=sample_index-32'd1;
                if (s2_start_mask[1])
                    s2_start_id[1]<=sample_index-32'd1;
            end
        end
    end

    // Running statistics stay separate because the filtered values differ.
    wire signed [31:0] s1_sum [0:1],s2_sum [0:1];
    wire signed [13:0] s1_min [0:1],s1_max [0:1];
    wire signed [13:0] s2_min [0:1],s2_max [0:1];
    wire [31:0] s1_diff [0:1],s2_diff [0:1];
    wire [8:0] s1_zero [0:1];
    genvar b;
    generate for(b=0;b<2;b=b+1) begin: banks
        shared_stream_stats_bank stats1 (
            .clk(clk),.resetn(resetn),.sample_valid(seq_valid),
            .bank_enable(enable[b]),.window_start(start[b]),
            .window_end(finish[b]),.sample_q8({{2{hp_aligned[11]}},hp_aligned}),
            .sum_snapshot(s1_sum[b]),.min_snapshot(s1_min[b]),
            .max_snapshot(s1_max[b]),.diff_snapshot(s1_diff[b]),
            .zero_snapshot(s1_zero[b])
        );
        shared_stream_stats_bank stats2 (
            .clk(s2_stats_clk),.resetn(resetn),.sample_valid(seq_valid),
            .bank_enable(s2_enable_mask[b]),.window_start(s2_start_mask[b]),
            .window_end(s2_end_mask[b]),.sample_q8(seq_sample),
            .sum_snapshot(s2_sum[b]),.min_snapshot(s2_min[b]),
            .max_snapshot(s2_max[b]),.diff_snapshot(s2_diff[b]),
            .zero_snapshot()
        );
    end endgenerate

    reg [31:0] completed_count;
    reg s2_ready_valid,s2_ready_bank;
    reg [31:0] s2_ready_id,s2_ready_start_sample;
    reg [8:0] s2_ready_start;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            s2_ready_valid<=0;s2_ready_bank<=0;
            s2_ready_id<=0;s2_ready_start<=0;
            s2_ready_start_sample<=0;
        end else begin
            s2_ready_valid<=0;
            if (seq_valid && |s2_end_mask) begin
                s2_ready_valid<=1;
                s2_ready_bank<=s2_end_mask[1];
                s2_ready_id<=completed_count;
                s2_ready_start_sample<=s2_end_mask[1]?s2_start_id[1]:s2_start_id[0];
                s2_ready_start<=completed_start_ptr;
            end
        end
    end

    reg ready_valid,ready_bank;
    reg [31:0] ready_id,ready_start_sample;
    reg [8:0] ready_start;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ready_valid<=0;ready_bank<=0;ready_id<=0;ready_start<=0;
            ready_start_sample<=0;completed_count<=0;
        end else begin
            ready_valid<=0;
            if (seq_valid && |finish) begin
                ready_valid<=1;
                ready_bank<=finish[1];
                ready_id<=completed_count;
                ready_start_sample<=finish[1]?s1_start_id[1]:s1_start_id[0];
                ready_start<=completed_start_ptr;
                completed_count<=completed_count+32'd1;
            end
        end
    end

    reg [31:0] work_id;
    reg [31:0] work_sample_start;
    reg work_is_stage2;
    reg work_bank;
    reg [8:0] start_ptr;
    reg signed [31:0] active_sum;
    reg signed [13:0] active_min,active_max;
    reg [31:0] active_diff;
    reg [8:0] active_zero;
    reg [31:0] abs_acc,block_acc,block_min,block_max,transition_acc;
    reg [8:0] crossing_acc,zc_acc;
    reg prev_above,above_seen,prev_deriv_sign,deriv_seen;
    reg signed [13:0] prev_replay;
    reg [31:0] prev_block;
    reg [3:0] completed_blocks;
    wire stage2_mode=state==REPLAY_2;
    wire signed [14:0] selected_sample=stage2_mode ?
        $signed(replay_s2) : $signed(replay_hp);
    wire signed [31:0] mean_fix=active_sum/32'sd240;
    wire signed [31:0] centered_num=stage2_mode && !SHARED_HP1_MODEL ?
        $signed(selected_sample)*32'sd240-active_sum :
        ($signed(selected_sample)-mean_fix)*32'sd240;
    wire [31:0] abs_centered=centered_num<0 ? -centered_num : centered_num;
    wire signed [31:0] min_centered=stage2_mode && !SHARED_HP1_MODEL ?
        $signed(active_min)*32'sd240-active_sum :
        ($signed(active_min)-mean_fix)*32'sd240;
    wire signed [31:0] max_centered=stage2_mode && !SHARED_HP1_MODEL ?
        $signed(active_max)*32'sd240-active_sum :
        ($signed(active_max)-mean_fix)*32'sd240;
    wire [31:0] min_mag=min_centered<0 ? -min_centered : min_centered;
    wire [31:0] max_mag=max_centered<0 ? -max_centered : max_centered;
    wire [31:0] peak=min_mag>max_mag ? min_mag : max_mag;
    wire above=peak!=0 && 32'd5*abs_centered>=peak;
    wire [31:0] abs_next=abs_acc+abs_centered;
    wire [8:0] crossing_next=crossing_acc+
        ((above_seen && above!=prev_above) ? 9'd1 : 9'd0);
    wire signed [14:0] replay_diff=selected_sample-$signed(prev_replay);
    wire [14:0] replay_diff_abs=replay_diff<0 ? -replay_diff : replay_diff;
    wire keep_deriv=SHARED_HP1_MODEL ?
        (replay_index!=0 && replay_diff!=0) :
        (replay_index!=0 && 32'd4780*replay_diff_abs>active_diff);
    wire [8:0] zc_next=zc_acc+
        ((keep_deriv && deriv_seen && (replay_diff<0)!=prev_deriv_sign) ? 9'd1 : 9'd0);
    wire [31:0] block_next=block_acc+abs_centered;
    wire block_last=replay_index%30==29;
    wire [31:0] block_min_next=completed_blocks==0 || block_next<block_min ? block_next:block_min;
    wire [31:0] block_max_next=completed_blocks==0 || block_next>block_max ? block_next:block_max;
    wire [31:0] transition_next=completed_blocks==0 ? transition_acc :
        transition_acc+(block_next>=prev_block ? block_next-prev_block : prev_block-block_next);
    wire [31:0] mean_units=abs_next/32'd57600;
    wire [31:0] range_units=(block_max_next-block_min_next)/32'd7200;
    wire [31:0] transition_units=transition_next/32'd50400;
    wire signed [31:0] s1_x0=$signed(mean_units[11:0])<<<8;
    wire signed [31:0] s1_x1=$signed({1'b0,active_zero[7:0]})<<<15;
    wire signed [31:0] s1_x2=$signed({1'b0,active_diff[20:0]})<<<7;
    wire signed [31:0] s1_x3=$signed({1'b0,crossing_next[7:0]})<<<16;
    wire signed [63:0] stage1_score_next=64'sd793979191296+
        $signed(s1_x0)*32'sd44266604-
        $signed(s1_x1)*32'sd1368018-
        $signed(s1_x2)*32'sd435043+
        $signed(s1_x3)*32'sd1618828;
    reg signed [63:0] stage1_score;
    reg current_abnormal;
    reg [2:0] votes;
    reg [1:0] vote_count;
    wire [2:0] next_votes={votes[1:0],current_abnormal};
    wire [1:0] next_vote_count=next_votes[0]+next_votes[1]+next_votes[2];

    reg signed [31:0] f0,f1,f2,f3,f4,f5,f6;
    reg request_valid,one_normal;
    wire classifier_ready,result_valid,result_vf,classifier_core_overflow;
    wire [31:0] result_id;
    wire signed [63:0] classifier_score;
    wire legacy_ready,legacy_result_valid,legacy_result_vf,legacy_overflow;
    wire legacy_clock_enabled;
    wire [31:0] legacy_result_id;
    wire signed [63:0] legacy_score;
    wire mac_ready,mac_result_valid,mac_result_vf,mac_overflow;
    wire mac_clock_enabled,mac_result_stage2;
    wire [31:0] mac_result_id;
    wire signed [63:0] mac_score_q40;
    assign classifier_ready=SHARED_HP1_MODEL ? mac_ready : legacy_ready;
    assign result_valid=SHARED_HP1_MODEL ? mac_result_valid : legacy_result_valid;
    assign result_vf=SHARED_HP1_MODEL ? mac_result_vf : legacy_result_vf;
    assign result_id=SHARED_HP1_MODEL ? mac_result_id : legacy_result_id;
    assign classifier_score=SHARED_HP1_MODEL ?
        ($signed(mac_score_q40) >>> 11) : legacy_score;
    assign classifier_clock_enabled=SHARED_HP1_MODEL ?
        mac_clock_enabled : legacy_clock_enabled;
    assign classifier_core_overflow=SHARED_HP1_MODEL ? mac_overflow : legacy_overflow;
    shared_classifier_mac_q #(.GATE_IDLE_CLOCK(CLOCK_GATING)) mac2 (
        .clk(clk),.resetn(resetn),
        .request_valid(SHARED_HP1_MODEL && request_valid),
        .request_stage2(work_is_stage2),.request_window_id(work_id),
        .f0(f0),.f1(f1),.f2(f2),.f3(f3),.f4(f4),.f5(f5),
        .input_ready(mac_ready),.classifier_clock_enabled(mac_clock_enabled),
        .result_valid(mac_result_valid),.result_window_id(mac_result_id),
        .result_stage2(mac_result_stage2),.vf(mac_result_vf),
        .score_q40(mac_score_q40),.overflow(mac_overflow)
    );
    // The shared-pipeline export uses six Q3.12 weights. Doubling each
    // integer coefficient expresses it as Q2.13 for this gated MAC.
    stage2_classifier_gated_q #(
        .W0(SHARED_HP1_MODEL ? -16'sd20428 : -16'sd7552),
        .W1(SHARED_HP1_MODEL ? -16'sd168 : 16'sd188),
        .W2(SHARED_HP1_MODEL ? 16'sd562 : -16'sd1),
        .W3(SHARED_HP1_MODEL ? 16'sd62 : 16'sd3),
        .W4(SHARED_HP1_MODEL ? -16'sd5540 : -16'sd7552),
        .W5(SHARED_HP1_MODEL ? -16'sd2026 : -16'sd5190),
        .W6(SHARED_HP1_MODEL ? 16'sd0 : 16'sd1166),
        .BIAS_Q29(SHARED_HP1_MODEL ? 64'sd676986880 : 64'sd532021248)
    ) classifier2 (
        .clk(clk),.resetn(resetn),.hold_awake(1'b0),
        .request_valid(!SHARED_HP1_MODEL && request_valid),.request_window_id(work_id),
        .f0_q16_16(f0),.f1_q16_16(f1),.f2_q16_16(f2),
        .f3_q16_16(f3),.f4_q16_16(f4),.f5_q16_16(f5),
        .f6_q16_16(f6),.input_ready(legacy_ready),
        .classifier_clock_enabled(legacy_clock_enabled),
        .result_valid(legacy_result_valid),.result_window_id(legacy_result_id),
        .vf(legacy_result_vf),.score_q29(legacy_score),
        .overflow(legacy_overflow)
    );
    reg scheduler_overflow;
    reg s1_pending,s1_pending_bank,s2_pending,s2_pending_bank;
    reg [31:0] s1_pending_id,s2_pending_id;
    reg [31:0] s1_pending_sample_start,s2_pending_sample_start;
    reg [8:0] s1_pending_start,s2_pending_start;
    // Keep the whole pipeline fast for the complete Stage 2 episode, including
    // historical windows that must finish after Stage 1 disarms new starts.
    // Include handoff pulses so the request never drops between collect/replay.
    assign processing_fast_request=stage2_armed || restart_pending ||
        |s2_started || s2_ready_valid || s2_pending ||
        state==PREFETCH_2 || state==REPLAY_2 || state==SEND_2 || state==WAIT_2;
    assign stage1_window_overflow=seq_overflow|alignment_overflow|scheduler_overflow;
    assign stage2_window_overflow=s2_timing_overflow|scheduler_overflow;
    assign classifier_overflow=classifier_core_overflow|scheduler_overflow;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state<=IDLE;read_ptr<=0;start_ptr<=0;replay_index<=0;
            work_id<=0;work_sample_start<=0;
            work_bank<=0;work_is_stage2<=0;
            active_sum<=0;active_min<=0;
            active_max<=0;active_diff<=0;active_zero<=0;
            abs_acc<=0;block_acc<=0;block_min<=0;block_max<=0;
            transition_acc<=0;crossing_acc<=0;zc_acc<=0;
            prev_above<=0;above_seen<=0;prev_deriv_sign<=0;
            deriv_seen<=0;prev_replay<=0;prev_block<=0;
            completed_blocks<=0;stage1_score<=0;current_abnormal<=0;
            votes<=0;vote_count<=0;f0<=0;f1<=0;f2<=0;f3<=0;
            f4<=0;f5<=0;f6<=0;request_valid<=0;
            one_normal<=0;stage2_armed<=0;
            restart_pending<=0;restart_target<=0;
            scheduler_overflow<=0;
            s1_pending<=0;s1_pending_bank<=0;s1_pending_id<=0;
            s1_pending_start<=0;s1_pending_sample_start<=0;
            s2_pending<=0;s2_pending_bank<=0;
            s2_pending_id<=0;s2_pending_start<=0;
            s2_pending_sample_start<=0;
            class_valid<=0;class_window_id<=0;class_code<=0;
            class_is_stage2<=0;
        end else begin
            class_valid<=0;
            request_valid<=0;
            if (seq_restart) restart_pending<=0;
            if (ready_valid) begin
                if (s1_pending) scheduler_overflow<=1;
                s1_pending<=1;s1_pending_bank<=ready_bank;
                s1_pending_id<=ready_id;s1_pending_start<=ready_start;
                s1_pending_sample_start<=ready_start_sample;
            end
            if (s2_ready_valid) begin
                if (s2_pending) scheduler_overflow<=1;
                s2_pending<=1;s2_pending_bank<=s2_ready_bank;
                s2_pending_id<=s2_ready_id;s2_pending_start<=s2_ready_start;
                s2_pending_sample_start<=s2_ready_start_sample;
            end
            case(state)
                IDLE: if (s1_pending) begin
                    s1_pending<=0;
                    work_is_stage2<=0;
                    work_id<=s1_pending_id;work_bank<=s1_pending_bank;
                    work_sample_start<=s1_pending_sample_start;
                    start_ptr<=s1_pending_start;read_ptr<=s1_pending_start;
                    replay_index<=0;
                    active_sum<=s1_pending_bank?s1_sum[1]:s1_sum[0];
                    active_min<=s1_pending_bank?s1_min[1]:s1_min[0];
                    active_max<=s1_pending_bank?s1_max[1]:s1_max[0];
                    active_diff<=s1_pending_bank?s1_diff[1]:s1_diff[0];
                    active_zero<=s1_pending_bank?s1_zero[1]:s1_zero[0];
                    abs_acc<=0;crossing_acc<=0;above_seen<=0;
                    state<=PREFETCH_1;
                end else if (s2_pending) begin
                    s2_pending<=0;
                    work_is_stage2<=1;
                    work_id<=s2_pending_id;work_bank<=s2_pending_bank;
                    work_sample_start<=s2_pending_sample_start;
                    start_ptr<=s2_pending_start;read_ptr<=s2_pending_start;
                    replay_index<=0;
                    active_sum<=s2_pending_bank?s2_sum[1]:s2_sum[0];
                    active_min<=s2_pending_bank?s2_min[1]:s2_min[0];
                    active_max<=s2_pending_bank?s2_max[1]:s2_max[0];
                    active_diff<=s2_pending_bank?s2_diff[1]:s2_diff[0];
                    active_zero<=0;
                    abs_acc<=0;crossing_acc<=0;zc_acc<=0;
                    block_acc<=0;block_min<=0;block_max<=0;
                    transition_acc<=0;prev_above<=0;above_seen<=0;
                    prev_deriv_sign<=0;deriv_seen<=0;
                    prev_replay<=0;prev_block<=0;completed_blocks<=0;
                    state<=PREFETCH_2;
                end
                PREFETCH_1: begin
                    read_ptr<=advance_ptr(read_ptr);
                    state<=REPLAY_1;
                end
                REPLAY_1: if (stage1_replay_step) begin
                    abs_acc<=abs_next;crossing_acc<=crossing_next;
                    prev_above<=above;above_seen<=1;
                    read_ptr<=advance_ptr(read_ptr);
                    if (replay_index==8'd239) begin
                        if (SHARED_HP1_MODEL) begin
                            f0<=s1_x0;f1<=s1_x1;f2<=s1_x2;f3<=s1_x3;
                            f4<=0;f5<=0;f6<=0;
                            state<=SCORE_1_REQ;
                        end else begin
                            stage1_score<=stage1_score_next;
                            current_abnormal<=stage1_score_next>=0;
                            state<=DECIDE_1;
                        end
                    end else replay_index<=replay_index+1'b1;
                end
                SCORE_1_REQ: if (classifier_ready) begin
                    request_valid<=1;state<=SCORE_1_WAIT;
                end
                SCORE_1_WAIT: if (result_valid) begin
                    if (result_id!=work_id || mac_result_stage2)
                        scheduler_overflow<=1;
                    stage1_score<=mac_score_q40;
                    current_abnormal<=mac_score_q40>=0;
                    state<=DECIDE_1;
                end
                DECIDE_1: begin
                    votes<=next_votes;
                    if (vote_count<3) vote_count<=vote_count+1'b1;
                    if (vote_count>=2) begin
                        if (next_vote_count>=2) begin
                            one_normal<=0;
                            if (!stage2_armed) begin
                                stage2_armed<=1;
                                restart_pending<=1;
                                restart_target<=raw_sample_count+
                                    (sample_valid ? 32'd1:32'd0);
                                // The rephase discards partial Stage 1
                                // windows, so old votes are no longer three
                                // consecutive one-second-stride windows.
                                votes<=0;
                                vote_count<=0;
                            end
                            class_valid<=1;class_window_id<=work_id;
                            class_code<=2'd3;class_is_stage2<=0;
                            state<=IDLE;
                        end else begin
                            if (one_normal) begin
                                // Stop opening new windows. Already-started
                                // Stage 2 windows drain to a historical result.
                                stage2_armed<=0;
                            end
                            one_normal<=1;
                            class_valid<=1;class_window_id<=work_id;
                            class_code<=0;class_is_stage2<=0;state<=IDLE;
                        end
                    end else state<=IDLE;
                end
                PREFETCH_2: begin
                    read_ptr<=advance_ptr(read_ptr);
                    state<=REPLAY_2;
                end
                REPLAY_2: begin
                    abs_acc<=abs_next;crossing_acc<=crossing_next;
                    zc_acc<=zc_next;prev_above<=above;above_seen<=1;
                    if (keep_deriv) begin
                        prev_deriv_sign<=replay_diff<0;deriv_seen<=1;
                    end
                    prev_replay<=selected_sample[13:0];
                    read_ptr<=advance_ptr(read_ptr);
                    if (block_last) begin
                        block_acc<=0;block_min<=block_min_next;
                        block_max<=block_max_next;
                        transition_acc<=transition_next;
                        prev_block<=block_next;
                        completed_blocks<=completed_blocks+1'b1;
                    end else block_acc<=block_next;
                    if (replay_index==8'd239) begin
                        f0<=SHARED_HP1_MODEL ?
                            $signed({1'b0,(mean_units>4095 ? 12'd4095:mean_units[11:0])})<<<8 :
                            $signed({1'b0,(mean_units>2047 ? 11'd2047:mean_units[10:0])})<<<8;
                        f1<=SHARED_HP1_MODEL ?
                            $signed(zc_next)<<<15 :
                            $signed({1'b0,(active_diff>65535 ? 16'd65535:active_diff[15:0])})<<<8;
                        f2<=SHARED_HP1_MODEL ?
                            $signed({1'b0,(active_diff>131070 ? 16'd65535:active_diff[16:1])})<<<8 :
                            $signed(zc_next)<<<16;
                        f3<=$signed(crossing_next)<<<16;
                        f4<=SHARED_HP1_MODEL ?
                            $signed({1'b0,(range_units>4095 ? 12'd4095:range_units[11:0])})<<<8 :
                            $signed({1'b0,(mean_units>2047 ? 11'd2047:mean_units[10:0])})<<<8;
                        f5<=SHARED_HP1_MODEL ?
                            $signed({1'b0,(transition_units>1023 ? 10'd1023:transition_units[9:0])})<<<8 :
                            $signed({1'b0,(range_units>2047 ? 11'd2047:range_units[10:0])})<<<8;
                        f6<=SHARED_HP1_MODEL ? 32'sd0 :
                            $signed({1'b0,(transition_units>2047 ? 11'd2047:transition_units[10:0])})<<<8;
                        state<=SEND_2;
                    end else replay_index<=replay_index+1'b1;
                end
                SEND_2: if (classifier_ready) begin
                    request_valid<=1;state<=WAIT_2;
                end
                WAIT_2: if (result_valid) begin
                    if (result_id!=work_id ||
                        (SHARED_HP1_MODEL && !mac_result_stage2))
                        scheduler_overflow<=1;
                    class_valid<=1;class_window_id<=result_id;
                    class_code<=result_vf?2'd2:2'd1;
                    class_is_stage2<=1;
                    state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// Streaming statistics for one overlap bank, shared by either filter path.
// The replay arithmetic lives only in two_stage_shared_replay_top.
module shared_stream_stats_bank (
    input wire clk,resetn,sample_valid,bank_enable,window_start,window_end,
    input wire signed [13:0] sample_q8,
    output reg signed [31:0] sum_snapshot,
    output reg signed [13:0] min_snapshot,max_snapshot,
    output reg [31:0] diff_snapshot,
    output reg [8:0] zero_snapshot
);
    reg signed [31:0] sum_acc;
    reg signed [13:0] min_acc,max_acc,prev_sample;
    reg [31:0] diff_acc;
    reg [8:0] zero_acc;
    reg [1:0] last_nonzero_sign;
    wire signed [31:0] sum_next=window_start?$signed(sample_q8):sum_acc+$signed(sample_q8);
    wire signed [13:0] min_next=window_start||sample_q8<min_acc?sample_q8:min_acc;
    wire signed [13:0] max_next=window_start||sample_q8>max_acc?sample_q8:max_acc;
    wire signed [14:0] delta=$signed(sample_q8)-$signed(prev_sample);
    wire [14:0] delta_abs=delta<0?-delta:delta;
    wire [31:0] diff_next=window_start?0:diff_acc+delta_abs;
    wire [1:0] sign_next=delta>0?2'd1:delta<0?2'd2:2'd0;
    wire [8:0] zero_next=window_start?0:zero_acc+
        ((sign_next!=0 && last_nonzero_sign!=0 && sign_next!=last_nonzero_sign)?9'd1:9'd0);
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sum_acc<=0;min_acc<=0;max_acc<=0;prev_sample<=0;
            diff_acc<=0;zero_acc<=0;last_nonzero_sign<=0;
            sum_snapshot<=0;min_snapshot<=0;max_snapshot<=0;
            diff_snapshot<=0;zero_snapshot<=0;
        end else if (sample_valid && bank_enable) begin
            sum_acc<=sum_next;min_acc<=min_next;max_acc<=max_next;
            prev_sample<=sample_q8;diff_acc<=diff_next;zero_acc<=zero_next;
            if (window_start) last_nonzero_sign<=0;
            else if (sign_next!=0) last_nonzero_sign<=sign_next;
            if (window_end) begin
                sum_snapshot<=sum_next;min_snapshot<=min_next;
                max_snapshot<=max_next;diff_snapshot<=diff_next;
                zero_snapshot<=zero_next;
            end
        end
    end
endmodule
