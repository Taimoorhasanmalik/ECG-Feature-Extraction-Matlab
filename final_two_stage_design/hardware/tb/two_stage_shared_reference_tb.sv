`timescale 1ns/1ps
module two_stage_shared_reference_tb #(
    parameter integer N=1200,
    parameter integer INITIAL_PHASE=0,
    parameter integer SHARED_HP1_MODEL=0,
    parameter integer DEEP_HISTORY=0,
    parameter integer CLOCK_HZ=1000,
    parameter integer STAGE1_FULL_RATE=0,
    parameter integer ADAPTIVE=0,
    parameter integer SOURCE_HZ=200000
);
    localparam WINDOWS=(N-240)/120+1;
    wire clk;
    reg fixed_clk=0,source_clk=0,resetn=0,sample_valid=0;
    reg signed [31:0] sample_q16_16=0;
    generate if (!ADAPTIVE) begin: fixed_oscillator
        always #5 fixed_clk=~fixed_clk;
    end endgenerate
    always #(500000000.0/SOURCE_HZ) source_clk=~source_clk;
    wire clock_ready,fast_mode,processing_fast_request;
    wire delivered_valid,mailbox_ready,mailbox_overflow;
    wire signed [31:0] delivered_data;
    wire pipeline_resetn=resetn && (!ADAPTIVE || clock_ready);
    generate if (ADAPTIVE) begin: adaptive_clock
        ecg_adaptive_clock #(.SOURCE_HZ(SOURCE_HZ)) divider (
            .source_clk(source_clk),.resetn(resetn),
            .fast_request(processing_fast_request),.processing_clk(clk),
            .fast_mode(fast_mode),.clock_ready(clock_ready));
        ecg_sample_mailbox mailbox (
            .source_clk(source_clk),.processing_clk(clk),.resetn(pipeline_resetn),
            .sample_valid(sample_valid),.sample_data(sample_q16_16),
            .sample_ready(mailbox_ready),.overflow(mailbox_overflow),
            .processing_valid(delivered_valid),.processing_data(delivered_data));
    end else begin: fixed_clock
        assign clk=fixed_clk;
        assign clock_ready=1;assign fast_mode=0;
        assign delivered_valid=sample_valid;assign delivered_data=sample_q16_16;
        assign mailbox_ready=1;assign mailbox_overflow=0;
    end endgenerate
    wire class_valid,class_is_stage2,classifier_clock_enabled;
    wire [31:0] class_window_id;
    wire [1:0] class_code;
    wire stage1_window_overflow,stage2_window_overflow,classifier_overflow;
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(SHARED_HP1_MODEL),.DEEP_HISTORY(DEEP_HISTORY),
        .STAGE1_FULL_RATE(STAGE1_FULL_RATE)) dut (
        .clk(clk),.resetn(pipeline_resetn),.sample_valid(delivered_valid),
        .sample_q16_16(delivered_data),.class_valid(class_valid),
        .class_window_id(class_window_id),.class_code(class_code),
        .class_is_stage2(class_is_stage2),
        .classifier_clock_enabled(classifier_clock_enabled),
        .stage1_window_overflow(stage1_window_overflow),
        .stage2_window_overflow(stage2_window_overflow),
        .classifier_overflow(classifier_overflow),
        .processing_fast_request(processing_fast_request)
    );
    reg [31:0] input_mem [0:N-1];
    reg [13:0] filter_mem [0:N-1];
    reg [63:0] all_s1_score_mem [0:N-240];
    reg [82:0] all_feature_mem [0:N-240];
    reg [63:0] all_score_mem [0:N-240];
    reg [1:0] expected_s1_class [0:N-1];
    reg expected_s1_valid [0:N-1];
    reg [31:0] started_sample [0:N-1],ended_id [0:N-1];
    string vector_dir;
    integer i,phase,input_count,filter_count,score_count,s1_class_count,s2_class_count;
    integer start_count,end_count,arm_count,min_arms,model_count;
    integer drain_count,min_drains;
    integer expected_s1_count,last_s1_id;
    reg [3:0] prev_state;
    reg prev_armed,first_sample_due;
    reg [2:0] model_votes;
    reg [31:0] arm_sample_index;
    initial if (ADAPTIVE) begin
        #(1000000000.0*(N/120.0+10.0));
        $fatal(1,"Adaptive test timed out");
    end
    integer source_phase=INITIAL_PHASE,tail_cycles,fast_entries=0,slow_returns=0;
    integer fast_ticks=0,slow_ticks=0;
    time arm_time=0,max_wake_ns=0;
    always @(posedge dut.stage2_armed) if (ADAPTIVE) arm_time=$time;
    reg last_fast=0;
    reg acquisition_run=0;
    always @(negedge source_clk) if (ADAPTIVE && pipeline_resetn && acquisition_run) begin
        source_phase=source_phase+120;
        sample_valid=0;
        if (source_phase>=SOURCE_HZ && input_count<N) begin
            source_phase=source_phase-SOURCE_HZ;
            if (!mailbox_ready) $fatal(1,"Acquisition stalled at sample %0d",input_count);
            sample_valid=1;sample_q16_16=input_mem[input_count];
            input_count=input_count+1;
        end
        if (fast_mode!=last_fast) begin
            if (fast_mode) begin
                fast_entries=fast_entries+1;
                if (!processing_fast_request) $fatal(1,"Unexpected fast entry");
                if ($time-arm_time>max_wake_ns) max_wake_ns=$time-arm_time;
                if ($time-arm_time>1000000+64'd5000000000/SOURCE_HZ)
                    $fatal(1,"Unbounded slow-to-fast wake latency");
            end else begin
                slow_returns=slow_returns+1;
                if (processing_fast_request) $fatal(1,"Slow return before Stage 2 drained");
            end
            $display("CLOCK: mode=%0d sample=%0d time_ns=%0t",fast_mode,input_count,$time);
            last_fast=fast_mode;
        end
        if (mailbox_overflow) $fatal(1,"Mailbox overflow");
    end
    initial begin
        if (!$value$plusargs("VECTOR_DIR=%s",vector_dir)) $fatal(1,"VECTOR_DIR missing");
        $readmemh({vector_dir,"/input.mem"},input_mem);
        if (SHARED_HP1_MODEL) $readmemh({vector_dir,"/filter.mem"},filter_mem);
        $readmemh({vector_dir,"/all_stage1_scores.mem"},all_s1_score_mem);
        $readmemh({vector_dir,"/all_features.mem"},all_feature_mem);
        $readmemh({vector_dir,"/all_scores.mem"},all_score_mem);
        if (!$value$plusargs("MIN_ARMS=%d",min_arms)) min_arms=0;
        if (!$value$plusargs("MIN_DRAINS=%d",min_drains)) min_drains=0;
        phase=INITIAL_PHASE;input_count=0;filter_count=0;score_count=0;s1_class_count=0;
        s2_class_count=0;start_count=0;end_count=0;arm_count=0;
        prev_state=0;prev_armed=0;first_sample_due=0;
        model_votes=0;model_count=0;arm_sample_index=0;
        expected_s1_count=0;last_s1_id=-1;drain_count=0;
        for(i=0;i<N;i=i+1) expected_s1_valid[i]=0;
        if (ADAPTIVE) begin
            repeat(4) @(negedge source_clk);
            resetn=1;
            wait(clock_ready);
            wait(mailbox_ready);
            acquisition_run=1;
        end else begin
            repeat(4) @(negedge clk);
            resetn=1;
        end
        tail_cycles=0;
        for(i=0;i<N*(CLOCK_HZ/120+2)+CLOCK_HZ/120*120;i=i+1) begin
            @(negedge clk);
            if (!ADAPTIVE) begin
                phase=phase+120;
                sample_valid=0;
                if(phase>=CLOCK_HZ && input_count<N) begin
                    phase=phase-CLOCK_HZ;
                    sample_valid=1;
                    sample_q16_16=input_mem[input_count];
                    input_count=input_count+1;
                end
            end else begin
                if (fast_mode) fast_ticks++;else slow_ticks++;
                if (input_count==N) tail_cycles=tail_cycles+1;
                if (tail_cycles==1024) break;
            end
            if(SHARED_HP1_MODEL && dut.s2_valid) begin
                if(filter_count>=N || dut.s2_sample!==filter_mem[filter_count])
                    $fatal(1,"Candidate filter mismatch at sample %0d: RTL %0d ref %0d",
                        filter_count,dut.s2_sample,$signed(filter_mem[filter_count]));
                filter_count=filter_count+1;
            end
            if(prev_state==2 && dut.state!=2) begin
                if(dut.work_id!=score_count || dut.work_sample_start>N-240 ||
                   dut.stage1_score!==all_s1_score_mem[dut.work_sample_start])
                    $fatal(1,"Stage 1 score mismatch window %0d start %0d",
                        dut.work_id,dut.work_sample_start);
                model_votes={model_votes[1:0],dut.stage1_score>=0};
                model_count=model_count+1;
                if(model_count>=3) begin
                    expected_s1_valid[dut.work_id]=1;
                    expected_s1_class[dut.work_id]=
                        (model_votes[0]+model_votes[1]+model_votes[2]>=2) ? 2'd3:2'd0;
                    expected_s1_count=expected_s1_count+1;
                end
                score_count=score_count+1;
            end
            if(prev_state==3 && dut.state!=3) begin
                if(SHARED_HP1_MODEL) begin
                    if(dut.work_sample_start>N-240 ||
                        {dut.f6[19:8],dut.f5[19:8],dut.f4[19:8],
                         dut.f3[24:16],dut.f2[24:8],dut.f1[23:15],dut.f0[19:8]}
                        !==all_feature_mem[dut.work_sample_start])
                        $fatal(1,"Candidate Stage 2 feature mismatch start sample %0d got %021h expected %021h",
                            dut.work_sample_start,
                            {dut.f6[19:8],dut.f5[19:8],dut.f4[19:8],
                             dut.f3[24:16],dut.f2[24:8],dut.f1[23:15],dut.f0[19:8]},
                            all_feature_mem[dut.work_sample_start]);
                end else if(dut.work_sample_start>N-240 ||
                    {dut.f6[19:8],dut.f5[19:8],dut.f4[19:8],
                     dut.f3[24:16],dut.f2[24:16],dut.f1[24:8],dut.f0[19:8]}
                    !==all_feature_mem[dut.work_sample_start])
                    $fatal(1,"Stage 2 feature mismatch start sample %0d",dut.work_sample_start);
            end
            prev_state=dut.state;
            if(dut.stage2_armed && !prev_armed) begin
                arm_count=arm_count+1;
                first_sample_due=1;
                arm_sample_index=dut.raw_sample_count;
                model_votes=0;model_count=0;
            end
            prev_armed=dut.stage2_armed;
            if(dut.seq_valid && |dut.s2_start_mask) begin
                if(first_sample_due) begin
                    if(dut.sample_index-1!=arm_sample_index ||
                       dut.start!=dut.s2_start_mask)
                        $fatal(1,"Both stages did not restart on next sample");
                    first_sample_due=0;
                end
                started_sample[start_count]=dut.sample_index-1;
                start_count=start_count+1;
            end
            if(dut.s2_ready_valid) begin
                ended_id[end_count]=dut.s2_ready_id;
                end_count=end_count+1;
            end
            if(dut.result_valid && dut.work_is_stage2 &&
                (dut.work_sample_start>N-240 ||
                dut.classifier_score!==all_score_mem[dut.work_sample_start]))
                $fatal(1,"Stage 2 score mismatch start sample %0d",dut.work_sample_start);
            if(class_valid) begin
                if(class_is_stage2) begin
                    if(s2_class_count>=end_count ||
                       class_window_id!==ended_id[s2_class_count] ||
                       dut.work_sample_start!==started_sample[s2_class_count] ||
                       class_code!==(all_score_mem[dut.work_sample_start][63] ? 2'd1 :
                                      all_score_mem[dut.work_sample_start]==0 ? 2'd1:2'd2))
                        $fatal(1,"Stage 2 class/id mismatch id=%0d class=%0d",
                            class_window_id,class_code);
                    s2_class_count=s2_class_count+1;
                    if(!dut.stage2_armed) drain_count=drain_count+1;
                end else begin
                    if(class_window_id>=score_count ||
                       (last_s1_id>=0 && class_window_id<=last_s1_id) ||
                       !expected_s1_valid[class_window_id] ||
                       class_code!==expected_s1_class[class_window_id])
                        $fatal(1,"Stage 1 class mismatch id=%0d class=%0d expected=%0d valid=%0d count=%0d",
                            class_window_id,class_code,expected_s1_class[class_window_id],
                            expected_s1_valid[class_window_id],score_count);
                    s1_class_count=s1_class_count+1;
                    last_s1_id=class_window_id;
                end
            end
            if(classifier_clock_enabled!==(SHARED_HP1_MODEL ?
                dut.mac2.pending : dut.classifier2.pending))
                $fatal(1,"classifier clock not gated to pending work");
            if(stage1_window_overflow||stage2_window_overflow||classifier_overflow)
                $fatal(1,"pipeline overflow at cycle %0d state %0d",i,dut.state);
        end
        if (ADAPTIVE && (dut.raw_sample_count!=N || mailbox_overflow ||
            fast_entries!=arm_count || (min_drains>0 && slow_returns==0)))
            $fatal(1,"Adaptive counts accepted=%0d sent=%0d fast=%0d arms=%0d slow=%0d",
                dut.raw_sample_count,input_count,fast_entries,arm_count,slow_returns);
        if(score_count<3 || s1_class_count!=expected_s1_count || first_sample_due ||
           (SHARED_HP1_MODEL && filter_count!=N) ||
           s2_class_count!=end_count || arm_count<min_arms ||
           drain_count<min_drains ||
           classifier_clock_enabled)
            $fatal(1,"counts score=%0d s1=%0d s2=%0d ends=%0d arms=%0d",
                score_count,s1_class_count,s2_class_count,end_count,arm_count);
        $display("PASS: trigger-aligned replay, %0d Stage 1 scores, %0d Stage 2 scores, %0d starts, %0d arms, %0d drained results",
            score_count,s2_class_count,start_count,arm_count,drain_count);
        if (ADAPTIVE) $display("PASS: adaptive 500/100000 Hz, %0d samples preserved, %0d fast entries, %0d slow returns",
            dut.raw_sample_count,fast_entries,slow_returns);
        if (ADAPTIVE) $display("ACTIVITY: slow=%0d fast=%0d processing cycles; max wake=%0d ns",
            slow_ticks,fast_ticks,max_wake_ns);
        $finish;
    end
endmodule
