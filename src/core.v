module core (
    clock,
    reset,
    io_input_bus,
    io_output_bus
);


// -- Include definitions -------------------------------------
`include "riscv.h"              // Contains XLEN definition
`include "forwarding_codes.h"   // Contains forwarding codes


// -- Module IO -----------------------------------------------
input clock, reset;
input [10:0] io_input_bus;  // TODO
output [10:0] io_output_bus; // TODO


// Pipeline independent wires ---------------------------------
wire stale;
wire [8:0] pc_branch_address;
wire branch_enable;


// -- Instruction Fetch stage -----------------------------------------------------------------------------------------------
// Wire defs ------------------
wire [8:0] IF_pc_in;
reg [8:0] IF_pc_out;

// -- Dertermine pc in ----------------------------------------
assign IF_pc_in = (branch_enable) ? pc_branch_address : IF_pc_out + 4;

// -- Instruction memory --------------------------------------
reg [XLEN-1:0] IF_instruction;
instruction_memory INSTRUCTION_MEMORY(
    .address(IF_pc_in), // pc in instead of pc out because address has an input register
	.clock(clock),  
	.data(32'b0),       // Set to zero since write is never used
	.wren(0),           // Never write to instruction mem (is initialized)  
	.q(IF_instruction)       
);

// -- Program counter -----------------------------------------
// Needed since the signal after the input register of "INSTRUCTION_MEMORY" is inaccessible
register PC(
    .in(IF_pc_in),
    .write_enable(!stale),
    .out(IF_pc_out),
    .clock(clock),
    .reset(reset)
);


// -- Instruction Decode stage ----------------------------------------------------------------------------------------------
// Wire defs ------------------
wire [31:0] ID_instruction;
wire [8:0] ID_pc_out;

// -- Pipeline reg IF -> ID -----------------------------------
register #(31) IF_instruction_ID (
    .in(IF_instruction), 
    .write_enable(!stale), 
    .out(ID_instruction), 
    .clock(clock), 
    .reset(reset ||branch_enable)   // Flush IF registers when taking branch
);
register #(9) IF_pc_out_ID (
    .in(IF_pc_out), 
    .write_enable(!stale), 
    .out(ID_pc_out), 
    .clock(clock), 
    .reset(reset || branch_enable)  // Flush IF registers when taking branch
);

// -- Control -------------------------------------------------
reg ID_branch_inst, ID_branch_mode, ID_mem_write_enable, ID_reg_write_enable, ID_mem_to_reg, ID_alu_src, ID_ill_instr;   // Control outputs
reg [3:0] ID_alu_op;
control CONTROL(
    .instruction(ID_instruction),  
    .stale(stale), 
    .branch_enable(ID_branch_inst),   
    .branch_mode(ID_branch_mode), 
    .mem_write_enable(ID_mem_write_enable),   
    .reg_write_enable(ID_reg_write_enable),   
    .mem_to_reg(ID_mem_to_reg),         
    .alu_op(ID_alu_op),             
    .alu_src(ID_alu_src),          
    .ill_instr(ID_ill_instr)           
);

// -- Register file -------------------------------------------
reg [XLEN-1:0] ID_read_data_0, ID_read_data_1;
wire [XLEN-1:0] WB_reg_data_in;
wire WB_reg_write_enable;
register_file REGISTER_FILE(
    .read_reg_0(ID_instruction[19:15]),
    .read_reg_1(ID_instruction[24:20]),
    .write_reg(ID_instruction[11:7]),
    .write_data(WB_reg_data_in),
    .write_enable(WB_reg_write_enable),
    .read_data_0(ID_read_data_0),
    .read_data_1(ID_read_data_1),
    .clock(clock),
    .reset(reset)
);

// -- Branch comparison unit ----------------------------------
reg ID_branch_comp; 
branch_comparison_unit BRANCH_COMPARISON_UNIT(
    .in_0(ID_read_data_0),
    .in_1(ID_read_data_1),
    .mode(ID_branch_mode),
    .branch(ID_branch_comp)
);

