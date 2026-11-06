// kmtp: run several Kindle MTP actions in ONE connection.
// The Kindle drops off USB whenever an MTP session ends, so every step
// has to happen inside a single session.
//
//   kmtp [wait] ACTION...
//   ls                 list the top folder
//   rmupd              delete Amazon update files in the top folder (update*.bin, *.partial)
//   fill LEAVE_MB      write blank filler files until only LEAVE_MB is free
//   rmfill             delete the filler files written by `fill`
//   rename OLD NEW     rename an item in the top folder
//   putdir LOCAL NAME  copy a local folder to the top folder as NAME
//   put LOCAL DIRNAME  copy one local file into top-level folder DIRNAME
//   rmtree NAME        delete a top-level folder and everything in it (core folders refused)
//   putpath LOCAL PATH copy a file to PATH (e.g. koreader/frontend/x.lua), replacing it
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <fnmatch.h>

static LIBMTP_mtpdevice_t *dev;
static uint32_t sid;
#define ROOT LIBMTP_FILES_AND_FOLDERS_ROOT

static uint64_t free_bytes(void) {
    LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED);
    return dev->storage ? dev->storage->FreeSpaceInBytes : 0;
}

static LIBMTP_file_t *list(uint32_t parent) {
    return LIBMTP_Get_Files_And_Folders(dev, sid, parent);
}

static void free_list(LIBMTP_file_t *f) {
    while (f) { LIBMTP_file_t *n = f->next; LIBMTP_destroy_file_t(f); f = n; }
}

static uint32_t find_root(const char *name) {
    uint32_t id = 0;
    LIBMTP_file_t *l = list(ROOT);
    for (LIBMTP_file_t *f = l; f; f = f->next)
        if (strcmp(f->filename, name) == 0) id = f->item_id;
    free_list(l);
    return id;
}

static void do_ls(void) {
    LIBMTP_file_t *l = list(ROOT);
    for (LIBMTP_file_t *f = l; f; f = f->next)
        printf("  %s%s  (%llu bytes)\n", f->filename,
               f->filetype == LIBMTP_FILETYPE_FOLDER ? "/" : "",
               (unsigned long long)f->filesize);
    free_list(l);
    printf("  free: %.1f MB\n", free_bytes() / 1048576.0);
}

static int do_rm_matching(const char **pats) {
    int n = 0, bad = 0;
    LIBMTP_file_t *l = list(ROOT);
    for (LIBMTP_file_t *f = l; f; f = f->next) {
        if (f->filetype == LIBMTP_FILETYPE_FOLDER) continue;
        for (const char **p = pats; *p; p++) {
            if (fnmatch(*p, f->filename, 0) == 0) {
                if (LIBMTP_Delete_Object(dev, f->item_id) == 0) { printf("  deleted %s\n", f->filename); n++; }
                else { printf("  FAILED to delete %s\n", f->filename); bad++; }
                break;
            }
        }
    }
    free_list(l);
    printf("  %d deleted\n", n);
    return bad ? 1 : 0;
}

static uint16_t zeros(void *params, void *priv, uint32_t wantlen, unsigned char *data, uint32_t *gotlen) {
    (void)params; (void)priv;
    memset(data, 0, wantlen); *gotlen = wantlen;
    return LIBMTP_HANDLER_RETURN_OK;
}

static int progress(uint64_t sent, uint64_t total, void const *const data) {
    static int last = -1; (void)data;
    int pct = total ? (int)(sent * 100 / total) : 100;
    if (pct / 10 != last / 10) { fprintf(stderr, "    %d%%\n", pct); last = pct; }
    return 0;
}

static int send_blank(const char *name, uint64_t size) {
    LIBMTP_file_t *f = LIBMTP_new_file_t();
    f->filename = strdup(name); f->filesize = size;
    f->filetype = LIBMTP_FILETYPE_UNKNOWN; f->parent_id = 0; f->storage_id = sid;
    int r = LIBMTP_Send_File_From_Handler(dev, zeros, NULL, f, progress, NULL);
    LIBMTP_destroy_file_t(f);
    return r;
}

static int do_fill(uint64_t leave) {
    const uint64_t chunk = 1024ULL * 1048576ULL;
    for (int i = 1; i < 100; i++) {
        uint64_t fr = free_bytes();
        if (fr <= leave + 4 * 1048576ULL) break;
        uint64_t size = fr - leave;
        if (size > chunk) size = chunk;
        char name[64]; snprintf(name, sizeof name, "filler_%02d.dat", i);
        if (find_root(name)) continue;
        printf("  writing %s (%.0f MB), %.0f MB free\n", name, size / 1048576.0, fr / 1048576.0);
        fflush(stdout);
        if (send_blank(name, size) != 0) {
            printf("  write failed\n"); LIBMTP_Dump_Errorstack(dev); LIBMTP_Clear_Errorstack(dev);
            return 1;
        }
    }
    printf("  free now: %.1f MB\n", free_bytes() / 1048576.0);
    return 0;
}

