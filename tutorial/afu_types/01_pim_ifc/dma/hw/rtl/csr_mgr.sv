// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT

`include "ofs_plat_if.vh"
`include "afu_json_info.vh"

//
// Simple CSR manager. Export the required device feature header and some
// command registers for triggering host memory reads and writes. The
// number of registers managed here is quite small and throughput
// of reads doesn't affect performance, so the CSR interface is not
// pipelined.
//

//
// Read registers (64 bits, byte address is offset * 8):
//
//   0: Device feature header (DFH)
//   1: AFU_ID_L
//   2: AFU_ID_L

import dma_pkg::*;

module csr_mgr
  #(
    parameter MAX_REQS_IN_FLIGHT = 32,
    parameter MAX_BURST_CNT = 8
    )
   (
    // CSR interface (MMIO on the host)
    ofs_plat_axi_mem_lite_if.to_source mmio64_to_afu,

    // !!RP Is this still enough? 
    output dma_pkg::t_control wr_host_control,
    input  dma_pkg::t_status  wr_host_status,

    // Write engine control - initiate a write of num_lines from addr when enable is set.
    // Write data comes from a read. For a given read/write pair, num_lines must match.
    output dma_pkg::t_control wr_ddr_control,
    input  dma_pkg::t_status wr_ddr_status
    );

    // Each interface names its associated clock and reset.
    logic clk;
    assign clk = mmio64_to_afu.clk;
    logic reset_n;
    assign reset_n = mmio64_to_afu.reset_n;


    // =========================================================================
    //
    //   CSR (MMIO) handling with AXI lite.
    //
    // =========================================================================

    t_dma_csr dma_csr;
    
    //
    // The AXI lite interface is defined in
    // $OPAE_PLATFORM_ROOT/hw/lib/build/platform/ofs_plat_if/rtl/base_ifcs/axi/ofs_plat_axi_mem_lite_if.sv.
    // It contains fields defined by the AXI standard, though organized
    // slightly unusually. Instead of being a flat data structure, the
    // payload for each bus is a struct. The name of the AXI field is the
    // concatenation of the struct instance and field. E.g., AWADDR is
    // aw.addr. The use of structs makes it easier to bulk copy or bulk
    // initialize the full payload of a bus.
    //

    //
    // A valid AFU must implement a device feature list, starting at MMIO
    // address 0.  Every entry in the feature list begins with 5 64-bit
    // words: a device feature header, two AFU UUID words and two reserved
    // words.
    //

    // 64 bit device feature header where the type [63:60] is 0x1 (AFU) and [40] is set (EOL)
    assign dma_csr.header.dfh = 'h1000010000000000;

    // The AFU ID is a unique ID for a given program.  Here we generated
    // one with the "uuidgen" program and stored it in the AFU's JSON file.
    // ASE and synthesis setup scripts automatically invoke afu_json_mgr
    // to extract the UUID into afu_json_info.vh.
    logic [127:0] afu_id = `AFU_ACCEL_UUID;
    assign dma_csr.header.guid_l = afu_id[63:0];
    assign dma_csr.header.guid_h = afu_id[127:64];

    assign dma_csr.header.rsvd_1 = 'hDEAD_BEEF_ABCD_EF01;
    assign dma_csr.header.rsvd_2 = 'hBADD_C0DE_FEDC_BA10;


    // Read only fixed register assignments
    assign dma_csr.csr.config1.max_byte                 = 'b0;  // TODO:
    assign dma_csr.csr.config1.max_burst_count          = 'b0;  // TODO:
    assign dma_csr.csr.config1.error_width              = 'b0;  // TODO:
    assign dma_csr.csr.config1.error_enable             = 'b0;  // TODO:
    assign dma_csr.csr.config1.enhanced_features        = 'b0;  // TODO:
    assign dma_csr.csr.config1.dma_mode                 = 'b0;  // TODO:
    assign dma_csr.csr.config1.descriptor_fifo_depth    = DMA_DESCRIPTOR_FIFO_DEPTH_ENCODED;;
    assign dma_csr.csr.config1.data_width               = 'b0;  // TODO:
    assign dma_csr.csr.config1.data_fifo_depth          = 'b0;  // TODO:
    assign dma_csr.csr.config1.channel_width            = 'b0;  // TODO:
    assign dma_csr.csr.config1.channel_enable           = 'b0;  // TODO:
    assign dma_csr.csr.config1.burst_wrapping_support   = 'b0;  // TODO:
    assign dma_csr.csr.config1.burst_enable             = 'b0;  // TODO:
 
    assign dma_csr.csr.config2.rsvd                         = 'b0;
    assign dma_csr.csr.config2.transfer_type                = 'b0;  // TODO:
    assign dma_csr.csr.config2.response_port                = 'b0;  // TODO:
    assign dma_csr.csr.config2.programmable_burtst_enable   = 'b0;  // TODO:
    assign dma_csr.csr.config2.prefetcher_enable            = 'b0;  // TODO:
    assign dma_csr.csr.config2.packet_enable                = 'b0;  // TODO: 
    assign dma_csr.csr.config2.max_stride                   = 'b0;  // TODO:
    assign dma_csr.csr.config2.stride_enable                = 'b0;  // TODO:
   

    // Use a copy of the MMIO interface as registers.
    ofs_plat_axi_mem_lite_if
      #(
        // PIM-provided macro to replicate identically sized instances of an
        // AXI lite interface.
        `OFS_PLAT_AXI_MEM_LITE_IF_REPLICATE_PARAMS(mmio64_to_afu)
        )
      mmio64_reg();

    // Is a CSR read request active this cycle? The test is simple because
    // the mmio64_reg.arvalid can only be set when the read response buffer
    // is empty.
    logic is_csr_read;
    assign is_csr_read = mmio64_reg.arvalid;

    // Is a CSR write request active this cycle?
    logic is_csr_write;
    assign is_csr_write = mmio64_reg.awvalid && mmio64_reg.wvalid;


    //
    // Receive MMIO read requests
    //

    // Ready for new request iff read request and response registers are empty
    assign mmio64_to_afu.arready = !mmio64_reg.arvalid && !mmio64_reg.rvalid;

    always_ff @(posedge clk) begin
        if (is_csr_read) begin
            // Current read request was handled
            mmio64_reg.arvalid <= 1'b0;
        end
        else if (mmio64_to_afu.arvalid && mmio64_to_afu.arready) begin
            // Receive new read request
            mmio64_reg.arvalid <= 1'b1;
            mmio64_reg.ar <= mmio64_to_afu.ar;
        end

        if (!reset_n) begin
            mmio64_reg.arvalid <= 1'b0;
        end
    end

    //
    // Decode register read addresses and respond with data.
    //

    assign mmio64_to_afu.rvalid = mmio64_reg.rvalid;
    assign mmio64_to_afu.r = mmio64_reg.r;

    always_ff @(posedge clk) begin
        if (is_csr_read) begin
            // New read response
            mmio64_reg.rvalid <= 1'b1;

            mmio64_reg.r <= '0;
            // The unique transaction ID matches responses to requests
            mmio64_reg.r.id <= mmio64_reg.ar.id;
            // Return user flags from request
            mmio64_reg.r.user <= mmio64_reg.ar.user;

            // AXI addresses are always in byte address space. Ignore the
            // low 3 bits to index 64 bit CSRs. Ignore high bits and let the
            // address space wrap.
            case (mmio64_reg.ar.addr[7:3])
              DMA_DFH:                 mmio64_reg.r.data <= dma_csr.header.dfh;
              DMA_GUID_L:              mmio64_reg.r.data <= dma_csr.header.guid_l;
              DMA_GUID_H:              mmio64_reg.r.data <= dma_csr.header.guid_h;
              DMA_RSVD_1:              mmio64_reg.r.data <= dma_csr.header.rsvd_1;
              DMA_RSVD_2:              mmio64_reg.r.data <= dma_csr.header.rsvd_2;

              DMA_SRC_ADDR:            mmio64_reg.r.data <= dma_csr.descriptor.src_addr;
              DMA_DEST_ADDR:           mmio64_reg.r.data <= dma_csr.descriptor.dest_addr;
              DMA_LENGTH:              mmio64_reg.r.data <= dma_csr.descriptor.length;
              DMA_DESCRIPTOR_CONTROL:  mmio64_reg.r.data <= dma_csr.descriptor.control;

              DMA_STATUS:              mmio64_reg.r.data <= dma_csr.csr.status;
              DMA_CONTROL:             mmio64_reg.r.data <= dma_csr.csr.control;
              DMA_WR_RE_FILL_LEVEL:    mmio64_reg.r.data <= dma_csr.csr.wr_re_fill_level;
              DMA_RESP_FILL_LEVEL:     mmio64_reg.r.data <= dma_csr.csr.resp_fill_level;
              DMA_WR_RE_SEQ_NUM:       mmio64_reg.r.data <= dma_csr.csr.seq_num;
              DMA_CONFIG_1:            mmio64_reg.r.data <= dma_csr.csr.config1;
              DMA_CONFIG_2:            mmio64_reg.r.data <= dma_csr.csr.config2;
              DMA_TYPE_VERSION:        mmio64_reg.r.data <= dma_csr.csr.info;
            endcase

        end else if (mmio64_to_afu.rready) begin
            // If a read response was pending, it completed
            mmio64_reg.rvalid <= 1'b0;
        end

        if (!reset_n) begin
            dma_csr.csr.status              <= 'b0;
            dma_csr.csr.wr_re_fill_level    <= 'b0;
            dma_csr.csr.resp_fill_level     <= 'b0;
            dma_csr.csr.seq_num             <= 'b0;
            dma_csr.csr.info                <= 'b0;
            mmio64_reg.rvalid <= 1'b0;
        end
    end


    //
    // CSR write handling.  Host software must tell the AFU the memory address
    // to which it should be writing.  The address is set by writing a CSR.
    //

    // Ready for new request iff write request register is empty. For simplicity,
    // not pipelined.
    assign mmio64_to_afu.awready = !mmio64_reg.awvalid && !mmio64_reg.bvalid;
    assign mmio64_to_afu.wready  = !mmio64_reg.wvalid && !mmio64_reg.bvalid;

    // Register incoming writes, waiting for both an address and a payload.
    always_ff @(posedge clk) begin
        if (is_csr_write) begin
            // Current write request was handled
            mmio64_reg.awvalid <= 1'b0;
            mmio64_reg.wvalid <= 1'b0;
        end else begin
            // Receive new write address
            if (mmio64_to_afu.awvalid && mmio64_to_afu.awready) begin
                mmio64_reg.awvalid <= 1'b1;
                mmio64_reg.aw <= mmio64_to_afu.aw;
            end

            // Receive new write data
            if (mmio64_to_afu.wvalid && mmio64_to_afu.wready)  begin
                mmio64_reg.wvalid <= 1'b1;
                mmio64_reg.w <= mmio64_to_afu.w;
            end
        end

        if (!reset_n) begin
            mmio64_reg.awvalid <= 1'b0;
            mmio64_reg.wvalid <= 1'b0;
        end
    end

    // Generate a CSR write response once both address and data have arrived
    assign mmio64_to_afu.bvalid = mmio64_reg.bvalid;
    assign mmio64_to_afu.b = mmio64_reg.b;

    always_ff @(posedge clk) begin
        if (is_csr_write) begin
            // New write response
            mmio64_reg.bvalid <= 1'b1;

            mmio64_reg.b <= '0;
            mmio64_reg.b.id <= mmio64_reg.aw.id;
            mmio64_reg.b.user <= mmio64_reg.aw.user;
        end else if (mmio64_to_afu.bready) begin
            // If a write response was pending it completed
            mmio64_reg.bvalid <= 1'b0;
        end

        if (!reset_n) begin
            mmio64_reg.bvalid <= 1'b0;
        end
    end


    //
    // Decode CSR writes into dma engine commands.
    //
    always_ff @(posedge clk) begin
        // There is no flow control on the module's outgoing read/write command
        // ports. If a request was trigger in the last cycle, it was sent.

        if (dma_csr.descriptor.control.go) begin
            dma_csr.descriptor.control.go <= 'b0;
        end

        if (is_csr_write) begin
            // AXI addresses are always in byte address space. Ignore the
            // low 3 bits to index 64 bit CSRs. Ignore high bits and let the
            // address space wrap.
            case (mmio64_reg.aw.addr[7:3])
              DMA_SRC_ADDR:           dma_csr.descriptor.src_addr   <= mmio64_reg.w.data[$bits(dma_csr.descriptor.src_addr)-1 : 0];
              DMA_DEST_ADDR:          dma_csr.descriptor.dest_addr  <= mmio64_reg.w.data[$bits(dma_csr.descriptor.src_addr)-1 : 0];
              DMA_LENGTH:             dma_csr.descriptor.length     <= mmio64_reg.w.data[$bits(dma_csr.descriptor.src_addr)-1 : 0];
              DMA_DESCRIPTOR_CONTROL: dma_csr.descriptor.control    <= mmio64_reg.w.data[$bits(dma_csr.descriptor.src_addr)-1 : 0];

              DMA_CONTROL:            dma_csr.csr.control           <= mmio64_reg.w.data[$bits(dma_csr.descriptor.src_addr)-1 : 0];
            endcase
            
        end

 
        if (!reset_n) begin
            dma_csr.descriptor.src_addr     <= 'b0;
            dma_csr.descriptor.dest_addr    <= 'b0;
            dma_csr.descriptor.length       <= 'b0;
            dma_csr.descriptor.control      <= 'b0;

            dma_csr.csr.control             <= 'b0;
            // wr_ddr_control.mode <= dma_pkg::DDR_TO_HOST;
            // wr_ddr_control.reset_engine <= 1;
            // wr_host_control.mode <= dma_pkg::DDR_TO_HOST;
            // wr_host_control.reset_engine <= 1;
        end
    end

    // TODO: used for testing; remove
    assign wr_host_control.descriptor = dma_csr.descriptor;
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            wr_host_control.reset_engine <= 'b0;
            wr_host_control.mode <= 'b0;
            wr_ddr_control <= 'b0;
        end
    end

    // synthesis translate_off
    always_ff @(posedge clk) begin
      //if (rd_cmd.enable && reset_n)
      //begin
      //    $display("CSR_MGR: Read 0x%0h lines, starting at addr 0x%0h",
      //             rd_cmd.num_lines, rd_cmd.addr);
      //end

      //if (wr_cmd.enable && reset_n)
      //begin
      //    $display("CSR_MGR: Write 0x%0h lines, starting at addr 0x%0h, %0s req comletion",
      //             wr_cmd.num_lines, { wr_cmd.addr[$bits(wr_cmd.addr)-1 : 1], 1'b0 },
      //             (wr_cmd.addr[0] ? "with" : "without"));
      //end
    end
    // synthesis translate_on

endmodule
