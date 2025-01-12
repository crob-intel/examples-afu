
// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>
#include <poll.h>
#include <pthread.h>
#include <time.h>

//#include <iostream>
//using namespace std;

#include <opae/fpga.h>
#include "dma.h"
#include "dma_util.h"

static fpga_handle s_accel_handle;
static bool s_is_ase_sim;
static volatile uint64_t *s_mmio_buf;
static int s_error_count = 0;

static uint64_t dma_dfh_offset = -256*1024;

// Shorter runs for ASE
#define TOTAL_COPY_COMMANDS (s_is_ase_sim ? 1500L : 1000000L)
#define DMA_BUFFER_SIZE (1024*1024)

#define TEST_BUFFER_SIZE_ASE 2048 * 1024
#define TEST_BUFFER_SIZE_HW 2048 * 1024

#define ON_ERR_GOTO(res, label, desc)                                          \
  do {                                                                         \
    if ((res) != FPGA_OK) {                                                    \
      print_err((desc), (res));                                                \
      s_error_count += 1;                                                      \
      goto label;                                                              \
    }                                                                          \
  } while (0)

#define BW_GIGA 1000000

void print_err(const char *s, fpga_result res) {
  fprintf(stderr, "Error %s: %s\n", s, fpgaErrStr(res));
}

// Read a 64 bit CSR. When a pointer to CSR buffer is available, read directly.
// Direct reads can be significantly faster.
static inline uint64_t readMMIO64(uint32_t idx) {
  if (s_mmio_buf) {
    return s_mmio_buf[idx];
  } else {
    fpga_result r;
    uint64_t v;
    r = fpgaReadMMIO64(s_accel_handle, 0, 8 * idx, &v);
    assert(FPGA_OK == r);
    return v;
  }
}

void mmio_read64(fpga_handle accel_handle, uint64_t addr, uint64_t *data,
                 const char *reg_name) {
  fpga_result r;
  r = fpgaReadMMIO64(accel_handle, 0, addr, data);
  assert(FPGA_OK == r);
  printf("Reading %s (Byte Offset=%08lx) = %08lx\n", reg_name, addr, *data);
}

void mmio_read64_silent(fpga_handle accel_handle, uint64_t addr,
                        uint64_t *data) {
  fpga_result r;
  r = fpgaReadMMIO64(accel_handle, 0, addr, data);
  assert(FPGA_OK == r);
}

// Write a 64 bit CSR. When a pointer to CSR buffer is available, write directly.
static inline void writeMMIO64(uint32_t idx, uint64_t v) {
  if (s_mmio_buf) {
    s_mmio_buf[idx] = v;
  } else {
    fpgaWriteMMIO64(s_accel_handle, 0, 8 * idx, v);
  }
}

double get_bandwidth(e_dma_mode descriptor_mode) {
  uint64_t rd_src_clk_cnt;
  uint64_t rd_src_valid_cnt;
  uint64_t wr_dest_clk_cnt;
  uint64_t wr_dest_valid_cnt;
  uint64_t wr_dest_bw;

  // Gather Read statistics and calculate bandwidth
  const uint64_t rd_src_perf_cntr = readMMIO64(DMA_CSR_IDX_RD_SRC_PERF_CNTR);
  rd_src_valid_cnt = rd_src_perf_cntr & 0xFFFFF; // keep lower 20 bits
  rd_src_clk_cnt = rd_src_perf_cntr >> 20;       // Keep upper 20 bits
  rd_src_clk_cnt &= 0xFFFFF;
  const double read_uptime = (rd_src_valid_cnt * 1.0) / (rd_src_clk_cnt * 1.0);
  const double read_bandwidth = read_uptime * MAX_TRPT_BYTES / 1000.0;
  if (descriptor_mode == ddr_to_host) {
    printf("\nAFU Reading DDR ");
  } else {
    printf("\nAFU Reading Host ");
  }
  printf("BW = %f GB/S\n", read_bandwidth);
  if(read_bandwidth < MIN_TRPT_GBPS) {
     fprintf(stderr, "Error: Minimum bandwidth requirement not met. Please ensure \
                      your device meets the minimum bandwidth of 8.2 GBps for \
                      optimal performance.\n");
     return -1;
  }

  // Gather Write statistics and calculate bandwidth
  const uint64_t wr_dest_perf_cntr = readMMIO64(DMA_CSR_IDX_WR_DEST_PERF_CNTR);
  wr_dest_valid_cnt = wr_dest_perf_cntr & 0xFFFFF;
  wr_dest_clk_cnt = wr_dest_perf_cntr >> 20;
  wr_dest_clk_cnt &= 0xFFFFF;
  const double write_uptime =
      (wr_dest_valid_cnt * 1.0) / (wr_dest_clk_cnt * 1.0);
  const double write_bandwidth = write_uptime * MAX_TRPT_BYTES / 1000.0;
  if (descriptor_mode == ddr_to_host) {
    printf("Host to AFU ");
  } else {
    printf("DDR to AFU ");
  }
  printf("Write BW = %f GB/S\n\n", write_bandwidth);
  if(write_bandwidth < MIN_TRPT_GBPS) {
     fprintf(stderr, "Error: Minimum bandwidth requirement not met. Please ensure \
                      your device meets the minimum bandwidth of 8.2 GBps for \
                      optimal performance.\n");
     return -1;
  }
  double average_bw = (read_bandwidth + write_bandwidth)/2; 
  return average_bw;
}