static int send_tree(const char *local, uint32_t parent, int *count) {
    DIR *d = opendir(local);
    if (!d) { printf("  can't open %s\n", local); return 1; }
    struct dirent *e;
    int bad = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' && (!e->d_name[1] || (e->d_name[1] == '.' && !e->d_name[2]))) continue;
        if (strcmp(e->d_name, ".DS_Store") == 0) continue;
        char path[4096]; snprintf(path, sizeof path, "%s/%s", local, e->d_name);
        struct stat st;
        if (lstat(path, &st) != 0) continue;
        if (S_ISLNK(st.st_mode)) { printf("  skipped symlink %s\n", path); continue; }
        if (S_ISDIR(st.st_mode)) {
            char *nm = strdup(e->d_name);
            uint32_t id = LIBMTP_Create_Folder(dev, nm, parent, sid);
            free(nm);
            if (!id) { printf("  mkdir failed %s\n", path); bad++; continue; }
            bad += send_tree(path, id, count);
        } else if (S_ISREG(st.st_mode)) {
            LIBMTP_file_t *f = LIBMTP_new_file_t();
            f->filename = strdup(e->d_name); f->filesize = st.st_size;
            f->filetype = LIBMTP_FILETYPE_UNKNOWN; f->parent_id = parent; f->storage_id = sid;
            if (LIBMTP_Send_File_From_File(dev, path, f, NULL, NULL) != 0) {
                printf("  send failed %s\n", path); LIBMTP_Clear_Errorstack(dev); bad++;
            } else if (++*count % 100 == 0) { fprintf(stderr, "    %d files\n", *count); }
            LIBMTP_destroy_file_t(f);
        }
    }
    closedir(d);
    return bad;
}

// Find a child by name under parent (ROOT for the top folder). 0 if missing.
static uint32_t find_child(uint32_t parent, const char *name, int *is_folder) {
    uint32_t id = 0;
    LIBMTP_file_t *l = list(parent);
    for (LIBMTP_file_t *f = l; f; f = f->next)
        if (strcmp(f->filename, name) == 0) { id = f->item_id; if (is_folder) *is_folder = f->filetype == LIBMTP_FILETYPE_FOLDER; }
    free_list(l);
    return id;
}

// Copy LOCAL to REMOTE ("koreader/frontend/pixel/drive.lua"), replacing a file already there.
static int do_putpath(const char *local, const char *remote) {
    struct stat st;
    if (stat(local, &st) || !S_ISREG(st.st_mode)) { printf("  no local file %s\n", local); return 1; }
    char buf[1024]; snprintf(buf, sizeof buf, "%s", remote);
    uint32_t parent = ROOT, send_parent = 0;
    char *seg = buf, *slash;
    while ((slash = strchr(seg, '/'))) {
        *slash = 0;
        int isf = 0;
        uint32_t id = find_child(parent, seg, &isf);
        if (!id || !isf) { printf("  no folder %s on the Kindle\n", seg); return 1; }
        parent = id; send_parent = id;
        seg = slash + 1;
    }
    int isf = 0;
    uint32_t old = find_child(parent, seg, &isf);
    if (old && isf) { printf("  %s is a folder\n", remote); return 1; }
    if (old && LIBMTP_Delete_Object(dev, old) != 0) { printf("  can't replace %s\n", remote); return 1; }
    LIBMTP_file_t *f = LIBMTP_new_file_t();
    f->filename = strdup(seg); f->filesize = st.st_size;
    f->filetype = LIBMTP_FILETYPE_UNKNOWN; f->parent_id = send_parent; f->storage_id = sid;
    int r = LIBMTP_Send_File_From_File(dev, local, f, NULL, NULL);
    LIBMTP_destroy_file_t(f);
    printf("  %s %s: %s\n", old ? "replaced" : "added", remote, r ? "FAILED" : "ok");
    return r ? 1 : 0;
}

static int rm_tree(uint32_t id, int *count) {
    int bad = 0;
    LIBMTP_file_t *l = list(id);
    for (LIBMTP_file_t *f = l; f; f = f->next) {
        if (f->filetype == LIBMTP_FILETYPE_FOLDER) bad += rm_tree(f->item_id, count);
        else if (LIBMTP_Delete_Object(dev, f->item_id) == 0) { if (++*count % 200 == 0) fprintf(stderr, "    %d deleted\n", *count); }
        else { bad++; LIBMTP_Clear_Errorstack(dev); }
    }
    free_list(l);
    if (LIBMTP_Delete_Object(dev, id) != 0) { bad++; LIBMTP_Clear_Errorstack(dev); }
    return bad;
}

