TOP      ?= tb_downscale_scanner_buffer
SIMV     ?= simv
LOG_DIR  ?= logs
CASE_DIR ?= case
TB_FILE  ?= $(CASE_DIR)/$(TOP).v

RTL_FILES := \
	ram_rws_256x160.v \
	ram_rws_64x128.v \
	pp_downscale_dst_scan_ctrl.v \
	downscale_block_buffer.v \
	pp_downscale_lanczos4_coef_rom.v \
	pp_downscale_lanczos4_core.v \
	$(TB_FILE)

VCS      ?= vcs
VCS_FLAGS ?= \
	-full64 \
	-sverilog \
	-timescale=1ns/1ps \
	-debug_access+all \
	+v2k \
	+define+VERIF_DEBUG_EN \
	+lint=TFIPC-L

RUN_FLAGS ?=

.PHONY: all comp run sim clean distclean filelist

all: sim

filelist:
	@printf "%s\n" $(RTL_FILES) > filelist.f
	@echo "Generated filelist.f"

comp: filelist
	@mkdir -p $(LOG_DIR)
	$(VCS) $(VCS_FLAGS) -top $(TOP) -f filelist.f -l $(LOG_DIR)/vcs_compile.log -o $(SIMV)

run: comp
	@mkdir -p $(LOG_DIR)
	./$(SIMV) $(RUN_FLAGS) -l $(LOG_DIR)/vcs_run.log

sim: run

clean:
	rm -rf csrc $(SIMV) $(SIMV).daidir ucli.key vc_hdrs.h DVEfiles inter.vpd novas.* verdiLog
	rm -rf filelist.f

distclean: clean
	rm -rf $(LOG_DIR)
