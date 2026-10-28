// Basys 3 demonstration wrapper. sw[14]=BRAM playback, sw[15]=resetn.
// Manual mode uses sw[11:0] as Q3.8 and btnC as a sample strobe.
// The BRAM demo is only a bring-up source; production acquisition is external.
module basys3_two_stage_top #(
    parameter SHARED_HP1_MODEL=1,
    parameter DEEP_HISTORY=0,
    parameter CLOCK_GATING=1
) (
    input wire clk, btnC,
    input wire [15:0] sw,
    output wire [15:0] led
);
    localparam integer PROCESSING_CLOCK_HZ=
        SHARED_HP1_MODEL && !DEEP_HISTORY ? 100000 : 1000;
    wire clk_processing, clock_ready;
    wire resetn = sw[15] & clock_ready;
    ecg_clock_1khz #(.OUTPUT_HZ(PROCESSING_CLOCK_HZ)) low_power_clock (
        .clk_100mhz(clk),.external_resetn(sw[15]),
        .clk_1khz(clk_processing),.clock_ready(clock_ready)
    );
    reg button_0,button_1,button_2,mode_0,mode_1;
    always @(posedge clk_processing or negedge resetn) begin
        if (!resetn) begin
            button_0<=0;button_1<=0;button_2<=0;mode_0<=0;mode_1<=0;
        end else begin
            button_0<=btnC;button_1<=button_0;button_2<=button_1;
            mode_0<=sw[14];mode_1<=mode_0;
        end
    end
    wire signed [11:0] demo_sample;
    wire demo_valid,demo_done;
    ecg_bram_demo_source #(
        .SAMPLE_WIDTH(12),.SAMPLE_COUNT(1200),
        .CLOCK_HZ(PROCESSING_CLOCK_HZ),.SAMPLE_RATE_HZ(120),
        .MEMORY_FILE("synthetic_two_stage_demo_q3_8.mem")
    ) demo (
        .clk(clk_processing),.resetn(resetn),.enable(mode_1),
        .sample_out(demo_sample),.sample_valid(demo_valid),
        .playback_done(demo_done)
    );
    wire sample_valid = mode_1 ? demo_valid : (button_1 & ~button_2);
    wire signed [11:0] sample_q3_8 = mode_1 ? demo_sample : sw[11:0];
    wire signed [31:0] sample_q16_16 = $signed(sample_q3_8) <<< 8;
    wire class_valid,class_is_stage2,clock_enabled,overflow1,overflow2,overflow_classifier;
    wire [31:0] class_window_id;
    wire [1:0] class_code;
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(SHARED_HP1_MODEL),.DEEP_HISTORY(DEEP_HISTORY),
        .CLOCK_GATING(CLOCK_GATING)) pipeline (
        .clk(clk_processing),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.class_valid(class_valid),
        .class_window_id(class_window_id),.class_code(class_code),
        .class_is_stage2(class_is_stage2),
        .classifier_clock_enabled(clock_enabled),
        .stage1_window_overflow(overflow1),
        .stage2_window_overflow(overflow2),
        .classifier_overflow(overflow_classifier)
    );
    reg [1:0] latest_class;
    reg latest_is_stage2;
    reg result_seen, sample_seen, overflow_seen;
    reg [16:0] heartbeat;
    always @(posedge clk_processing or negedge resetn) begin
        if (!resetn) begin
            latest_class<=0;latest_is_stage2<=0;
            result_seen<=0;sample_seen<=0;
            overflow_seen<=0;heartbeat<=0;
        end else begin
            heartbeat<=heartbeat+1'b1;
            if(sample_valid) sample_seen<=1;
            if(class_valid) begin
                latest_class<=class_code;
                latest_is_stage2<=class_is_stage2;
                result_seen<=1;
            end
            if(overflow1 || overflow2 || overflow_classifier) overflow_seen<=1;
        end
    end
    assign led[0]=latest_class==2'd0;
    assign led[1]=latest_class==2'd1;
    assign led[2]=latest_class==2'd2;
    assign led[3]=result_seen;
    assign led[4]=clock_enabled;
    assign led[5]=overflow_seen;
    assign led[6]=sample_seen;
    assign led[7]=class_valid;
    assign led[8]=class_window_id[0];
    assign led[9]=clock_ready;
    assign led[10]=resetn;
    assign led[11]=mode_1;
    assign led[12]=demo_done;
    assign led[13]=latest_class==2'd3;
    assign led[14]=latest_is_stage2;
    assign led[15]=PROCESSING_CLOCK_HZ==100000 ? heartbeat[16] : heartbeat[9];
endmodule