void print_csrs() {
  printf("AFU properties:\n");

  uint64_t dfh = readMMIO64(DMA_CSR_IDX_DFH);
  printf("  DMA_DFH:                %016lX\n", dfh);

  uint64_t guid_l = readMMIO64(DMA_CSR_IDX_GUID_L);
  printf("  DMA_GUID_L:             %016lX\n", guid_l);

  uint64_t guid_h = readMMIO64(DMA_CSR_IDX_GUID_H);
  printf("  DMA_GUID_H:             %016lX\n", guid_h);

  uint64_t rsvd_1 = readMMIO64(DMA_CSR_IDX_RSVD_1);
  printf("  DMA_RSVD_1:             %016lX\n", rsvd_1);

  uint64_t rsvd_2 = readMMIO64(DMA_CSR_IDX_RSVD_2);
  printf("  DMA_RSVD_2:             %016lX\n", rsvd_2);

  uint64_t src_addr = readMMIO64(DMA_CSR_IDX_SRC_ADDR);
  printf("  DMA_SRC_ADDR:           %016lX\n", src_addr);

  uint64_t dest_addr = readMMIO64(DMA_CSR_IDX_DEST_ADDR);
  printf("  DMA_DEST_ADDR:          %016lX\n", dest_addr);

  uint64_t length = readMMIO64(DMA_CSR_IDX_LENGTH);
  printf("  DMA_LENGTH:             %016lX\n", length);

  uint64_t descriptor_control = readMMIO64(DMA_CSR_IDX_DESCRIPTOR_CONTROL);
  printf("  DMA_DESCRIPTOR_CONTROL: %016lX\n", descriptor_control);

  uint64_t status = readMMIO64(DMA_CSR_IDX_STATUS);
  printf("  DMA_STATUS:             %016lX\n", status);

  uint64_t csr_control = readMMIO64(DMA_CSR_IDX_CONTROL);
  printf("  DMA_CONTROL:            %016lX\n", csr_control);

  uint64_t wr_re_fill_level = readMMIO64(DMA_CSR_IDX_WR_RE_FILL_LEVEL);
  printf("  DMA_WR_RE_FILL_LEVEL:   %016lX\n", wr_re_fill_level);

  uint64_t resp_fill_level = readMMIO64(DMA_CSR_IDX_RESP_FILL_LEVEL);
  printf("  DMA_RESP_FILL_LEVEL:    %016lX\n", resp_fill_level);

  uint64_t seq_num = readMMIO64(DMA_CSR_IDX_WR_RE_SEQ_NUM);
  printf("  DMA_WR_RE_SEQ_NUM:      %016lX\n", seq_num);

  uint64_t config1 = readMMIO64(DMA_CSR_IDX_CONFIG_1);
  printf("  DMA_CONFIG_1:           %016lX\n", config1);

  uint64_t config2 = readMMIO64(DMA_CSR_IDX_CONFIG_2);
  printf("  DMA_CONFIG_2:           %016lX\n", config2);

  uint64_t info = readMMIO64(DMA_CSR_IDX_TYPE_VERSION);
  printf("  DMA_TYPE_VERSION:       %016lX\n", info);

  uint64_t rd_src_perf_cntr = readMMIO64(DMA_CSR_IDX_RD_SRC_PERF_CNTR);
  printf("  RD_SRC_PERF_CNTR:       %016lX\n", rd_src_perf_cntr);

  uint64_t wr_dest_perf_cntr = readMMIO64(DMA_CSR_IDX_WR_DEST_PERF_CNTR);
  printf("  WR_DEST_PERF_CNTR:      %016lX\n", wr_dest_perf_cntr);

  printf("\n");
}