int main(int argc, char **argv) {
    int ai = 1, wait = 0;
    if (ai < argc && strcmp(argv[ai], "wait") == 0) { wait = 1; ai++; }
    LIBMTP_Init();
    LIBMTP_raw_device_t *raw = NULL; int nraw = 0;
    for (int t = 0; ; t++) {
        system("killall ptpcamerad 2>/dev/null");
        usleep(300000);
        if (LIBMTP_Detect_Raw_Devices(&raw, &nraw) == LIBMTP_ERROR_NONE && nraw > 0) {
            dev = LIBMTP_Open_Raw_Device_Uncached(&raw[0]);
            if (dev) break;
        }
        if (!wait || t > 900) { printf("NO KINDLE FOUND\n"); return 2; }
        if (t % 30 == 0) { printf("waiting for the Kindle...\n"); fflush(stdout); }
        sleep(1);
    }
    LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED);
    if (!dev->storage) { printf("no storage\n"); return 3; }
    sid = dev->storage->id;
    printf("connected: %s\n", LIBMTP_Get_Modelname(dev));
    int rc = 0;
    for (; ai < argc; ai++) {
        const char *a = argv[ai];
        printf("== %s\n", a); fflush(stdout);
        if (!strcmp(a, "ls")) do_ls();
        else if (!strcmp(a, "rmupd")) { const char *p[] = {"update*.bin", "*.bin.tmp.partial", "update*.partial", NULL}; rc |= do_rm_matching(p); }
        else if (!strcmp(a, "rmfill")) { const char *p[] = {"filler_[0-9][0-9].dat", NULL}; rc |= do_rm_matching(p); }
        else if (!strcmp(a, "fill") && ai + 1 < argc) rc |= do_fill(strtoull(argv[++ai], NULL, 10) * 1048576ULL);
        else if (!strcmp(a, "rename") && ai + 2 < argc) {
            const char *o = argv[++ai], *n = argv[++ai];
            int done = 0;
            LIBMTP_file_t *l = list(ROOT);
            for (LIBMTP_file_t *f = l; f; f = f->next)
                if (!strcmp(f->filename, o)) { done = LIBMTP_Set_File_Name(dev, f, n) == 0; break; }
            free_list(l);
            printf("  rename %s -> %s: %s\n", o, n, done ? "ok" : "FAILED"); rc |= !done;
        }
        else if (!strcmp(a, "putdir") && ai + 2 < argc) {
            const char *loc = argv[++ai], *nm = argv[++ai];
            if (find_root(nm)) { printf("  %s already exists on the Kindle, not touching it\n", nm); rc = 1; continue; }
            char *n2 = strdup(nm);
            uint32_t id = LIBMTP_Create_Folder(dev, n2, 0, sid);
            free(n2);
            if (!id) { printf("  mkdir failed\n"); rc = 1; continue; }
            int count = 0, bad = send_tree(loc, id, &count);
            printf("  copied %d files, %d problems\n", count, bad); rc |= bad ? 1 : 0;
        }
        else if (!strcmp(a, "put") && ai + 2 < argc) {
            const char *loc = argv[++ai], *dir = argv[++ai];
            uint32_t pid = find_root(dir);
            struct stat st;
            if (!pid || stat(loc, &st)) { printf("  missing folder or file\n"); rc = 1; continue; }
            const char *base = strrchr(loc, '/'); base = base ? base + 1 : loc;
            LIBMTP_file_t *f = LIBMTP_new_file_t();
            f->filename = strdup(base); f->filesize = st.st_size;
            f->filetype = LIBMTP_FILETYPE_UNKNOWN; f->parent_id = pid; f->storage_id = sid;
            int r = LIBMTP_Send_File_From_File(dev, loc, f, NULL, NULL);
            LIBMTP_destroy_file_t(f);
            printf("  put %s: %s\n", base, r ? "FAILED" : "ok"); rc |= r ? 1 : 0;
        }
        else if (!strcmp(a, "rmtree") && ai + 1 < argc) {
            const char *nm = argv[++ai];
            const char *protect[] = {"koreader", "documents", "system", "fonts", "libkh", "jobman", "kmc", "audible", "voice", "extensions", NULL};
            int prot = 0;
            for (const char **p = protect; *p; p++) if (!strcmp(*p, nm)) prot = 1;
            int isf = 0;
            uint32_t id = find_child(ROOT, nm, &isf);
            if (prot) { printf("  refusing to delete protected folder %s\n", nm); rc = 1; }
            else if (!id || !isf) { printf("  no folder %s\n", nm); rc = 1; }
            else { int count = 0, bad = rm_tree(id, &count); printf("  deleted %s: %d files, %d problems\n", nm, count, bad); rc |= bad ? 1 : 0; }
        }
        else if (!strcmp(a, "putpath") && ai + 2 < argc) { const char *l = argv[++ai]; rc |= do_putpath(l, argv[++ai]); }
        else { printf("  unknown action %s\n", a); rc = 1; }
    }
    LIBMTP_Release_Device(dev);
    printf(rc ? "DONE WITH PROBLEMS\n" : "ALL DONE\n");
    return rc;
}
