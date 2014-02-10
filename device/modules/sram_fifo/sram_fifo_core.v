/**
 * ------------------------------------------------------------
 * Copyright (c) SILAB , Physics Institute of Bonn University 
 * ------------------------------------------------------------
 *
 * SVN revision information:
 *  $Rev::                       $:
 *  $Author::                    $: 
 *  $Date::                      $:
 */
 
module sram_fifo_core
#(
    parameter                   DEPTH = 21'h10_0000,
    parameter                   FIFO_ALMOST_FULL_THRESHOLD = 95, // in percent
    parameter                   FIFO_ALMOST_EMPTY_THRESHOLD = 5 // in percent
) (
    input wire                  BUS_CLK,
//    input wire                  BUS_CLK270,
    input wire                  BUS_RST,
    input wire [15:0]           BUS_ADD,
    input wire [7:0]            BUS_DATA_IN,
    input wire                  BUS_RD,
    input wire                  BUS_WR,
    output reg [7:0]            BUS_DATA_OUT,
    
    output wire [19:0]          SRAM_A,
    inout wire [15:0]           SRAM_IO,
    output wire                 SRAM_BHE_B,
    output wire                 SRAM_BLE_B,
    output wire                 SRAM_CE1_B,
    output wire                 SRAM_OE_B,
    output wire                 SRAM_WE_B,
    
    input wire                  USB_READ,
    output wire [7:0]           USB_DATA,
    
    output reg                  FIFO_READ_NEXT_OUT,
    input wire                  FIFO_EMPTY_IN,
    input wire [31:0]           FIFO_DATA,
    
    output wire                 FIFO_NOT_EMPTY,
    output wire                 FIFO_FULL,
    output reg                  FIFO_NEAR_FULL,
    output wire                 FIFO_READ_ERROR
);

parameter OUT_LINES = 1;

/////
wire SOFT_RST; //0
assign SOFT_RST = (BUS_ADD==0 && BUS_WR);  

wire RST;
assign RST = BUS_RST | SOFT_RST;

reg [7:0] status_regs[7:0];

// reg 0 for SOFT_RST
wire [7:0] FIFO_ALMOST_FULL_VALUE;
assign FIFO_ALMOST_FULL_VALUE = status_regs[1];
wire [7:0] FIFO_ALMOST_EMPTY_VALUE;
assign FIFO_ALMOST_EMPTY_VALUE = status_regs[2];

always @(posedge BUS_CLK)
begin
    if(RST)
    begin
        status_regs[0] <= 0;
        status_regs[1] <= 255*FIFO_ALMOST_FULL_THRESHOLD/100;
        status_regs[2] <= 255*FIFO_ALMOST_EMPTY_THRESHOLD/100;
        status_regs[3] <= 8'b0;
        status_regs[4] <= 8'b0;
        status_regs[5] <= 8'b0;
        status_regs[6] <= 8'b0;
        status_regs[7] <= 8'b0;
    end
    else if(BUS_WR && BUS_ADD < 8)
    begin
        status_regs[BUS_ADD[2:0]] <= BUS_DATA_IN;
    end
end

// read reg
reg [20:0] CONF_SIZE; // write data count, 1 - 2 - 3
reg [7:0] CONF_READ_ERROR; // read error count (read attempts when FIFO is empty), 4

