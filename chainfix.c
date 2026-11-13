/*
 * chainfix.c - FLEX disk chain checker / free-chain relinker for Linux
 *
 * A C re-implementation of CHAINFIX V1.0 (Caterpillar Software, FLEX09)
 * that operates on raw FLEX disk image files (e.g. hdflex2.dsk).
 *
 * Steps (as in the original):
 *   1. Build a map of every sector owned by the system area, directory
 *      and each file.
 *   2. Build a map of the free chain.
 *   3. Report collisions (sector in a file AND in the free chain).
 *   4. Report misses (sector in neither).
 *   5. Optionally relink the free chain from every unowned sector.
 *
 * Fixes relative to the 6809 original (see analysis.md):
 *   - collision scan does not restart forever (orig. BRA $0273 bug)
 *   - chain traces stop at an intersection, so loops can't hang
 *   - links are range-checked; a bad link is reported, not fatal
 *   - an empty free chain (full disk) is handled
 *   - the directory is traced from 00/05, not via 00/04's link
 *   - free-chain tail is initialised; whole T/S space is scanned
 *   - relink is done in memory and committed atomically (tmp+rename)
 *
 * Image format: raw sector dump, track 0 first, sectors 1..N per track,
 * 256 bytes per sector, no header.  Geometry comes from the SIR
 * (track 0 sector 3, max track at +$26, max sector at +$27).  If track 0
 * has fewer sectors than the other tracks this is detected from the
 * image size, or can be given with -0.
 *
 * Build:  cc -O2 -Wall -o chainfix chainfix.c
 */

#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <libgen.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SECSIZE     256
#define NTS         65536u          /* 16-bit track/sector space   */

/* SIR offsets (within sector 00/03) */
#define SIR_LABEL   0x10
#define SIR_VOLNUM  0x1B
#define SIR_FREE_ST 0x1D
#define SIR_FREE_EN 0x1F
#define SIR_FREE_CT 0x21
#define SIR_MAXTRK  0x26
#define SIR_MAXSEC  0x27

/* Directory sector layout */
#define DIR_FIRST   0x0005          /* 00/05 */
#define DIR_HDR     16
#define DIR_ENTSZ   24
#define DIR_NENT    10

/* Owner ids in the file map */
#define OWN_NONE    0u
#define OWN_SYSTEM  1u
#define OWN_DIR     2u
#define OWN_FILE0   3u              /* file i -> OWN_FILE0 + i     */
#define OWN_FREE    1u              /* id used in the free map     */

/* trace result flags */
#define TR_INTERSECT 1
#define TR_LOOP      2
#define TR_BADLINK   4

typedef struct {
    char     name[13];              /* "NAME.EXT"                  */
    uint16_t start, end, count;
    uint8_t  random;
    uint16_t last;                  /* last sector reached         */
    unsigned traced;                /* sectors traced              */
    int      flags;
} fileent_t;

/* ---- globals --------------------------------------------------------- */

static uint8_t  *img;
static size_t    imgsize;
static unsigned  maxtrk, maxsec, t0sec;
static uint32_t *fileown;           /* owner id per T/S            */
static uint32_t *freeown;           /* OWN_FREE if on free chain   */
static fileent_t *files;
static size_t    nfiles, capfiles;
static int       quiet;