// -- Immediate generator -------------------------------------
reg [XLEN-1:0] ID_immediate_out;
immediate_generator IMMEDIATE_GENERATOR(
    .instruction(ID_instruction),
    .immediate_out(ID_immediate_out)
);

// -- Calculate branch address --------------------------------
assign pc_branch_address = ID_immediate_out + ID_pc_out;

// -- Set branch enable ---------------------------------------
assign branch_enable = (ID_branch_inst && ID_branch_comp);


// -- Execution stage -------------------------------------------------------------------------------------------------------
// Wire defs ------------------
wire [31:0] EX_instruction;
wire [XLEN-1:0] EX_read_data_0, EX_read_data_1, EX_immediate_out;
wire EX_mem_write_enable, EX_reg_write_enable, EX_mem_to_reg, EX_alu_src;
wire [3:0] EX_alu_op;

// -- Pipeline reg ID -> EX -----------------------------------
register #(32) ID_instruction_EX (.in(EX_instruction), .write_enable('1), .out(ID_instruction), .clock(clock), .reset(reset));
register #(XLEN) ID_read_data_0_EX (.in(ID_read_data_0), .write_enable('1), .out(EX_read_data_0), .clock(clock), .reset(reset));
register #(XLEN) ID_read_data_1_EX (.in(ID_read_data_1), .write_enable('1), .out(EX_read_data_1), .clock(clock), .reset(reset));
register #(XLEN) ID_immediate_out_EX (.in(EX_immediate_out), .write_enable('1), .out(ID_immediate_out), .clock(clock), .reset(reset));
register #(1) ID_mem_write_enable_EX (.in(ID_mem_write_enable), .write_enable('1), .out(EX_mem_write_enable), .clock(clock), .reset(reset));
register #(1) ID_reg_write_enable_EX (.in(ID_reg_write_enable), .write_enable('1), .out(EX_reg_write_enable), .clock(clock), .reset(reset));
register #(1) ID_mem_to_reg_EX (.in(ID_mem_to_reg), .write_enable('1), .out(EX_mem_to_reg), .clock(clock), .reset(reset));
register #(1) ID_alu_src_EX (.in(ID_alu_src), .write_enable('1), .out(EX_alu_src), .clock(clock), .reset(reset));
register #(4) ID_alu_op_EX (.in(ID_alu_op), .write_enable('1), .out(EX_alu_op), .clock(clock), .reset(reset));

// -- Determine alu source ------------------------------------
reg [FORWARDING_CODE_SIZE-1:0] EX_forward_0, EX_forward_1;
reg [XLEN-1:0] EX_alu_in_0;
reg [XLEN-1:0] EX_alu_in_1;
wire [XLEN-1:0] MEM_alu_out;
always @(*) begin
    case (EX_forward_0)
        REG_FILE: EX_alu_in_0 <= EX_read_data_0;
        ALU_RESULT: EX_alu_in_0 <= MEM_alu_out;
        MEMORY: EX_alu_in_0 <= WB_reg_data_in;
        default: EX_alu_in_0 <= EX_read_data_0;
    endcase
    case (EX_forward_1)
        REG_FILE: EX_alu_in_1 <= EX_read_data_1;
        ALU_RESULT: EX_alu_in_1 <= MEM_alu_out;
        MEMORY: EX_alu_in_1 <= WB_reg_data_in;
        default: EX_alu_in_1 <= EX_read_data_1;
    endcase
end

// -- Arithmetic logic unit -----------------------------------
reg [XLEN-1:0] EX_alu_out;
alu ALU(
    .in_0(EX_alu_in_0),
    .in_1((EX_alu_src) ? EX_immediate_out : EX_alu_in_1),
    .operation(EX_alu_op),
    .out(EX_alu_out)
);


