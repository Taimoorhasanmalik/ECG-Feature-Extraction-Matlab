// Bundled-data toggle handshake. Source holds data until acknowledgement;
// only the request/acknowledgement cross through synchronizers. One sample
// slot is sufficient for periodic 120 Hz input with a >=500 Hz consumer.
// Source must respect sample_ready; an unaccepted strobe sets overflow.
module ecg_sample_mailbox (
    input wire source_clk, processing_clk, resetn,
    input wire sample_valid,
    input wire signed [31:0] sample_data,
    output wire sample_ready,
    output reg overflow,
    output reg processing_valid,
    output reg signed [31:0] processing_data
);
    reg [31:0] held_data;
    reg request_toggle,ack_toggle;
    (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,request_sync;
    (* ASYNC_REG="TRUE" *) reg [1:0] source_init;
    always @(posedge source_clk or negedge resetn)
        if (!resetn) source_init<=0;
        else source_init<={source_init[0],1'b1};
    wire source_resetn=source_init[1];
    assign sample_ready=source_resetn && request_toggle==ack_sync[1];
    always @(posedge source_clk or negedge source_resetn) begin
        if (!source_resetn) begin
            held_data<=0;request_toggle<=0;ack_sync<=0;overflow<=0;
        end else begin
            ack_sync<={ack_sync[0],ack_toggle};
            if (sample_valid) begin
                if (sample_ready) begin
                    held_data<=sample_data;request_toggle<=~request_toggle;
                end else overflow<=1;
            end
        end
    end
    always @(posedge processing_clk or negedge resetn) begin
        if (!resetn) begin
            request_sync<=0;ack_toggle<=0;
            processing_valid<=0;processing_data<=0;
        end else begin
            request_sync<={request_sync[0],request_toggle};
            processing_valid<=0;
            if (request_sync[1]!=ack_toggle) begin
                processing_data<=held_data;
                processing_valid<=1;
                ack_toggle<=request_sync[1];
            end
        end
    end
endmodule
