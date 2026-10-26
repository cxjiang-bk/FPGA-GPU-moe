module tb_mem_axi;
  timeunit 1ns; timeprecision 1ps;
  logic clk = 0, rst = 1, clear_error = 0;
  always #5 clk = !clk;
  logic a_req = 0, a_we = 0, b_req = 0, b_we = 0, b_tag = 0, sw_req = 0;
  logic [31:0] a_addr = 0, a_wdata = 0, b_addr = 0, sw_addr = 0, sw_wdata = 0;
  logic [3:0] a_be = 0, sw_be = 0;
  logic [31:0] b_wmask = 0;
  logic [1023:0] b_wdata = 0;
  wire a_rdy, a_rvalid, b_rdy, b_rvalid, b_rtag, sw_rdy, rd_idle, wr_idle;
  wire [255:0] a_rdata;
  wire [1023:0] b_rdata;
  wire [31:0] error_code;
  wire [63:0] read_bytes, write_bytes;
  wire [31:0] m_axi_awaddr, m_axi_araddr;
  wire [7:0] m_axi_awlen, m_axi_arlen;
  wire [2:0] m_axi_awsize, m_axi_arsize;
  wire [1:0] m_axi_awburst, m_axi_arburst, m_axi_bresp, m_axi_rresp;
  wire m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
  wire m_axi_bvalid, m_axi_bready, m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
  wire [1023:0] m_axi_wdata, m_axi_rdata;
  wire [127:0] m_axi_wstrb;
  logic allow_r = 1, allow_b = 1, inject_extra_read = 0;
  logic [1:0] inject_rresp = 0, inject_bresp = 0;
  wire [31:0] last_araddr;
  int read_transactions, write_transactions;
  byte unsigned expected [65536];
  int checks = 0;
  otpu_mem_axi dut (.*);
  axi_memory_model #(.MEM_BYTES(65536), .WRAP_ADDRESS(1)) memory (
    .clk, .rst, .allow_r, .allow_b, .inject_rresp, .inject_bresp, .inject_extra_read,
    .awaddr(m_axi_awaddr), .araddr(m_axi_araddr), .awlen(m_axi_awlen), .arlen(m_axi_arlen),
    .awsize(m_axi_awsize), .arsize(m_axi_arsize), .awburst(m_axi_awburst), .arburst(m_axi_arburst),
    .awvalid(m_axi_awvalid), .wlast(m_axi_wlast), .wvalid(m_axi_wvalid), .bready(m_axi_bready),
    .arvalid(m_axi_arvalid), .rready(m_axi_rready), .wdata(m_axi_wdata), .wstrb(m_axi_wstrb),
    .awready(m_axi_awready), .wready(m_axi_wready), .bvalid(m_axi_bvalid),
    .arready(m_axi_arready), .rlast(m_axi_rlast), .rvalid(m_axi_rvalid),
    .bresp(m_axi_bresp), .rresp(m_axi_rresp), .rdata(m_axi_rdata),
    .last_araddr, .read_transactions, .write_transactions);

  assert property (@(posedge clk) disable iff(rst)
    m_axi_awvalid && !m_axi_awready |=> m_axi_awvalid && $stable(m_axi_awaddr));
  assert property (@(posedge clk) disable iff(rst)
    m_axi_arvalid && !m_axi_arready |=> m_axi_arvalid && $stable(m_axi_araddr));
  assert property (@(posedge clk) disable iff(rst)
    m_axi_wvalid && !m_axi_wready |=> m_axi_wvalid && $stable({m_axi_wdata,m_axi_wstrb}));

  task automatic send_b(input logic [31:0] addr, input bit write_, input bit tag_);
    @(negedge clk); b_req = 1; b_addr = addr; b_we = write_; b_tag = tag_;
    do @(posedge clk); while (!b_rdy);
    @(negedge clk); b_req = 0;
  endtask
  task automatic check_b(input int addr, input bit tag_);
    while (!b_rvalid) @(negedge clk);
    if (b_rtag !== tag_) $fatal(1, "B tag mismatch");
    for (int i = 0; i < 128; i++)
      if (b_rdata[8*i +: 8] !== expected[(addr+i) % 65536])
        $fatal(1, "B data mismatch byte=%0d", addr+i);
    checks++; @(negedge clk);
  endtask
  task automatic drain;
    @(negedge clk);
    while (!rd_idle || !wr_idle) @(negedge clk);
  endtask
  task automatic clear_fault(input int code);
    drain();
    if (error_code != code) $fatal(1, "error=%0d expected=%0d", error_code, code);
    clear_error = 1; @(negedge clk); clear_error = 0; @(negedge clk);
    if (error_code != 0) $fatal(1, "error not cleared");
    checks++;
  endtask

  initial begin
    repeat (5) @(negedge clk); rst = 0;
    for (int i = 0; i < 65536; i++) begin
      expected[i] = 8'(i ^ (i >> 8) ^ 'h5a); memory.mem[i] = expected[i];
    end
    // A reads the aligned 32-byte scale line; check every line offset in a 128-byte beat.
    for (int l = 0; l < 4; l++) begin
      @(negedge clk); a_req = 1; a_addr = 'h1200 + 8*l + 3;
      do @(posedge clk); while (!a_rdy);
      @(negedge clk); a_req = 0;
      while (!a_rvalid) @(negedge clk);
      for (int i = 0; i < 32; i++)
        if (a_rdata[8*i +: 8] !== expected['h4800+32*l+i]) $fatal(1, "A line mismatch");
      checks++; @(negedge clk);
    end
    // B word masks, distinct data patterns and both tags, including the 4 KiB boundary.
    for (int t = 0; t < 48; t++) begin
      b_wmask = 32'h6d93a5c7 ^ (32'(t) * 'h9e3779b9);
      for (int j = 0; j < 128; j++) b_wdata[8*j +: 8] = 8'(t*17+j);
      for (int j = 0; j < 128; j++)
        if (b_wmask[j/4]) expected[('hf80 + t*128 + j) % 65536] = b_wdata[8*j +: 8];
      send_b(('hf80+t*128)/4, 1, 0); drain();
      send_b(('hf80+t*128)/4, 0, 1'(t)); check_b('hf80+t*128, 1'(t));
    end
    // Independent scalar byte enables, at every word lane in the wide AXI beat.
    for (int t = 0; t < 32; t++) begin
      @(negedge clk); sw_req = 1; sw_addr = 'h2000 + t;
      sw_wdata = 32'h12345678 ^ 32'(t); sw_be = 4'(t);
      for (int j = 0; j < 4; j++)
        if (sw_be[j]) expected['h8000 + 4*t+j] = sw_wdata[8*j +: 8];
      do @(posedge clk); while (!sw_rdy);
      @(negedge clk); sw_req = 0; drain();
    end
    send_b('h2000, 0, 1); check_b('h8000, 1);
    // All three native ports can enqueue together and make progress.
    @(negedge clk);
    a_req = 1; a_addr = 0; a_we = 0;
    b_req = 1; b_addr = 'h2000; b_we = 0; b_tag = 0;
    sw_req = 1; sw_addr = 'h3000; sw_wdata = 'hdeadbeef; sw_be = 15;
    @(posedge clk);
    if (!(a_rdy && b_rdy && sw_rdy)) $fatal(1, "queues not ready");
    @(negedge clk); a_req = 0; b_req = 0; sw_req = 0;
    check_b('h8000, 0); drain(); checks++;
    // A delayed B response must keep wr_idle low, including after AW/W are accepted.
    allow_b = 0; b_wmask = '1; send_b('h2000, 1, 0);
    repeat (40) begin @(negedge clk); if (wr_idle) $fatal(1, "early write idle"); end
    allow_b = 1; drain(); checks++;
    // An older pending B write must precede a later A read, even when round-robin
    // would choose A next after an active SW write. This catches cross-port stale reads.
    allow_b = 0;
    @(negedge clk); sw_req = 1; sw_addr = 'h3000; sw_be = 15; sw_wdata = 1;
    do @(posedge clk); while (!sw_rdy);
    @(negedge clk); sw_req = 0;
    while (!(memory.have_aw && memory.have_w)) @(negedge clk);
    b_wmask = '1; b_wdata = {32{32'hcafef00d}};
    send_b('h2400, 1, 0);
    @(negedge clk); a_req = 1; a_addr = 'h2400;
    do @(posedge clk); while (!a_rdy);
    @(negedge clk); a_req = 0; allow_b = 1;
    while (!a_rvalid) @(negedge clk);
    if (a_rdata !== {8{32'hcafef00d}}) $fatal(1, "cross-port write/read reordered");
    drain(); checks++;
    // Highest legal core address remains 0xffffff80 on AXI (model wraps only for this test).
    send_b('h3fffffe0, 0, 1); check_b('hff80, 1);
    if (last_araddr != 32'hffffff80) $fatal(1, "word-to-byte conversion truncated");
    // Faults are sticky and do not discard accepted transactions.
    inject_rresp = 2; send_b(0, 0, 0);
    while (!b_rvalid) @(negedge clk);
    if (b_rdata != 0) $fatal(1, "bad read not poisoned");
    inject_rresp = 0; clear_fault(2);
    inject_bresp = 2; send_b(0, 1, 0); drain(); inject_bresp = 0; clear_fault(3);
    inject_extra_read = 1; send_b(0, 0, 0);
    while (!b_rvalid) @(negedge clk);
    inject_extra_read = 0; clear_fault(4);
    send_b(1, 0, 0); while (!b_rvalid) @(negedge clk); clear_fault(1);
    send_b('h40000000, 0, 0); while (!b_rvalid) @(negedge clk); clear_fault(1);
    $display("BRIDGE_PASS checks=%0d reads=%0d writes=%0d", checks, read_transactions, write_transactions);
    $finish;
  end
  initial begin #2000000; $fatal(1, "unit test timeout"); end
endmodule
