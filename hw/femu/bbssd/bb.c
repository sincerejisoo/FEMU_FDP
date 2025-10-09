#include "../nvme.h"
#include "./ftl.h"

/* FDP: Initialize a Reclaim Unit */
static void fdp_init_ru(struct ssd *ssd, fdp_ru_t *ru, uint16_t ruid, 
                        uint16_t rgid, uint8_t ruhid)
{
    struct ssdparams *spp = &ssd->sp;
    
    ru->ruid = ruid;
    ru->rgid = rgid;
    ru->ruhid = ruhid;
    ru->state = NVME_FDP_RUH_UNUSED;
    ru->curline = NULL;
    ru->bytes_written = 0;
    ru->ru_open_time = 0;
    
    /* Each RU gets a fraction of total capacity */
    /* For Phase 1, we'll use simple equal division */
    ru->capacity = (uint64_t)spp->tt_pgs * spp->secsz * spp->secs_per_pg / FDP_DEFAULT_RUHS;
    
    /* Initialize write pointer */
    ru->wp.curline = NULL;
    ru->wp.ch = 0;
    ru->wp.lun = 0;
    ru->wp.pg = 0;
    ru->wp.blk = 0;
    ru->wp.pl = 0;
    
    /* Initialize free line list for this RU */
    QTAILQ_INIT(&ru->free_line_list);
    ru->free_line_cnt = 0;
}

/* FDP: Initialize configuration */
static void fdp_init_config(struct ssd *ssd)
{
    fdp_config_t *cfg = &ssd->fdp_cfg;
    
    /* Phase 1: Disable FDP by default until fully implemented */
    cfg->enabled = false;
    cfg->nrg = 1;  /* Single Reclaim Group for Phase 1 */
    cfg->nruh = FDP_DEFAULT_RUHS;  /* 4 RU Handles */
    cfg->fdpa = 0x1;  /* FDP enabled, RUH type is initially specified */
    
    /* Allocate Reclaim Groups */
    cfg->rgs = g_malloc0(sizeof(fdp_rg_t) * cfg->nrg);
    
    /* Initialize the single Reclaim Group */
    fdp_rg_t *rg = &cfg->rgs[0];
    rg->rgid = 0;
    rg->nruh = cfg->nruh;
    rg->rgslbs = ssd->sp.tt_pgs;  /* Total logical blocks */
    
    /* Allocate and initialize Reclaim Units */
    rg->rus = g_malloc0(sizeof(fdp_ru_t) * rg->nruh);
    for (int i = 0; i < rg->nruh; i++) {
        fdp_init_ru(ssd, &rg->rus[i], i, rg->rgid, i);
    }
    
    /* Initialize PH to RUHID mapping (1:1 for Phase 1) */
    for (int i = 0; i < FDP_MAX_PLACEMENT_HANDLES; i++) {
        if (i < cfg->nruh) {
            cfg->ph_to_ruhid[i] = i;  /* Direct mapping */
        } else {
            cfg->ph_to_ruhid[i] = 0;  /* Default to RU 0 */
        }
    }
    
    /* Initialize statistics */
    cfg->total_host_writes = 0;
    cfg->total_media_writes = 0;
    cfg->ru_switches = 0;
    
    femu_log("[FDP] Initialized: %d RG(s), %d RUH(s) per RG\n", cfg->nrg, cfg->nruh);
}