/* column-wrapped T/S list printer (16 per line, like the original) */
static int listcol;
static void list_begin(void) { listcol = 0; }
static void list_ts(unsigned ts)
{
    printf("%04X%c", ts, (++listcol % 16) ? ' ' : '\n');
}
static void list_end(void) { if (listcol % 16) putchar('\n'); }

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("chainfix: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

/* ---- geometry / sector access --------------------------------------- */

static unsigned spt(unsigned trk) { return trk == 0 ? t0sec : maxsec; }

static int valid_ts(unsigned ts)
{
    unsigned t = ts >> 8, s = ts & 0xFF;
    return t <= maxtrk && s >= 1 && s <= spt(t);
}

static uint8_t *sector(unsigned ts)
{
    unsigned t = ts >> 8, s = ts & 0xFF;
    size_t lba = (t == 0) ? (s - 1)
                          : t0sec + (size_t)(t - 1) * maxsec + (s - 1);
    return img + lba * SECSIZE;
}

static unsigned get16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static void put16(uint8_t *p, unsigned v) { p[0] = v >> 8; p[1] = v & 0xFF; }
static unsigned link_of(unsigned ts) { return get16(sector(ts)); }

static const char *owner_name(uint32_t id)
{
    switch (id) {
    case OWN_NONE:   return "(none)";
    case OWN_SYSTEM: return "<system>";
    case OWN_DIR:    return "<directory>";
    default:         return files[id - OWN_FILE0].name;
    }
}

/* ---- chain tracing ---------------------------------------------------- */

/*
 * Follow a chain from 'start', marking each sector in 'own' with 'id'.
 * Stops at link 00/00, at a bad link, or at the first sector that is
 * already owned (intersection or loop).  Returns TR_* flags.
 */
static int trace(unsigned start, uint32_t id, uint32_t *own,
                 const char *what, unsigned *plast, unsigned *pcount)
{
    unsigned ts = start, prev = 0, n = 0;
    int r = 0;

    while (ts != 0) {
        if (!valid_ts(ts)) {
            printf("  %s: bad link to %04X (from %04X)\n",
                   what, ts, prev);
            r |= TR_BADLINK;
            break;
        }
        if (own[ts] != OWN_NONE) {
            if (own[ts] == id) {
                printf("  %s: chain loops back to %04X (from %04X)\n",
                       what, ts, prev);
                r |= TR_LOOP;
            } else {
                printf("  %s: intersection at %04X with %s\n",
                       what, ts, own == fileown ? owner_name(own[ts])
                                                : "free chain");
                r |= TR_INTERSECT;
            }
            break;
        }
        own[ts] = id;
        n++;
        prev = ts;
        ts = link_of(ts);
    }
    if (plast)  *plast = prev;
    if (pcount) *pcount = n;
    return r;
}

/* ---- directory -------------------------------------------------------- */

static void fmt_name(char *dst, const uint8_t *e)
{
    int i, k = 0;
    for (i = 0; i < 8 && e[i]; i++) dst[k++] = e[i] & 0x7F;
    dst[k++] = '.';
    for (i = 8; i < 11 && e[i]; i++) dst[k++] = e[i] & 0x7F;
    dst[k] = 0;
}

static void add_file(const uint8_t *e)
{
    fileent_t *f;
    if (nfiles == capfiles) {
        capfiles = capfiles ? capfiles * 2 : 256;
        files = realloc(files, capfiles * sizeof *files);
        if (!files) die("out of memory");
    }
    f = &files[nfiles++];
    memset(f, 0, sizeof *f);
    fmt_name(f->name, e);
    f->start  = get16(e + 13);
    f->end    = get16(e + 15);
    f->count  = get16(e + 17);
    f->random = e[19];
}

/*
 * Walk the directory chain (already marked as OWN_DIR) and collect files.
 * FLEX treats the first never-used entry (name byte 0) as the end of the
 * directory, but damaged disks can have live entries after one; freeing
 * those files' sectors would be disastrous, so the whole chain is
 * scanned and a warning is given.  -s restores the strict FLEX rule.
 */
static int strict_dir;
static unsigned after_end;          /* live entries after a 0 entry */

static void read_directory(void)
{
    unsigned ts = DIR_FIRST, guard = 0;
    int seen_end = 0;
    while (ts != 0 && valid_ts(ts) && fileown[ts] == OWN_DIR &&
           guard++ < NTS) {
        const uint8_t *p = sector(ts);
        for (int i = 0; i < DIR_NENT; i++) {
            const uint8_t *e = p + DIR_HDR + i * DIR_ENTSZ;
            if (e[0] == 0) {                /* never used             */
                if (strict_dir) return;
                if (!seen_end && !quiet)
                    printf("  (directory end marker at %04X entry %d)\n",
                           ts, i);
                seen_end = 1;
                continue;
            }
            if (e[0] & 0x80) continue;      /* deleted                */
            if (seen_end) after_end++;
            add_file(e);
        }
        ts = link_of(ts);
    }
}

/* ---- main checking pipeline ------------------------------------------ */

struct stats {
    unsigned files_intersected, file_intersections, file_loops;
    unsigned file_badlinks, bad_ends, bad_counts;
    unsigned free_problems, collisions, misses;
    unsigned free_count, free_last;
    int      sys_problems;
};

static void check(struct stats *st)
{
    uint8_t *sir = sector(0x0003);
    unsigned ts, last, n;

    memset(st, 0, sizeof *st);

    /* system sectors 00/01..00/04 */
    for (ts = 1; ts <= 4 && ts <= t0sec; ts++)
        fileown[ts] = OWN_SYSTEM;

    /* directory chain from 00/05 */
    if (!quiet) printf("Building the file map.\n");
    st->sys_problems = trace(DIR_FIRST, OWN_DIR, fileown, "<directory>",
                             NULL, &n);
    if (!quiet) printf("  directory: %u sectors\n", n);

    read_directory();

    for (size_t i = 0; i < nfiles; i++) {
        fileent_t *f = &files[i];
        if (!quiet) printf("  %-12s", f->name);
        if (f->start == 0) {
            if (!quiet) putchar('\n');
            if (f->end != 0) {
                printf("  %s: empty file but end T/S is %04X\n",
                       f->name, f->end);
                st->bad_ends++;
            }
            continue;
        }
        if (!quiet) printf(" %04X-%04X %5u sectors\n",
                           f->start, f->end, f->count);
        f->flags = trace(f->start, OWN_FILE0 + (uint32_t)i, fileown,
                         f->name, &last, &f->traced);
        f->last = last;
        if (f->flags & TR_INTERSECT) { st->files_intersected++;
                                       st->file_intersections++; }
        if (f->flags & TR_LOOP)      { st->files_intersected++;
                                       st->file_loops++; }
        if (f->flags & TR_BADLINK)     st->file_badlinks++;
        if (f->flags) continue;     /* end/count meaningless now   */
        if (last != f->end) {
            printf("  %s: file end INCORRECT: directory %04X, chain %04X\n",
                   f->name, f->end, last);
            st->bad_ends++;
        }
        if (f->traced != f->count) {
            printf("  %s: sector count mismatch: directory %u, chain %u\n",
                   f->name, f->count, f->traced);
            st->bad_counts++;
        }
    }

    /* free chain */
    if (!quiet) printf("Building the free map.\n");
    {
        unsigned head = get16(sir + SIR_FREE_ST);
        unsigned tail = get16(sir + SIR_FREE_EN);
        unsigned cnt  = get16(sir + SIR_FREE_CT);
        int r = trace(head, OWN_FREE, freeown, "free chain", &last, &n);
        st->free_count = n;
        st->free_last  = last;
        if (r) st->free_problems++;
        if (!r && last != tail) {
            printf("  free chain: end INCORRECT: SIR %04X, chain %04X\n",
                   tail, last);
            st->free_problems++;
        }
        if (n != cnt) {
            printf("  free chain: count mismatch: SIR %u, chain %u\n",
                   cnt, n);
            st->free_problems++;
        }
        if (!quiet) printf("  free chain: %u sectors\n", n);
    }

    /* collisions */
    if (!quiet) printf("Checking for collisions.\n");
    list_begin();
    for (ts = 0; ts < NTS; ts++)
        if (fileown[ts] && freeown[ts]) {
            list_ts(ts);
            st->collisions++;
        }
    list_end();
    if (st->collisions && !quiet) {
        /* name the files involved */
        uint32_t prev = OWN_NONE;
        for (ts = 0; ts < NTS; ts++)
            if (fileown[ts] && freeown[ts] && fileown[ts] != prev) {
                printf("  free chain overlaps %s\n",
                       owner_name(fileown[ts]));
                prev = fileown[ts];
            }
    }

    /* misses */
    if (!quiet) printf("Checking for misses.\n");
    list_begin();
    for (ts = 0; ts < NTS; ts++)
        if (valid_ts(ts) && !fileown[ts] && !freeown[ts]) {
            list_ts(ts);
            st->misses++;
        }
    list_end();
}

/* ---- relink ------------------------------------------------------------ */

static unsigned relink(int zerofill)
{
    uint8_t *sir;
    unsigned head = 0, tail = 0, count = 0;

    /* walk downwards so the resulting chain ascends */
    for (int ts = NTS - 1; ts > 0; ts--) {
        if (!valid_ts(ts) || fileown[ts] != OWN_NONE)
            continue;
        uint8_t *p = sector(ts);
        if (zerofill)
            memset(p, 0, SECSIZE);
        else
            put16(p + 2, 0);        /* clear record number         */
        put16(p, head);             /* link to next higher free    */
        if (head == 0) tail = ts;
        head = ts;
        count++;
    }
    sir = sector(0x0003);
    put16(sir + SIR_FREE_ST, head);
    put16(sir + SIR_FREE_EN, tail);
    put16(sir + SIR_FREE_CT, count);
    return count;
}

/* write the whole image to 'path' atomically */
static void commit(const char *path, mode_t mode)
{
    char *dup = strdup(path), *dir = dirname(dup);
    size_t len = strlen(dir) + 32;
    char *tmp = malloc(len);
    int fd;

    snprintf(tmp, len, "%s/.chainfix.XXXXXX", dir);
    fd = mkstemp(tmp);
    if (fd < 0) die("cannot create temp file in %s: %s", dir, strerror(errno));
    if (write(fd, img, imgsize) != (ssize_t)imgsize || fsync(fd) != 0) {
        unlink(tmp);
        die("write to %s failed: %s", tmp, strerror(errno));
    }
    fchmod(fd, mode);
    close(fd);
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        die("rename %s -> %s failed: %s", tmp, path, strerror(errno));
    }
    free(tmp);
    free(dup);
}