void send_descriptor(fpga_handle accel_handle, uint64_t mmio_dst,
                     dma_descriptor_t desc) {
  // mmio requires 8 byte alignment
  assert(mmio_dst % 8 == 0);

  uint32_t dev_addr = mmio_dst;

  fpgaWriteMMIO64(accel_handle, 0, dev_addr, desc.src_address);
  printf("Writing %lX to address %X\n", desc.src_address, dev_addr);
  dev_addr += 8;
  fpgaWriteMMIO64(accel_handle, 0, dev_addr, desc.dest_address);
  printf("Writing %lX to address %X\n", desc.dest_address, dev_addr);
  dev_addr += 8;
  fpgaWriteMMIO64(accel_handle, 0, dev_addr, desc.len);
  printf("Writing %X to address %X\n", desc.len, dev_addr);
  dev_addr += 8;
  fpgaWriteMMIO64(accel_handle, 0, dev_addr, desc.control);
  printf("Writing %X to address %X\n", desc.control, dev_addr);
}

void dma_transfer(fpga_handle accel_handle, e_dma_mode mode, uint64_t dev_src,
                  uint64_t dev_dest, int len, bool verbose) {
  // Performance tracking variables
  clock_t start, end;
  double sw_bandwidth;

  fpga_result res = FPGA_OK;

  // dma requires 64 byte alignment
  assert(dev_src % 64 == 0);
  assert(dev_dest % 64 == 0);

  // only 32bit for now
  const uint64_t MASK_FOR_32BIT_ADDR = 0xFFFFFFFF;

  dma_descriptor_t desc;
  // Set the DMA Transaction type: host_to_ddr, ddr_to_host, ddr_to_ddr
  e_dma_mode descriptor_mode = mode;

  desc.src_address = dev_src & MASK_FOR_32BIT_ADDR;
  desc.dest_address = dev_dest & MASK_FOR_32BIT_ADDR;
  desc.len = len;
  desc.control = 0x80000000 | (descriptor_mode << MODE_SHIFT);

  const uint64_t DMA_DESC_BASE = 8 * DMA_CSR_IDX_SRC_ADDR;
  const uint64_t DMA_STATUS_BASE = 8 * DMA_CSR_IDX_STATUS;
  uint64_t mmio_data = 0;

  // int desc_size = sizeof(desc)/sizeof(desc.control);
  int desc_size = sizeof(desc);
  if (verbose) {
    printf("\nDescriptor size   = %d\n", desc_size);
    printf("desc.src_address  = %04lX\n", desc.src_address);
    printf("desc.dest_address = %04lX\n", desc.dest_address);
    printf("desc.len          = %d\n", desc.len);
    printf("desc.control      = %04X\n", desc.control);
  }

  // send descriptor
  start = clock();
  for (int i=0; i<2; i++) {
     send_descriptor(accel_handle, DMA_DESC_BASE, desc);
  }

  mmio_read64_silent(accel_handle, DMA_STATUS_BASE, &mmio_data);
  // If the descriptor buffer is empty, then we are done
  while ((mmio_data & 0x1) == 0x1) {
#ifdef USE_ASE
    sleep(1);
    if (verbose)
      print_csrs();
    mmio_read64(accel_handle, DMA_STATUS_BASE, &mmio_data, "dma_csr_base");
#else
    mmio_read64_silent(accel_handle, DMA_STATUS_BASE, &mmio_data);
#endif
    }
    end = clock();
    sw_bandwidth = ((double)(len * DMA_LINE_SIZE)) /
                   (BW_GIGA * ((double)(end - start)) / CLOCKS_PER_SEC);
    printf("\nApparent Transfer Bandwidth: %4.5fGB/s", sw_bandwidth);
}

