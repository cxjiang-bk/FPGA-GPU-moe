// AXI-Lite control in the core clock domain; the platform performs control CDC.
module v80_control #(
  parameter logic [31:0] ARCH_HASH = 0,
  parameter logic [31:0] PLATFORM_ID = 32'h56383001,
  parameter int MAX_INSTRUCTIONS = 1024
) (
  input logic clk, rst,
  input logic [11:0] s_axi_awaddr, s_axi_araddr,
  input logic s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready,
  input logic [31:0] s_axi_wdata,
  input logic [3:0] s_axi_wstrb,
  output logic s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid,
  output logic [1:0] s_axi_bresp, s_axi_rresp,
  output logic [31:0] s_axi_rdata,
  output logic core_reset, ld_start, clear_bridge_error,
  output logic [31:0] ld_addr, ld_n,
  output logic [31:0] rinit [8],
  input logic ld_busy, halted, core_error, quiescent,
  input logic [31:0] bridge_error, icount,
  input logic [63:0] read_bytes, write_bytes
);
  import v80_regs_pkg::*;
  typedef enum logic [2:0] {IDLE, LOAD, WAIT_BUSY, WAIT_LOAD, EXECUTE, DRAIN} state_t;
  state_t state;
  logic aw_pending, w_pending, done;
  logic [11:0] aw_address;
  logic [31:0] w_data, program_address, program_count, timeout_cycles, arg [8];
  logic [3:0] w_mask;
  logic [31:0] command_pulse, error, epoch, task_epoch, done_epoch, done_icount;
  logic [63:0] task_id, running_id, done_id, total_cycles, exec_cycles;
  wire busy = state != IDLE;
  wire [31:0] effective_error = error != 0 ? error : bridge_error;
  logic [31:0] command_value;
  logic [32:0] program_end;
  assign s_axi_awready = !rst && !aw_pending && !s_axi_bvalid;
  assign s_axi_wready = !rst && !w_pending && !s_axi_bvalid;
  assign s_axi_arready = !rst && !s_axi_rvalid;
  assign program_end = 33'(program_address) + ((33'(program_count)*32 + 127) & 33'h1ffffff80);

  function automatic logic [31:0] merge_bytes(input logic [31:0] old_value,
                                               input logic [31:0] value,
                                               input logic [3:0] mask);
    logic [31:0] out;
    out = old_value;
    for (int i = 0; i < 4; i++) if (mask[i]) out[8*i +: 8] = value[8*i +: 8];
    return out;
  endfunction
  always_comb command_value = merge_bytes(0, w_data, w_mask);

  function automatic logic [31:0] read_register(input logic [11:0] address);
    case (32'(address))
      REG_ID: return DEVICE_ID;
      REG_ABI: return ABI_VERSION;
      REG_CFG_HASH: return ARCH_HASH;
      REG_PLATFORM: return PLATFORM_ID;
      REG_STATUS: return 32'(busy) | (32'(done) << 1) | (32'(effective_error != 0) << 2);
      REG_DONE_ID_LO: return done_id[31:0];
      REG_DONE_ID_HI: return done_id[63:32];
      REG_EPOCH: return epoch;
      REG_TASK_ID_LO: return task_id[31:0];
      REG_TASK_ID_HI: return task_id[63:32];
      REG_PROGRAM_ADDR: return program_address;
      REG_PROGRAM_COUNT: return program_count;
      REG_TIMEOUT_CYCLES: return timeout_cycles;
      REG_ERROR: return effective_error;
      REG_TOTAL_CYCLES_LO: return total_cycles[31:0];
      REG_TOTAL_CYCLES_HI: return total_cycles[63:32];
      REG_READ_BYTES_LO: return read_bytes[31:0];
      REG_READ_BYTES_HI: return read_bytes[63:32];
      REG_WRITE_BYTES_LO: return write_bytes[31:0];
      REG_WRITE_BYTES_HI: return write_bytes[63:32];
      REG_ICOUNT: return busy ? icount : done_icount;
      REG_DONE_EPOCH: return done_epoch;
      REG_EXEC_CYCLES_LO: return exec_cycles[31:0];
      REG_EXEC_CYCLES_HI: return exec_cycles[63:32];
      default: if (address >= REG_ARG0 && address <= REG_ARG7) return arg[(address-REG_ARG0)/4];
    endcase
    return 0;
  endfunction

  // AW and W can arrive in either order. Hold B/R until the master accepts them.
  always_ff @(posedge clk) begin
    if (rst) begin
      aw_pending <= 0; w_pending <= 0; s_axi_bvalid <= 0; s_axi_rvalid <= 0;
      s_axi_bresp <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0; command_pulse <= 0;
      program_address <= 0; program_count <= 0; timeout_cycles <= 10000000; task_id <= 0;
      for (int i = 0; i < 8; i++) arg[i] <= 0;
    end else begin
      command_pulse <= 0;
      if (s_axi_awvalid && s_axi_awready) begin aw_pending <= 1; aw_address <= s_axi_awaddr; end
      if (s_axi_wvalid && s_axi_wready) begin w_pending <= 1; w_data <= s_axi_wdata; w_mask <= s_axi_wstrb; end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
      if (aw_pending && w_pending && !s_axi_bvalid) begin
        aw_pending <= 0; w_pending <= 0; s_axi_bvalid <= 1; s_axi_bresp <= 0;
        if (aw_address[1:0] != 0 || (busy && aw_address != REG_COMMAND)) s_axi_bresp <= 2;
        else case (32'(aw_address))
          REG_TASK_ID_LO: task_id[31:0] <= merge_bytes(task_id[31:0], w_data, w_mask);
          REG_TASK_ID_HI: task_id[63:32] <= merge_bytes(task_id[63:32], w_data, w_mask);
          REG_PROGRAM_ADDR: program_address <= merge_bytes(program_address, w_data, w_mask);
          REG_PROGRAM_COUNT: program_count <= merge_bytes(program_count, w_data, w_mask);
          REG_TIMEOUT_CYCLES: timeout_cycles <= merge_bytes(timeout_cycles, w_data, w_mask);
          REG_COMMAND: begin
            case (command_value)
              0: begin end
              CMD_RUN: if (busy || !quiescent || effective_error != 0 ||
                           program_count == 0 || program_count > MAX_INSTRUCTIONS ||
                           program_address[6:0] != 0 || program_end > 33'h100000000)
                         s_axi_bresp <= 2;
                       else command_pulse <= CMD_RUN;
              CMD_ABORT: if (!busy || state == DRAIN) s_axi_bresp <= 2;
                         else command_pulse <= CMD_ABORT;
              CMD_CLEAR, CMD_RESET: if (busy || !quiescent) s_axi_bresp <= 2;
                                    else command_pulse <= command_value;
              default: s_axi_bresp <= 2;
            endcase
          end
          default: if (aw_address >= REG_ARG0 && aw_address <= REG_ARG7)
                     arg[(aw_address-REG_ARG0)/4] <= merge_bytes(arg[(aw_address-REG_ARG0)/4], w_data, w_mask);
                   else s_axi_bresp <= 2;
        endcase
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid <= 1;
        s_axi_rdata <= read_register(s_axi_araddr);
        s_axi_rresp <= s_axi_araddr[1:0] != 0 ? 2 : 0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE; core_reset <= 1; ld_start <= 0; clear_bridge_error <= 0;
      ld_addr <= 0; ld_n <= 0; error <= 0; epoch <= 0; task_epoch <= 0;
      done <= 0; running_id <= 0; done_id <= 0; done_epoch <= 0; done_icount <= 0;
      total_cycles <= 0; exec_cycles <= 0;
      for (int i = 0; i < 8; i++) rinit[i] <= 0;
    end else begin
      ld_start <= 0; clear_bridge_error <= 0;
      if (busy) total_cycles <= total_cycles + 1;
      if (state == EXECUTE) exec_cycles <= exec_cycles + 1;
      if (command_pulse == CMD_CLEAR || command_pulse == CMD_RESET) begin
        done <= 0; error <= 0; clear_bridge_error <= 1;
        if (command_pulse == CMD_RESET) begin epoch <= epoch + 1; core_reset <= 1; end
      end
      if (command_pulse == CMD_RUN) begin
        running_id <= task_id; task_epoch <= epoch; done <= 0; error <= 0;
        total_cycles <= 0; exec_cycles <= 0;
        ld_addr <= program_address; ld_n <= program_count;
        for (int i = 0; i < 8; i++) rinit[i] <= arg[i];
        core_reset <= 1; state <= LOAD;
      end else if (busy && state != DRAIN &&
                   (command_pulse == CMD_ABORT || bridge_error != 0 || core_error ||
                    (timeout_cycles != 0 && total_cycles >= timeout_cycles))) begin
        core_reset <= 1; state <= DRAIN; epoch <= epoch + 1;
        error <= command_pulse == CMD_ABORT ? ERR_ABORT : bridge_error != 0 ? bridge_error :
                 core_error ? ERR_CORE : ERR_TIMEOUT;
      end else case (state)
        LOAD: begin ld_start <= 1; state <= WAIT_BUSY; end
        WAIT_BUSY: if (ld_busy) state <= WAIT_LOAD;
        WAIT_LOAD: if (!ld_busy) begin core_reset <= 0; state <= EXECUTE; end
        EXECUTE: if (halted && quiescent) begin
          done_icount <= icount;
          done <= 1; done_id <= running_id; done_epoch <= task_epoch;
          state <= IDLE; core_reset <= 1;
        end
        DRAIN: if (quiescent && !ld_busy) begin
          done_icount <= icount;
          done <= 1; done_id <= running_id; done_epoch <= task_epoch; state <= IDLE;
        end
        default: begin end
      endcase
    end
  end
endmodule