/* ---- main --------------------------------------------------------------- */

static void usage(void)
{
    fprintf(stderr,
        "usage: chainfix [options] image.dsk\n"
        "  -n          report only, never relink\n"
        "  -y          relink without asking\n"
        "  -F          allow relink even if file chains are damaged\n"
        "  -o FILE     write the relinked image to FILE (default: in place)\n"
        "  -z          zero-fill free sectors when relinking (as original)\n"
        "  -0 N        track 0 has N sectors (default: auto)\n"
        "  -q          quiet: only print problems and totals\n"
        "  -s          strict FLEX directory: stop at first never-used entry\n"
        "exit status: 0 clean, 1 problems found, 2 error\n");
    exit(2);
}

int main(int argc, char **argv)
{
    int opt, never = 0, yes = 0, force = 0, zerofill = 0;
    const char *outpath = NULL, *path;
    int t0opt = -1;
    struct stats st;
    struct stat sb;
    FILE *fp;

    while ((opt = getopt(argc, argv, "nyFo:z0:qsh")) != -1) {
        switch (opt) {
        case 'n': never = 1; break;
        case 'y': yes = 1; break;
        case 'F': force = 1; break;
        case 'o': outpath = optarg; break;
        case 'z': zerofill = 1; break;
        case '0': t0opt = atoi(optarg); break;
        case 'q': quiet = 1; break;
        case 's': strict_dir = 1; break;
        default:  usage();
        }
    }
    if (optind != argc - 1) usage();
    path = argv[optind];

    /* load image */
    if (!(fp = fopen(path, "rb"))) die("%s: %s", path, strerror(errno));
    if (fstat(fileno(fp), &sb) != 0) die("%s: %s", path, strerror(errno));
    imgsize = sb.st_size;
    if (imgsize < 5 * SECSIZE || imgsize % SECSIZE)
        die("%s: size %zu is not a whole number of sectors", path, imgsize);
    if (!(img = malloc(imgsize))) die("out of memory");
    if (fread(img, 1, imgsize, fp) != imgsize) die("%s: read error", path);
    fclose(fp);

    /* geometry from the SIR (00/03 is always the third sector) */
    maxtrk = img[2 * SECSIZE + SIR_MAXTRK];
    maxsec = img[2 * SECSIZE + SIR_MAXSEC];
    if (maxsec == 0) die("SIR max sector is 0 - not a FLEX disk?");
    {
        size_t nsec = imgsize / SECSIZE;
        size_t uni  = (size_t)(maxtrk + 1) * maxsec;
        if (t0opt >= 0) {
            t0sec = t0opt;
        } else if (nsec >= uni) {
            t0sec = maxsec;
            if (nsec > uni)
                fprintf(stderr, "chainfix: warning: %zu extra sectors "
                        "beyond SIR geometry ignored\n", nsec - uni);
        } else if (nsec > (size_t)maxtrk * maxsec &&
                   nsec - (size_t)maxtrk * maxsec >= 5) {
            t0sec = nsec - (size_t)maxtrk * maxsec;
            fprintf(stderr, "chainfix: track 0 has %u sectors "
                    "(from image size)\n", t0sec);
        } else {
            die("image has %zu sectors, SIR says %u tracks x %u sectors; "
                "use -0", nsec, maxtrk + 1, maxsec);
        }
        if (t0sec < 5 || t0sec > 255) die("bad track 0 sector count %u", t0sec);
        if (t0sec + (size_t)maxtrk * maxsec > nsec)
            die("image too small for geometry");
    }

    {
        const uint8_t *sir = sector(0x0003);
        char label[12] = {0};
        for (int i = 0; i < 11 && sir[SIR_LABEL + i]; i++)
            label[i] = sir[SIR_LABEL + i] & 0x7F;
        printf("CHAINFIX (Linux) - %s\n", path);
        printf("Volume %s #%u, tracks 0-%u, sectors 1-%u", label,
               get16(sir + SIR_VOLNUM), maxtrk, maxsec);
        if (t0sec != maxsec) printf(" (track 0: 1-%u)", t0sec);
        printf("\n\n");
    }

    fileown = calloc(NTS, sizeof *fileown);
    freeown = calloc(NTS, sizeof *freeown);
    if (!fileown || !freeown) die("out of memory");

    check(&st);

    unsigned problems = st.files_intersected + st.file_badlinks +
        st.bad_ends + st.bad_counts + st.free_problems +
        st.collisions + st.misses + (st.sys_problems ? 1 : 0) + after_end;

    printf("\n");
    printf("Files                          - %zu\n", nfiles);
    printf("Free sectors (chain)           - %u\n", st.free_count);
    printf("Total number files intersected - %u\n", st.files_intersected);
    printf("  cross-linked / looped        - %u / %u\n",
           st.file_intersections, st.file_loops);
    printf("Files with bad links           - %u\n", st.file_badlinks);
    printf("Files with bad end / count     - %u / %u\n",
           st.bad_ends, st.bad_counts);
    printf("Free chain problems            - %u\n", st.free_problems);
    printf("File/free collisions (sectors) - %u\n", st.collisions);
    printf("Total number of missed sectors - %u\n", st.misses);

    if (st.sys_problems)
        printf("\nWARNING: the directory chain itself is damaged.\n");
    if (after_end)
        printf("\nWARNING: %u live directory entries follow a never-used "
               "entry.\nFLEX itself may not see these files.\n", after_end);

    if (problems == 0) {
        printf("\nDisk is consistent.\n");
        return 0;
    }
    if (never)
        return 1;

    if (!force && (st.file_badlinks || st.files_intersected ||
                   st.sys_problems)) {
        printf("\nFile chains are damaged; relinking would free sectors "
               "that may still\nbelong to files. Repair the files first, "
               "or use -F to relink anyway.\n");
        return 1;
    }
    if (!st.collisions && !st.misses && !st.free_problems) {
        printf("\nFree chain is consistent; nothing to relink.\n");
        return 1;
    }

    if (!yes) {
        char buf[16];
        if (!isatty(STDIN_FILENO)) {
            printf("\nNot a terminal; use -y to relink.\n");
            return 1;
        }
        printf("\nRelink the free chain (Y/N) ");
        fflush(stdout);
        if (!fgets(buf, sizeof buf, stdin) || (buf[0] & 0x5F) != 'Y')
            return 1;
    }

    printf("Relinking the free chain.\n");
    unsigned nfree = relink(zerofill);
    commit(outpath ? outpath : path, sb.st_mode & 07777);
    printf("New free chain: %u sectors, written to %s\n",
           nfree, outpath ? outpath : path);
    printf("Chain fix program complete.\n");
    return 1;
}