int run_basic_ddr_dma_test(fpga_handle accel_handle, int transfer_size, bool verbose) {
  // Shared buffer in host memory
  volatile uint64_t *dma_buf_ptr = NULL;
  // Workspace ID used by OPAE to identify buffer
  uint64_t dma_buf_wsid;
  // Return status buffer for OPAE library calls
  fpga_result res = FPGA_OK;
  int num_errors = 0;

  // Set test transfer size
  uint32_t test_buffer_size;

  //Ensure the transfer size is in terms of 64B (512-bit) lines
  assert(transfer_size%64==0);

  if (s_is_ase_sim)
    assert(transfer_size <= TEST_BUFFER_SIZE_ASE);
  else
    assert(test_buffer_size <= TEST_BUFFER_SIZE_HW);
  
  test_buffer_size = transfer_size;

  // Set transfer size in number of beats of size awsize
  const uint32_t awsize = DMA_LINE_SIZE;
  uint32_t dma_len = ((test_buffer_size - 1) / DMA_LINE_SIZE)+1; // Ceiling of test_buffer_size / awsize
  printf("dma_len = %d\n", dma_len);

  // Create expected result
  uint32_t test_buffer_word_size = test_buffer_size / 8;
  char expected_result[test_buffer_size];
  uint64_t *expected_result_word_ptr = (uint64_t *)expected_result;
  for (int i = 0; i < test_buffer_word_size; i++) {
    expected_result_word_ptr[i] = i;
  }

  printf("TEST_BUFFER_SIZE = %d\n", test_buffer_size);
  printf("DMA_BUFFER_SIZE  = %d\n", DMA_BUFFER_SIZE);

  // Initialize shared buffer
  res = fpgaPrepareBuffer(accel_handle, DMA_BUFFER_SIZE, (void **)&dma_buf_ptr,
                          &dma_buf_wsid, 0);
  ON_ERR_GOTO(res, release_buf, "allocating dma buffer");
  memset((void *)dma_buf_ptr, 0x0, DMA_BUFFER_SIZE);

  // Store virtual address of IO registers
  uint64_t dma_buf_iova;
  res = fpgaGetIOAddress(accel_handle, dma_buf_wsid, &dma_buf_iova);
  ON_ERR_GOTO(res, release_buf, "getting dma DMA_BUF_IOVA");

  for (int i = 0; i < test_buffer_word_size; i++) {
    dma_buf_ptr[i] = i;
  }

  // Basic DMA transfer, Host to DDR
  dma_transfer(accel_handle, host_to_ddr, dma_buf_iova | DMA_HOST_MASK, 0,
               dma_len, verbose);
  double h2a_bw = get_bandwidth(host_to_ddr);

  // DMA Transfer
  memset((void *)dma_buf_ptr, 0x0, DMA_BUFFER_SIZE);

  // Basic DMA transfer, DDR to Host
  dma_transfer(accel_handle, ddr_to_host, 0, dma_buf_iova | DMA_HOST_MASK,
               dma_len, verbose);

  double a2h_bw = get_bandwidth(ddr_to_host);

  if ((a2h_bw == -1) || h2a_bw == -1) {
     fprintf(stderr, "Error: Minimum bandwidth requirement violation detected.\n");
     return -1; 
  }

  // Check expected result
  if (memcmp((void *)dma_buf_ptr, (void *)expected_result, test_buffer_size) !=
      0) {
    printf("\nERROR: memcmp failed!\n");
    num_errors++;
  } else {
    printf("\nSuccess!\n");
  }

  release_buf:
    res = fpgaReleaseBuffer(accel_handle, dma_buf_wsid); 

  return num_errors;
}

int dma(fpga_handle accel_handle, bool is_ase_sim, uint32_t transfer_size,
        bool verbose) {
  fpga_result r;

  s_accel_handle = accel_handle;
  s_is_ase_sim = is_ase_sim;

  // Get a pointer to the MMIO buffer for direct access. The OPAE functions will
  // be used with ASE since true MMIO isn't detected by the SW simulator.
  if (is_ase_sim) {
    s_mmio_buf = NULL;
  } else {
    uint64_t *tmp_ptr;
    r = fpgaMapMMIO(accel_handle, 0, &tmp_ptr);
    assert(FPGA_OK == r);
    s_mmio_buf = tmp_ptr;
  }

  return run_basic_ddr_dma_test(s_accel_handle, transfer_size, verbose);
}