/* FDP: Distribute lines among RUs and initialize write pointers */
static void fdp_distribute_lines(struct ssd *ssd)
{
    fdp_config_t *cfg = &ssd->fdp_cfg;
    struct line_mgmt *lm = &ssd->lm;
    
    if (!cfg->enabled) {
        return;  /* Skip if FDP not enabled */
    }
    
    /* Use actual free line count (may be less than tt_lines if global WP already used some) */
    int total_lines = lm->free_line_cnt;
    int lines_per_ru = total_lines / cfg->nruh;
    int remaining_lines = total_lines % cfg->nruh;
    
    ftl_log("[FDP] Distributing %d lines among %d RUs (%d lines/RU, %d get +1)\n",
            total_lines, cfg->nruh, lines_per_ru, remaining_lines);
    
    /* Move lines from global free_line_list to RU-specific lists */
    for (int ruid = 0; ruid < cfg->nruh; ruid++) {
        fdp_ru_t *ru = &cfg->rgs[0].rus[ruid];
        int lines_for_this_ru = lines_per_ru + (ruid < remaining_lines ? 1 : 0);
        
        for (int i = 0; i < lines_for_this_ru; i++) {
            struct line *line = QTAILQ_FIRST(&lm->free_line_list);
            if (!line) {
                ftl_err("Ran out of lines during RU distribution!\n");
                break;
            }
            
            QTAILQ_REMOVE(&lm->free_line_list, line, entry);
            lm->free_line_cnt--;
            
            QTAILQ_INSERT_TAIL(&ru->free_line_list, line, entry);
            ru->free_line_cnt++;
        }
        
        /* Initialize write pointer for this RU */
        struct line *first_line = QTAILQ_FIRST(&ru->free_line_list);
        if (first_line) {
            QTAILQ_REMOVE(&ru->free_line_list, first_line, entry);
            ru->free_line_cnt--;
            
            ru->wp.curline = first_line;
            ru->wp.ch = 0;
            ru->wp.lun = 0;
            ru->wp.pg = 0;
            ru->wp.blk = first_line->id;
            ru->wp.pl = 0;
            
            ru->state = NVME_FDP_RUH_HOST_SPEC;  /* Mark as open */
            
            ftl_log("[FDP] RU %d: %d lines, first_blk=%d\n",
                    ruid, ru->free_line_cnt + 1, ru->wp.blk);
        } else {
            ftl_err("RU %d has no lines!\n", ruid);
        }
    }
    
    ftl_log("[FDP] Line distribution complete. Global free_line_cnt=%d\n",
            lm->free_line_cnt);
}

static void bb_init_ctrl_str(FemuCtrl *n)
{
    static int fsid_vbb = 0;
    const char *vbbssd_mn = "FEMU BlackBox-SSD Controller";
    const char *vbbssd_sn = "vSSD";

    nvme_set_ctrl_name(n, vbbssd_mn, vbbssd_sn, &fsid_vbb);
}

/* bb <=> black-box */
static void bb_init(FemuCtrl *n, Error **errp)
{
    struct ssd *ssd = n->ssd = g_malloc0(sizeof(struct ssd));

    bb_init_ctrl_str(n);

    ssd->dataplane_started_ptr = &n->dataplane_started;
    ssd->ssdname = (char *)n->devname;
    femu_debug("Starting FEMU in Blackbox-SSD mode ...\n");
    ssd_init(n);
    
    /* Initialize FDP configuration (disabled by default) */
    fdp_init_config(ssd);
    
    /* Only advertise FDP support if enabled */
    if (ssd->fdp_cfg.enabled) {
        n->oncs |= NVME_ONCS_FDP;
        n->oacs |= NVME_OACS_DIRECTIVES;
        
        /* Update the controller identify structure directly (init_ctrl already called) */
        n->id_ctrl.oncs = cpu_to_le16(n->oncs);
        n->id_ctrl.oacs = cpu_to_le16(n->oacs);
        
        femu_log("[FDP] Controller capabilities updated: ONCS=0x%x, OACS=0x%x\n",
                 n->oncs, n->oacs);
    } else {
        femu_log("[FDP] Initialized but disabled (set fdp_enabled=1 to enable)\n");
    }
}

