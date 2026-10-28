// Basys 3 adaptive-clock experiment. sw[15]=resetn, sw[14]=120 Hz demo.
// All acquisition timing remains on the 100 MHz board clock. btnC manual
// sampling is a bring-up aid only (not debounced). LEDs 15/14 show speed/arm.
module basys3_two_stage_adaptive_top #(
    parameter integer ADAPTIVE_CLOCK=1,
    parameter integer STAGE1_FULL_RATE=0
) (input wire clk,btnC,input wire [15:0] sw,output wire [15:0] led);
    wire processing_clk,clock_ready,fast_mode,fast_request;
    wire resetn=sw[15] && clock_ready;
    (* ASYNC_REG="TRUE" *) reg [1:0] source_ready;
    (* ASYNC_REG="TRUE" *) reg [1:0] button_sync,mode_sync;
    reg button_last;
    always @(posedge clk or negedge sw[15]) begin
        if (!sw[15]) begin
            source_ready<=0;button_sync<=0;mode_sync<=0;button_last<=0;
        end else begin
            source_ready<={source_ready[0],clock_ready};
            button_sync<={button_sync[0],btnC};
            mode_sync<={mode_sync[0],sw[14]};button_last<=button_sync[1];
        end
    end
    wire signed [11:0] demo_sample;
    wire demo_valid,demo_done;
    ecg_bram_demo_source #(.SAMPLE_WIDTH(12),.SAMPLE_COUNT(1200),
        .CLOCK_HZ(100000000),.SAMPLE_RATE_HZ(120),
        .MEMORY_FILE("synthetic_two_stage_demo_q3_8.mem")) demo (
        .clk(clk),.resetn(sw[15] && source_ready[1]),.enable(mode_sync[1]),
        .sample_out(demo_sample),.sample_valid(demo_valid),.playback_done(demo_done));
    wire input_valid=source_ready[1] && (mode_sync[1] ? demo_valid :
        button_sync[1] && !button_last);
    wire signed [11:0] input_sample=mode_sync[1] ? demo_sample : sw[11:0];
    wire signed [31:0] input_q16_16=$signed(input_sample)<<<8;
    wire input_ready,input_overflow,class_valid,class_is_stage2,mac_enabled;
    wire overflow1,overflow2,overflow_mac;
    wire [31:0] class_id;
    wire [1:0] class_code;
    two_stage_adaptive_clock_top #(.ADAPTIVE_CLOCK(ADAPTIVE_CLOCK),
        .STAGE1_FULL_RATE(STAGE1_FULL_RATE)) system_core (
        .source_clk(clk),.resetn(sw[15]),.sample_valid(input_valid),
        .sample_q16_16(input_q16_16),.sample_ready(input_ready),
        .input_overflow(input_overflow),.processing_clk(processing_clk),
        .clock_ready(clock_ready),.fast_mode(fast_mode),
        .processing_fast_request(fast_request),.class_valid(class_valid),
        .class_is_stage2(class_is_stage2),.classifier_clock_enabled(mac_enabled),
        .class_window_id(class_id),.class_code(class_code),
        .stage1_window_overflow(overflow1),.stage2_window_overflow(overflow2),
        .classifier_overflow(overflow_mac));
    reg [1:0] latest_class;
    reg latest_stage2,result_seen,overflow_seen;
    always @(posedge processing_clk or negedge resetn) begin
        if (!resetn) begin
            latest_class<=0;latest_stage2<=0;result_seen<=0;overflow_seen<=0;
        end else begin
            if (class_valid) begin
                latest_class<=class_code;latest_stage2<=class_is_stage2;
                result_seen<=1;
            end
            if (overflow1 || overflow2 || overflow_mac) overflow_seen<=1;
        end
    end
    assign led[0]=latest_class==0;assign led[1]=latest_class==1;
    assign led[2]=latest_class==2;assign led[3]=result_seen;
    assign led[4]=mac_enabled;assign led[5]=overflow_seen || input_overflow;
    assign led[6]=input_ready;assign led[7]=class_valid;
    assign led[8]=class_id[0];assign led[9]=clock_ready;
    assign led[10]=resetn;assign led[11]=mode_sync[1];
    assign led[12]=demo_done;assign led[13]=latest_stage2;
    assign led[14]=fast_request;assign led[15]=fast_mode;
endmodule