always @ (negedge BUS_CLK) begin //(*) begin
    if(BUS_RD) begin
        if(BUS_ADD == 1)
            BUS_DATA_OUT <= {3'b000, CONF_SIZE[20:16]};
        else if(BUS_ADD == 2)
            BUS_DATA_OUT <= CONF_SIZE[15:8];
        else if(BUS_ADD == 3)
            BUS_DATA_OUT <= CONF_SIZE[7:0]; 
        else if(BUS_ADD == 4)
            BUS_DATA_OUT <= CONF_READ_ERROR;
    end
end


wire empty, full;
reg [19:0] rd_ponter, next_rd_ponter, wr_pointer, next_wr_pointer;

reg usb_read_dly;
always@(posedge BUS_CLK)
    usb_read_dly <= USB_READ;
    
wire read_sram;

reg byte_to_read;
always@(posedge BUS_CLK)
    if(RST)
        byte_to_read <= 0;
    else if(read_sram)
        byte_to_read <= 0;
    else if(usb_read_dly)
        byte_to_read <= !byte_to_read;
    
localparam READ_TRY_SRAM = 3, READ_SRAM = 0,  READ_NOP_SRAM = 2;
reg [1:0] read_state, read_state_next;
always@(posedge BUS_CLK)
    if(RST)
        read_state <= READ_TRY_SRAM;
    else
        read_state <= read_state_next;

always@(*) begin
    read_state_next = read_state;
    
    case(read_state)
        READ_TRY_SRAM: 
            if(!empty)
                read_state_next = READ_SRAM;
        READ_SRAM:
            if(empty)
                read_state_next = READ_TRY_SRAM;
            else
                read_state_next = READ_NOP_SRAM;
        READ_NOP_SRAM:
            if(empty)
                read_state_next = READ_TRY_SRAM;
            else if(USB_READ && byte_to_read == 1 && !empty)
                read_state_next = READ_SRAM;
        default : read_state_next = READ_TRY_SRAM;
    endcase
end

reg [15:0] sram_data_read;

assign read_sram = (read_state == READ_SRAM);

always@(posedge BUS_CLK)
    if(read_sram)
        sram_data_read <= SRAM_IO;

assign USB_DATA = byte_to_read ?  sram_data_read[7:0] : sram_data_read[15:8] ;

always@(posedge BUS_CLK) begin
    if(RST)
        CONF_READ_ERROR <= 0;
    else if(empty && USB_READ && CONF_READ_ERROR != 8'hff)
        CONF_READ_ERROR <= CONF_READ_ERROR +1;
end      


reg write_sram;
reg full_ff;

always @ (*) begin
   if(!FIFO_EMPTY_IN && !full_ff && !read_sram)
       write_sram = 1;
   else
       write_sram = 0;
       
    if(!FIFO_EMPTY_IN && !full && !read_sram && wr_pointer[0]==1)
       FIFO_READ_NEXT_OUT = 1;
    else
       FIFO_READ_NEXT_OUT = 0;
end

wire [15:0] DATA_TO_SRAM;
assign DATA_TO_SRAM = wr_pointer[0]==0 ? FIFO_DATA[31:16] : FIFO_DATA[15:0];

//CG_MOD_neg icg(.ck_in(BUS_CLK270), .enable(write_sram), .ck_out(SRAM_WE_B));

OFDDRRSE WE_INST (
	.CE(1'b1), 
    .C0(~BUS_CLK),
	.C1(BUS_CLK),
	//.C0(~BUS_CLK270),
	//.C1(BUS_CLK270),
	.D0(~write_sram),
	.D1(1'b1),
	.R(1'b0),
	.S(1'b0),
	.Q(SRAM_WE_B)
);


assign SRAM_IO = write_sram ? DATA_TO_SRAM : 16'hzzzz ;
assign SRAM_A = (read_sram) ? rd_ponter : wr_pointer;
assign SRAM_BHE_B = 0;
assign SRAM_BLE_B = 0;
assign SRAM_CE1_B = 0;
assign SRAM_OE_B = !read_sram;

always @ (*) begin
     if(rd_ponter == DEPTH-1)
        next_rd_ponter = 0;
     else
        next_rd_ponter = rd_ponter + 1;
end

always@(posedge BUS_CLK) begin
    if(RST)
        rd_ponter <= 0;
    else if(read_sram && !empty) begin
        rd_ponter <= next_rd_ponter;
    end
end

always @ (*) begin
    if(wr_pointer == DEPTH-1)
        next_wr_pointer = 0;
    else
        next_wr_pointer = wr_pointer + 1;
end

always@(posedge BUS_CLK) begin
    if(RST)
        wr_pointer <= 0;
    else if(write_sram && !full) begin
        wr_pointer <= next_wr_pointer;
    end
end

assign empty = (wr_pointer == rd_ponter);
assign full = ((wr_pointer==(DEPTH-1) && rd_ponter==0) ||  (wr_pointer!=(DEPTH-1) && wr_pointer+1 == rd_ponter) ); 

always@(posedge BUS_CLK) begin
    if(RST)
        full_ff <= 0;
    else if(read_sram && !empty)
        full_ff <= ((wr_pointer==(DEPTH-1) && next_rd_ponter==0) ||  (wr_pointer!=(DEPTH-1) && wr_pointer+1 == next_rd_ponter) );
    else if(write_sram && !full)
        full_ff <= ((next_wr_pointer==(DEPTH-1) && rd_ponter==0) ||  (next_wr_pointer!=(DEPTH-1) && next_wr_pointer+1 == rd_ponter) );
end


always @ (posedge BUS_CLK) begin //(*) begin
    if(wr_pointer >= rd_ponter)
        if(read_state == READ_NOP_SRAM)
            CONF_SIZE <= wr_pointer - rd_ponter+1;
        else
            CONF_SIZE <= wr_pointer - rd_ponter;
    else
        CONF_SIZE <= wr_pointer + (DEPTH-rd_ponter);
end

assign FIFO_NOT_EMPTY = !empty;
assign FIFO_FULL = full;
assign FIFO_READ_ERROR = (CONF_READ_ERROR != 0);

always @(posedge BUS_CLK) begin
    if(RST)
        FIFO_NEAR_FULL <= 1'b0;
    else if (((((FIFO_ALMOST_FULL_VALUE+1)*DEPTH)>>8) <= CONF_SIZE) || (FIFO_ALMOST_FULL_VALUE == 8'b0 && CONF_SIZE >= 0))
        FIFO_NEAR_FULL <= 1'b1;
    else if (((((FIFO_ALMOST_EMPTY_VALUE+1)*DEPTH)>>8) >= CONF_SIZE && FIFO_ALMOST_EMPTY_VALUE != 8'b0) || CONF_SIZE == 21'b0)
        FIFO_NEAR_FULL <= 1'b0;
end

endmodule