// -- Memory access stage ---------------------------------------------------------------------------------------------------
// Wire defs ------------------
wire [31:0] MEM_instruction;
wire [XLEN-1:0] MEM_mem_data;
wire MEM_mem_write_enable, MEM_reg_write_enable, MEM_mem_to_reg;

// -- Pipeline reg EX -> MEM ----------------------------------
register #(32) EX_instruction_MEM (.in(EX_instruction), .write_enable('1), .out(MEM_instruction), .clock(clock), .reset(reset));
register #(XLEN) EX_alu_out_MEM (.in(EX_alu_out), .write_enable('1), .out(MEM_alu_out), .clock(clock), .reset(reset));
register #(XLEN) EX_mem_data_MEM (.in(EX_alu_in_1), .write_enable('1), .out(MEM_mem_data), .clock(clock), .reset(reset));   // Alu in 1 -> mem data!
register #(1) EX_mem_write_enable_MEM (.in(EX_mem_write_enable), .write_enable('1), .out(MEM_mem_write_enable), .clock(clock), .reset(reset));
register #(1) EX_reg_write_enable_MEM (.in(EX_reg_write_enable), .write_enable('1), .out(MEM_reg_write_enable), .clock(clock), .reset(reset));
register #(1) EX_mem_to_reg_MEM (.in(EX_mem_to_reg), .write_enable('1), .out(MEM_mem_to_reg), .clock(clock), .reset(reset));


// -- Data memory ---------------------------------------------
reg MEM_data_mem_out;
data_memory DATA_MEMORY(
	.address(MEM_alu_out),
	.clock(clock),  
	.data(MEM_mem_data),
    .wren(MEM_mem_write_enable),
	.q(MEM_data_mem_out)
);


// -- Write back stage ------------------------------------------------------------------------------------------------------
// Wire defs ------------------
wire [31:0] WB_instruction;
wire WB_mem_to_reg;
wire [XLEN-1:0] WB_data_mem_out, WB_mem_data;

// -- Pipeline reg MEM -> WB ----------------------------------
register #(32) MEM_instruction_WB (.in(MEM_instruction), .write_enable('1), .out(WB_instruction), .clock(clock), .reset(reset));
register #(XLEN) MEM_data_mem_out_WB (.in(MEM_data_mem_out), .write_enable('1), .out(WB_data_mem_out), .clock(clock), .reset(reset));
register #(XLEN) MEM_mem_data_WB (.in(MEM_mem_data), .write_enable('1), .out(WB_mem_data), .clock(clock), .reset(reset));
register #(1) MEM_reg_write_enable_WB (.in(MEM_reg_write_enable), .write_enable('1), .out(WB_reg_write_enable), .clock(clock), .reset(reset));
register #(1) MEM_mem_to_reg_WB (.in(MEM_mem_to_reg), .write_enable('1), .out(WB_mem_to_reg), .clock(clock), .reset(reset));

// Determine registerfile data source ----------------------------------
assign WB_reg_data_in = (WB_mem_to_reg) ? WB_data_mem_out : WB_mem_data;


// -- Forwarding and hazard detection ---------------------------------------------------------------------------------------

// -- Forwarding unit -----------------------------------------
forwarding_unit FORWARDING_UNIT (
    .MEM_reg_write_enable(MEM_reg_write_enable),
    .WB_reg_write_enable(WB_reg_write_enable),
    .MEM_destination_register(MEM_instruction[11:7]),
    .WB_destination_register(WB_instruction[11:7]),
    .EX_read_register_0(EX_instruction[19:15]),
    .EX_read_register_1(EX_instruction[24:20]),
    .forward_0(EX_forward_0),
    .forward_1(EX_forward_1)
);

// -- Hazard detection unit -----------------------------------
hazard_detection_unit HAZARD_DETECTION_UNIT (
    .EX_mem_to_reg(EX_mem_to_reg),
    .EX_destination_register(EX_alu_out),
    .ID_read_register_0(ID_instruction[19:15]),
    .ID_read_register_1(ID_instruction[24:20]),
    .stale(stale)
);

endmodule