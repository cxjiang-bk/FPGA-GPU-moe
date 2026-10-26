module tb_v80_core;
  timeunit 1ns; timeprecision 1ps;
  import v80_regs_pkg::*;
  import v80_config_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = !clk;
  logic [11:0] s_axi_awaddr = 0, s_axi_araddr = 0;
  logic s_axi_awvalid = 0, s_axi_wvalid = 0, s_axi_bready = 0, s_axi_arvalid = 0, s_axi_rready = 0;
  logic [31:0] s_axi_wdata = 0;
  logic [3:0] s_axi_wstrb = 15;
  wire s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
  wire [1:0] s_axi_bresp, s_axi_rresp;
  wire [31:0] s_axi_rdata;
  wire [31:0] m_axi_awaddr, m_axi_araddr;
  wire [7:0] m_axi_awlen, m_axi_arlen;
  wire [2:0] m_axi_awsize, m_axi_arsize;
  wire [1:0] m_axi_awburst, m_axi_arburst, m_axi_bresp, m_axi_rresp;
  wire m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
  wire m_axi_bvalid, m_axi_bready, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  wire [1023:0] m_axi_wdata, m_axi_rdata;
  wire [127:0] m_axi_wstrb;
  logic allow_r = 1, allow_b = 1;
  logic [1:0] inject_rresp = 0;
  wire [31:0] last_araddr;
  int read_transactions, write_transactions;
  int program_address, program_count, output_address, output_bytes, image_bytes;
  int fd, loaded, checks = 0;
  logic [31:0] value, before_epoch;
  string golden_path, dump_path;
  byte unsigned golden [8192];
  v80_opentpu_core dut (.*);
  axi_memory_model memory (
    .clk, .rst, .allow_r, .allow_b, .inject_rresp, .inject_bresp(2'b0), .inject_extra_read(1'b0),
    .awaddr(m_axi_awaddr), .araddr(m_axi_araddr), .awlen(m_axi_awlen), .arlen(m_axi_arlen),
    .awsize(m_axi_awsize), .arsize(m_axi_arsize), .awburst(m_axi_awburst), .arburst(m_axi_arburst),
    .awvalid(m_axi_awvalid), .wlast(m_axi_wlast), .wvalid(m_axi_wvalid), .bready(m_axi_bready),
    .arvalid(m_axi_arvalid), .rready(m_axi_rready), .wdata(m_axi_wdata), .wstrb(m_axi_wstrb),
    .awready(m_axi_awready), .wready(m_axi_wready), .bvalid(m_axi_bvalid),
    .arready(m_axi_arready), .rlast(m_axi_rlast), .rvalid(m_axi_rvalid),
    .bresp(m_axi_bresp), .rresp(m_axi_rresp), .rdata(m_axi_rdata),
    .last_araddr, .read_transactions, .write_transactions);

  assert property (@(posedge clk) disable iff(rst)
    s_axi_rvalid && !s_axi_rready |=> s_axi_rvalid && $stable({s_axi_rdata,s_axi_rresp}));
  assert property (@(posedge clk) disable iff(rst)
    s_axi_bvalid && !s_axi_bready |=> s_axi_bvalid && $stable(s_axi_bresp));

  task automatic write_reg(input int address, input logic [31:0] data_,
                           input logic [1:0] response = 0, input bit w_first = 0,
                           input logic [3:0] mask = 15);
    @(negedge clk); s_axi_wdata = data_; s_axi_wstrb = mask; s_axi_awaddr = 12'(address);
    if (w_first) begin
      s_axi_wvalid = 1; do @(posedge clk); while (!s_axi_wready);
      @(negedge clk); s_axi_wvalid = 0;
      repeat (2) @(negedge clk);
      s_axi_awvalid = 1; do @(posedge clk); while (!s_axi_awready);
      @(negedge clk); s_axi_awvalid = 0;
    end else begin
      s_axi_awvalid = 1; do @(posedge clk); while (!s_axi_awready);
      @(negedge clk); s_axi_awvalid = 0;
      repeat (2) @(negedge clk);
      s_axi_wvalid = 1; do @(posedge clk); while (!s_axi_wready);
      @(negedge clk); s_axi_wvalid = 0;
    end
    while (!s_axi_bvalid) @(negedge clk);
    if (s_axi_bresp != response) $fatal(1, "write %h resp=%0d expected=%0d", address, s_axi_bresp, response);
    repeat (2) @(negedge clk);
    s_axi_bready = 1; @(negedge clk); s_axi_bready = 0;
  endtask
  task automatic read_reg(input int address, output logic [31:0] data_);
    @(negedge clk); s_axi_araddr = 12'(address); s_axi_arvalid = 1;
    do @(posedge clk); while (!s_axi_arready);
    @(negedge clk); s_axi_arvalid = 0;
    while (!s_axi_rvalid) @(negedge clk);
    if (s_axi_rresp != 0) $fatal(1, "read %h failed", address);
    data_ = s_axi_rdata;
    repeat (2) @(negedge clk);
    s_axi_rready = 1; @(negedge clk); s_axi_rready = 0;
  endtask
  task automatic wait_done(input int id_, input int error_ = 0);
    do read_reg(REG_STATUS, value); while (!(value & STATUS_DONE));
    if (value & STATUS_BUSY) $fatal(1, "DONE while busy");
    read_reg(REG_ERROR, value);
    if (value != error_) $fatal(1, "task %0d error=%h expected=%h", id_, value, error_);
    read_reg(REG_DONE_ID_LO, value);
    if (value != id_) $fatal(1, "stale completion ID");
    checks++;
  endtask
  task automatic check_output;
    for (int i = 0; i < output_bytes; i++)
      if (memory.mem[output_address+i] !== golden[i])
        $fatal(1, "output mismatch byte=%0d got=%h expected=%h", i, memory.mem[output_address+i], golden[i]);
    checks++;
  endtask
  task automatic start_task(input int id_);
    write_reg(REG_COMMAND, CMD_CLEAR);
    write_reg(REG_TASK_ID_LO, 32'(id_), 0, 1);
    write_reg(REG_COMMAND, CMD_RUN);
  endtask

  initial begin
    if (!$value$plusargs("program_address=%d", program_address) ||
        !$value$plusargs("program_count=%d", program_count) ||
        !$value$plusargs("output_address=%d", output_address) ||
        !$value$plusargs("output_bytes=%d", output_bytes) ||
        !$value$plusargs("image_bytes=%d", image_bytes) ||
        !$value$plusargs("golden=%s", golden_path) || !$value$plusargs("dump=%s", dump_path))
      $fatal(1, "missing case arguments");
    if (output_bytes > 8192) $fatal(1, "golden too large");
    fd = $fopen(golden_path, "rb"); loaded = $fread(golden, fd); $fclose(fd);
    if (loaded != output_bytes) $fatal(1, "golden length mismatch");
    repeat (8) @(negedge clk); rst = 0;
    read_reg(REG_ID, value); if (value != DEVICE_ID) $fatal(1, "identity mismatch");
    read_reg(REG_CFG_HASH, value); if (value != CFG_ARCH_HASH) $fatal(1, "config mismatch");
    write_reg(REG_ID, 0, 2);
    write_reg(REG_COMMAND, CMD_RUN, 2); // zero instruction count
    write_reg(REG_PROGRAM_ADDR, 32'(program_address+4));
    write_reg(REG_PROGRAM_COUNT, 32'(program_count), 0, 1);
    write_reg(REG_COMMAND, CMD_RUN, 2); // misaligned program
    write_reg(REG_PROGRAM_ADDR, 32'(program_address));
    write_reg(REG_TASK_ID_HI, 'h12345678);
    write_reg(REG_TASK_ID_HI, 'habcdef01, 0, 1, 3);
    read_reg(REG_TASK_ID_HI, value); if (value != 'h1234ef01) $fatal(1, "WSTRB ignored");
    for (int run = 1; run <= 3; run++) begin
      for (int i = 0; i < output_bytes; i++) memory.mem[output_address+i] = 'ha5;
      allow_b = 0; start_task(run);
      write_reg(REG_ARG0, 32'hffffffff, 2); // busy configuration is immutable
      while (!(memory.have_aw && memory.have_w)) @(negedge clk);
      repeat (20) @(negedge clk);
      read_reg(REG_STATUS, value);
      if (!(value & STATUS_BUSY) || (value & STATUS_DONE)) $fatal(1, "completion before AXI B response");
      allow_b = 1; wait_done(run); check_output();
      read_reg(REG_ICOUNT, value); if (value != program_count) $fatal(1, "instruction count mismatch");
      read_reg(REG_EXEC_CYCLES_LO, value);
      $display("CORE_RUN id=%0d exec_cycles=%0d", run, value);
    end
    read_reg(REG_EPOCH, before_epoch);
    allow_r = 0; start_task(4); repeat (40) @(negedge clk);
    write_reg(REG_COMMAND, CMD_ABORT);
    repeat (20) @(negedge clk);
    read_reg(REG_STATUS, value);
    if (!(value & STATUS_BUSY) || !(value & STATUS_ERROR)) $fatal(1, "abort discarded outstanding read");
    allow_r = 1; wait_done(4, ERR_ABORT);
    read_reg(REG_DONE_EPOCH, value); if (value != before_epoch) $fatal(1, "wrong task epoch");
    read_reg(REG_EPOCH, value); if (value != before_epoch+1) $fatal(1, "epoch did not advance");
    write_reg(REG_COMMAND, CMD_CLEAR);
    write_reg(REG_TIMEOUT_CYCLES, 40);
    allow_r = 0; start_task(5); repeat (150) @(negedge clk);
    read_reg(REG_ERROR, value); if (value != ERR_TIMEOUT) $fatal(1, "timeout not reported");
    allow_r = 1; wait_done(5, ERR_TIMEOUT);
    write_reg(REG_COMMAND, CMD_CLEAR); write_reg(REG_TIMEOUT_CYCLES, 10000000);
    inject_rresp = 2; start_task(6); wait_done(6, 2); inject_rresp = 0;
    start_task(7); wait_done(7); check_output();
    fd = $fopen(dump_path, "wb");
    for (int i = 0; i < image_bytes; i++) $fwrite(fd, "%c", memory.mem[i]);
    $fclose(fd);
    $display("CORE_PASS checks=%0d reads=%0d writes=%0d", checks, read_transactions, write_transactions);
    $finish;
  end
  initial begin #50000000; $fatal(1, "core integration timeout"); end
endmodule