static void bb_flip(FemuCtrl *n, NvmeCmd *cmd)
{
    struct ssd *ssd = n->ssd;
    int64_t cdw10 = le64_to_cpu(cmd->cdw10);

    switch (cdw10) {
    case FEMU_ENABLE_GC_DELAY:
        ssd->sp.enable_gc_delay = true;
        femu_log("%s,FEMU GC Delay Emulation [Enabled]!\n", n->devname);
        break;
    case FEMU_DISABLE_GC_DELAY:
        ssd->sp.enable_gc_delay = false;
        femu_log("%s,FEMU GC Delay Emulation [Disabled]!\n", n->devname);
        break;
    case FEMU_ENABLE_DELAY_EMU:
        ssd->sp.pg_rd_lat = NAND_READ_LATENCY;
        ssd->sp.pg_wr_lat = NAND_PROG_LATENCY;
        ssd->sp.blk_er_lat = NAND_ERASE_LATENCY;
        ssd->sp.ch_xfer_lat = 0;
        femu_log("%s,FEMU Delay Emulation [Enabled]!\n", n->devname);
        break;
    case FEMU_DISABLE_DELAY_EMU:
        ssd->sp.pg_rd_lat = 0;
        ssd->sp.pg_wr_lat = 0;
        ssd->sp.blk_er_lat = 0;
        ssd->sp.ch_xfer_lat = 0;
        femu_log("%s,FEMU Delay Emulation [Disabled]!\n", n->devname);
        break;
    case FEMU_RESET_ACCT:
        n->nr_tt_ios = 0;
        n->nr_tt_late_ios = 0;
        femu_log("%s,Reset tt_late_ios/tt_ios,%lu/%lu\n", n->devname,
                n->nr_tt_late_ios, n->nr_tt_ios);
        break;
    case FEMU_ENABLE_LOG:
        n->print_log = true;
        femu_log("%s,Log print [Enabled]!\n", n->devname);
        break;
    case FEMU_DISABLE_LOG:
        n->print_log = false;
        femu_log("%s,Log print [Disabled]!\n", n->devname);
        break;
    case FEMU_ENABLE_FDP:
        ssd->fdp_cfg.enabled = true;
        /* Distribute lines among RUs */
        fdp_distribute_lines(ssd);
        /* Update controller capabilities */
        n->oncs |= NVME_ONCS_FDP;
        n->oacs |= NVME_OACS_DIRECTIVES;
        n->id_ctrl.oncs = cpu_to_le16(n->oncs);
        n->id_ctrl.oacs = cpu_to_le16(n->oacs);
        femu_log("%s,FDP [Enabled]! ONCS=0x%x, OACS=0x%x\n", n->devname, n->oncs, n->oacs);
        break;
    case FEMU_DISABLE_FDP:
        ssd->fdp_cfg.enabled = false;
        n->oncs &= ~NVME_ONCS_FDP;
        n->oacs &= ~NVME_OACS_DIRECTIVES;
        n->id_ctrl.oncs = cpu_to_le16(n->oncs);
        n->id_ctrl.oacs = cpu_to_le16(n->oacs);
        femu_log("%s,FDP [Disabled]! ONCS=0x%x, OACS=0x%x\n", n->devname, n->oncs, n->oacs);
        break;
    default:
        printf("FEMU:%s,Not implemented flip cmd (%lu)\n", n->devname, cdw10);
    }
}

static uint16_t bb_nvme_rw(FemuCtrl *n, NvmeNamespace *ns, NvmeCmd *cmd,
                           NvmeRequest *req)
{
    return nvme_rw(n, ns, cmd, req);
}

static uint16_t bb_io_cmd(FemuCtrl *n, NvmeNamespace *ns, NvmeCmd *cmd,
                          NvmeRequest *req)
{
    switch (cmd->opcode) {
    case NVME_CMD_READ:
    case NVME_CMD_WRITE:
        return bb_nvme_rw(n, ns, cmd, req);
    default:
        return NVME_INVALID_OPCODE | NVME_DNR;
    }
}

static uint16_t bb_admin_cmd(FemuCtrl *n, NvmeCmd *cmd)
{
    switch (cmd->opcode) {
    case NVME_ADM_CMD_FEMU_FLIP:
        bb_flip(n, cmd);
        return NVME_SUCCESS;
    default:
        return NVME_INVALID_OPCODE | NVME_DNR;
    }
}

int nvme_register_bbssd(FemuCtrl *n)
{
    n->ext_ops = (FemuExtCtrlOps) {
        .state            = NULL,
        .init             = bb_init,
        .exit             = NULL,
        .rw_check_req     = NULL,
        .admin_cmd        = bb_admin_cmd,
        .io_cmd           = bb_io_cmd,
        .get_log          = NULL,
    };

    return 0;
}

