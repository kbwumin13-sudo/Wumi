#include "coilfind.h"
#include <errno.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/syslimits.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <unistd.h>
#include <mach/mach.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

static inline uint8_t fold(uint8_t x) { return (uint8_t)(x | (((uint8_t)(x - 'A') < 26) ? 0x20 : 0)); }
static inline int eq(uint8_t a, uint8_t b, int cs) { return cs ? a == b : fold(a) == b; }

#if defined(__aarch64__)
static inline uint8x16_t folded(uint8x16_t x, int cs) {
    if (cs) return x;
    uint8x16_t upper = vcltq_u8(vsubq_u8(x, vdupq_n_u8('A')), vdupq_n_u8(26));
    return vorrq_u8(x, vandq_u8(upper, vdupq_n_u8(0x20)));
}
static inline uint64_t mask16(uint8x16_t x) {
    uint8x8_t y = vshrn_n_u16(vreinterpretq_u16_u8(x), 4);
    return vget_lane_u64(vreinterpret_u64_u8(y), 0);
}
#endif
long sift_find(const uint8_t *hay, size_t len, size_t from, const uint8_t *needle, size_t nlen, int cs) {
    if (from > len) return -1;
    if (!nlen) return (long)from;
    if (nlen > len - from) return -1;
    size_t last = len - nlen, i = from;
#if defined(__aarch64__)
    uint8x16_t first = vdupq_n_u8(needle[0]), tail = vdupq_n_u8(needle[nlen-1]);
    while (i <= last && last - i >= 15) {
        uint8x16_t x = folded(vld1q_u8(hay + i), cs);
        uint8x16_t y = nlen == 1 ? x : folded(vld1q_u8(hay + i + nlen - 1), cs);
        uint64_t mask = mask16(vandq_u8(vceqq_u8(x, first), vceqq_u8(y, tail)));
        while (mask) {
            unsigned bit = (unsigned)__builtin_ctzll(mask);
            size_t p = i + bit / 4;
            size_t j = 1;
            for (; j + 1 < nlen && eq(hay[p+j], needle[j], cs); j++);
            if (j + 1 >= nlen) return (long)p;
            mask &= ~((uint64_t)15 << (bit & ~3u));
        }
        i += 16;
    }
#endif
    for (; i <= last; i++) {
        size_t j = 0;
        for (; j < nlen && eq(hay[i+j], needle[j], cs); j++);
        if (j == nlen) return (long)i;
    }
    return -1;
}
size_t sift_scan_entries(const uint8_t *blob, const uint32_t *off, uint32_t e0, uint32_t e1, const uint8_t *needle, size_t nlen, int cs, uint32_t *out, size_t cap, uint32_t *resume) {
    uint32_t e=e0; size_t pos=off[e0], end=off[e1], count=0;
    while (e<e1 && count<cap) {
        long found=sift_find(blob,end,pos,needle,nlen,cs);
        if (found<0) { e=e1; break; }
        size_t p=(size_t)found;
        while (e<e1 && off[e+1]<=p) e++;
        if (e>=e1) break;
        if (p+nlen<=off[e+1]) { out[count++]=e++; pos=off[e]; }
        else pos=p+1;
    }
    *resume=e; return count;
}
size_t sift_filter_entries(uint32_t e0,uint32_t e1,const uint8_t *flags,
                           const uint8_t *kind,uint16_t kind_mask,
                           const uint8_t *path_mask,uint32_t *out) {
    size_t count=0;
    for(uint32_t i=e0;i<e1;i++) {
        if((flags[i]&8) || !(kind_mask & (1u<<kind[i])) || (path_mask && !path_mask[i]))continue;
        out[count++]=i;
    }
    return count;
}
int sift_contains(const uint8_t *s,size_t len,const uint8_t *p,size_t plen,int cs) { return sift_find(s,len,0,p,plen,cs)>=0; }
size_t sift_scan_candidates(const uint32_t *ids,size_t count,const uint8_t *blob,
                            const uint32_t *off,const uint8_t *needle,size_t nlen,
                            int cs,int include_non_ascii,uint32_t *out) {
    size_t hits=0;
    for(size_t j=0;j<count;j++) {
        uint32_t id=ids[j]; const uint8_t *name=blob+off[id]; size_t len=off[id+1]-off[id];
        int hit=sift_contains(name,len,needle,nlen,cs);
        /* Alternate-key matches are verified by the shared scoring pipeline. */
        if(!hit && include_non_ascii) {
            for(size_t k=0;k<len;k++) { if(name[k]>=128) { hit=1; break; } }
        }
        if(hit) out[hits++]=id;
    }
    return hits;
}
int sift_has_prefix(const uint8_t *s,size_t len,const uint8_t *p,size_t plen,int cs) { return plen<=len && sift_find(s,plen,0,p,plen,cs)==0; }
int sift_has_suffix(const uint8_t *s,size_t len,const uint8_t *p,size_t plen,int cs) { return plen<=len && sift_find(s+len-plen,plen,0,p,plen,cs)==0; }
int sift_equals(const uint8_t *s,size_t len,const uint8_t *p,size_t plen,int cs) { return len==plen && sift_has_prefix(s,len,p,plen,cs); }
int sift_has_ancestor(uint32_t id, const uint32_t *parents, const uint8_t *names,
                      const uint32_t *offsets, const uint8_t *needle, size_t length) {
    for (uint32_t p = parents[id]; p; p = parents[p]) {
        size_t start = offsets[p], len = offsets[p + 1] - start;
        if (len == length && sift_equals(names + start, len, needle, length, 0)) return 1;
    }
    return 0;
}
int sift_match_quality(const uint8_t *name,size_t len,const uint8_t *needle,size_t nlen,int cs) {
    if (!nlen || nlen>len) return 0;
    int best=0;
    for(size_t p=0;p<=len-nlen;p++) {
        if (len<=64 || nlen<=2) {
            /* Avoid restarting the SIMD finder for each short-name match. */
            if(!eq(name[p],needle[0],cs)) continue;
            if(nlen>1) {
                if(!eq(name[p+nlen-1],needle[nlen-1],cs)) continue;
                size_t j=1;
                for(;j+1<nlen && eq(name[p+j],needle[j],cs);j++);
                if(j+1<nlen) continue;
            }
        } else {
            long found=sift_find(name,len,p,needle,nlen,cs);
            if(found<0) break;
            p=(size_t)found;
        }
        int q=1;
        if (!p) {
            q=3;
            if (nlen==len) q=4;
            else if (name[nlen]=='.' && !memchr(name+nlen+1,'.',len-nlen-1)) q=4;
        } else {
            uint8_t a=name[p-1], b=name[p];
            if (a==' '||a=='-'||a=='_'||a=='.'||a=='('||a=='['||a=='+'||a==',' ||
                (a>='a'&&a<='z'&&b>='A'&&b<='Z') || (a<0x80&&b>=0x80) ||
                ((a>='0'&&a<='9')&&((b>='a'&&b<='z')||(b>='A'&&b<='Z'))) ||
                ((b>='0'&&b<='9')&&((a>='a'&&a<='z')||(a>='A'&&a<='Z')))) q=2;
        }
        if (q>best) best=q;
        /* Later positions cannot improve a prefix or a word-boundary hit. */
        if (best>=2) break;
    }
    return best;
}
static size_t utf8step(const uint8_t *s,size_t n,size_t p) {
    if (p>=n) return p; size_t q=p+1; while(q<n && (s[q]&0xc0)==0x80) q++; return q;
}
int sift_glob_match(const uint8_t *pat,size_t plen,const uint8_t *s,size_t slen,int cs) {
    size_t p=0,i=0,star=(size_t)-1,back=0;
    while(i<slen) {
        if(p<plen && pat[p]=='*') { star=p++; back=i; }
        else if(p<plen && pat[p]=='?') { i=utf8step(s,slen,i); p++; }
        else if(p<plen && eq(s[i],pat[p],cs)) { i++; p++; }
        else if(star!=(size_t)-1 && back<slen) { back=utf8step(s,slen,back); i=back; p=star+1; }
        else return 0;
    }
    while(p<plen && pat[p]=='*') p++; return p==plen;
}
int sift_name_compare(const uint8_t *a,size_t alen,const uint8_t *b,size_t blen) {
    size_t i=0,j=0;
    while(i<alen && j<blen) {
        if(a[i]>='0'&&a[i]<='9'&&b[j]>='0'&&b[j]<='9') {
            size_t ai=i,bj=j; while(ai<alen&&a[ai]=='0')ai++; while(bj<blen&&b[bj]=='0')bj++;
            size_t ae=ai,be=bj; while(ae<alen&&a[ae]>='0'&&a[ae]<='9')ae++; while(be<blen&&b[be]>='0'&&b[be]<='9')be++;
            if(ae-ai!=be-bj)return ae-ai<be-bj?-1:1;
            int cmp=memcmp(a+ai,b+bj,ae-ai); if(cmp)return cmp<0?-1:1;
            size_t az=ae-i,bz=be-j; if(az!=bz)return az<bz?-1:1;
            i=ae;j=be;continue;
        }
        uint8_t x=fold(a[i]),y=fold(b[j]); if(x!=y)return x<y?-1:1; i++;j++;
    }
    return i==alen?(j==blen?0:-1):1;
}

void sift_score_name_batch(const uint32_t *ids,size_t count,const uint8_t *names,const uint32_t *name_off,
                           const uint8_t *flags,const uint8_t *kind,const uint8_t *depth,const uint32_t *mtime,
                           const uint8_t *needle,size_t needle_len,int cs,uint32_t now,int32_t *scores) {
    static const int base[5]={0,400,600,800,1000};
    for(size_t j=0;j<count;j++) {
        uint32_t id=ids[j]; size_t start=name_off[id],len=name_off[id+1]-start;
        int quality=sift_match_quality(names+start,len,needle,needle_len,cs);
        if(!quality) {
            scores[j]=OILFIND_SCORE_NO_MATCH;
            if(!cs) {
                for(size_t k=0;k<len;k++) {
                    if(names[start+k]>=128) { scores[j]=OILFIND_SCORE_FALLBACK; break; }
                }
            }
            continue;
        }
        int score=base[quality]-(int)(2*((len>needle_len && len-needle_len<64)?len-needle_len:(len>needle_len?64:0)));
        uint8_t f=flags[id];
        if((f&0x80) && !(f&(0x10|0x20|0x04)))score+=60;
        if(kind[id]==2)score+=150;
        if(kind[id]==1)score+=20;
        uint32_t age=now>=mtime[id]?now-mtime[id]:0;
        if(age<=86400)score+=60;
        else if(age<=604800)score+=45;
        else if(age<=2592000)score+=30;
        else if(age<=31536000)score+=10;
        if(f&0x10)score-=350;
        if(f&0x20)score-=300;
        if(f&0x04)score-=200;
        score-=5*(depth[id]<16?depth[id]:16);
        scores[j]=score;
    }
}

void sift_exclude_name_batch(const uint32_t *ids, size_t count,
                             const uint8_t *names, const uint32_t *name_off,
                             const uint32_t *parents, const uint8_t *flags,
                             const uint8_t *kind, int filter_kind, const uint8_t *needle,
                             size_t needle_len, int cs, int ancestors,
                             int root_matches, int32_t *scores) {
    for (size_t j = 0; j < count; j++) {
        if (scores[j] == OILFIND_SCORE_NO_MATCH) continue;
        uint32_t id = ids[j];
        if ((flags[id] & 0x08) || (filter_kind >= 0 && kind[id] != filter_kind)) {
            scores[j] = OILFIND_SCORE_NO_MATCH;
            continue;
        }
        if (scores[j] == OILFIND_SCORE_FALLBACK) continue;
        size_t start = name_off[id], len = name_off[id + 1] - start;
        if (root_matches || sift_contains(names + start, len, needle, needle_len, cs)) {
            scores[j] = OILFIND_SCORE_NO_MATCH;
            continue;
        }
        /* Unicode and pinyin exclusions use the shared alternate-key evaluator. */
        int non_ascii = 0;
        for (size_t k = 0; k < len; k++) {
            if (names[start + k] >= 128) { non_ascii = 1; break; }
        }
        if (non_ascii) scores[j] = OILFIND_SCORE_FALLBACK;
        else if (ancestors && sift_has_ancestor(id, parents, names, name_off, needle, needle_len)) scores[j] = OILFIND_SCORE_NO_MATCH;
    }
}

static size_t align4(size_t n) { return (n+3)&~(size_t)3; }
int sift_read_dir(int fd,void *scratch,size_t scratch_size,oilfind_dirent *out,int out_cap) {
    struct attrlist al={0}; al.bitmapcount=ATTR_BIT_MAP_COUNT;
    al.commonattr=ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_NAME|ATTR_CMN_ERROR|ATTR_CMN_DEVID|ATTR_CMN_OBJTYPE|ATTR_CMN_MODTIME|ATTR_CMN_FLAGS|ATTR_CMN_FILEID;
    al.fileattr=ATTR_FILE_DATALENGTH;
    int n; do { n=getattrlistbulk(fd,&al,scratch,scratch_size,0); } while(n<0&&errno==EINTR);
    if(n<=0)return n;
    if(n>out_cap) { errno=ENOBUFS; return -1; }
    uint8_t *cur=scratch,*limit=cur+scratch_size;
    for(int k=0;k<n;k++) {
        if(cur+sizeof(uint32_t)>limit) {errno=EIO;return -1;}
        uint32_t length; memcpy(&length,cur,4); if(length<8||cur+length>limit){errno=EIO;return -1;}
        uint8_t *end=cur+length,*p=cur+4; attribute_set_t got={0};
        if(p+sizeof(got)>end){errno=EIO;return -1;} memcpy(&got,p,sizeof(got));p+=sizeof(got);
        oilfind_dirent e={0};
#define TAKE(dst,sz) do { if(p+(sz)>end){errno=EIO;return -1;} memcpy(&(dst),p,(sz)); p+=align4(sz); } while(0)
        /* getattrlistbulk returns ERROR immediately after RETURNED_ATTRS. */
        if(got.commonattr&ATTR_CMN_ERROR) TAKE(e.error,sizeof(int32_t));
        if(got.commonattr&ATTR_CMN_NAME) { attrreference_t ref; uint8_t *refp=p; TAKE(ref,sizeof(ref)); uint8_t *str=refp+ref.attr_dataoffset; if(str<cur||str>=end){errno=EIO;return -1;} e.name=(const char*)str; e.name_len=(uint32_t)strnlen((const char*)str,(size_t)(end-str)); }
        if(got.commonattr&ATTR_CMN_DEVID) { dev_t v; TAKE(v,sizeof(v)); e.dev=v; }
        if(got.commonattr&ATTR_CMN_OBJTYPE) { fsobj_type_t v; TAKE(v,sizeof(v)); e.type=v==VDIR?1:v==VLNK?2:v==VREG?0:3; }
        if(got.commonattr&ATTR_CMN_MODTIME) { struct timespec v; TAKE(v,sizeof(v)); e.mtime=v.tv_sec; }
        if(got.commonattr&ATTR_CMN_FLAGS) TAKE(e.bsd_flags,sizeof(uint32_t));
        if(got.commonattr&ATTR_CMN_FILEID) TAKE(e.fileid,sizeof(uint64_t));
        if(got.fileattr&ATTR_FILE_DATALENGTH) TAKE(e.size,sizeof(uint64_t));
#undef TAKE
        /* Firmlink source IDs differ from the inode seen by open; capture the target
           through this verified parent before enqueueing the directory. */
        if(e.type==1 && (e.bsd_flags&SF_FIRMLINK)) {
            struct stat target;
            if(fstatat(fd,e.name,&target,AT_SYMLINK_NOFOLLOW)!=0) e.error=errno;
            else if(!S_ISDIR(target.st_mode)) e.error=ENOTDIR;
            else {
                e.fileid=target.st_ino; e.dev=target.st_dev; e.bsd_flags=target.st_flags;
                e.mtime=target.st_mtimespec.tv_sec;
            }
        }
        out[k]=e; cur=end;
    }
    return n;
}

uint64_t sift_entry_hash(uint32_t parent, const uint8_t *name, size_t len, int case_sensitive) {
    uint64_t h=UINT64_C(0xcbf29ce484222325);
    for(unsigned i=0;i<4;i++) h=(h^((parent>>(8*i))&255))*UINT64_C(0x100000001b3);
    for(size_t i=0;i<len;i++) h=(h^(case_sensitive?name[i]:fold(name[i])))*UINT64_C(0x100000001b3);
    return h;
}
void sift_build_hash(uint32_t *table,size_t capacity,const uint32_t *parents,
                     const uint8_t *names,const uint32_t *offsets,size_t count,
                     int case_sensitive) {
    memset(table,255,capacity*sizeof(uint32_t));
    for(size_t i=0;i<count;i++) {
        size_t slot=(size_t)(((__uint128_t)sift_entry_hash(parents[i],names+offsets[i],offsets[i+1]-offsets[i],case_sensitive)*capacity)>>64);
        while(table[slot]!=UINT32_MAX) slot=slot+1==capacity?0:slot+1;
        table[slot]=(uint32_t)i;
    }
}
void sift_sweep(uint8_t *flags,const uint32_t *parents,size_t count,uint32_t *removed) {
    uint32_t n=0;
    for(size_t i=1;i<count;i++) if(!(flags[i]&8) && (flags[parents[i]]&8)) { flags[i]|=8; n++; }
    *removed=n;
}

int sift_name_equal_folded(const uint8_t *a,size_t alen,const uint8_t *b,size_t blen) {
    if(alen!=blen)return 0;
    for(size_t i=0;i<alen;i++)if(fold(a[i])!=fold(b[i]))return 0;
    return 1;
}

int sift_name_equal(const uint8_t *a,size_t alen,const uint8_t *b,size_t blen,int case_sensitive) {
    if(alen!=blen)return 0;
    if(case_sensitive)return memcmp(a,b,alen)==0;
    return sift_name_equal_folded(a,alen,b,blen);
}

int sift_validate_index(const uint32_t *name_off,const uint32_t *parent,const uint8_t *kind,
                        size_t count,size_t names_len,
                        const uint32_t *alt_off,const uint32_t *alt_owner,
                        size_t alt_count,size_t alt_len,
                        uint32_t home_index,uint32_t deleted_count) {
    if(!count || names_len>UINT32_MAX || alt_len>UINT32_MAX)return 0;
    if(name_off[0]!=0 || name_off[count]!=names_len || parent[0]!=0)return 0;
    for(size_t i=1;i<=count;i++)if(name_off[i]<name_off[i-1])return 0;
    for(size_t i=0;i<count;i++) {
        if(kind[i]>8)return 0;
        if(i && parent[i]>=i)return 0;
    }
    if(alt_off[0]!=0 || alt_off[alt_count]!=alt_len)return 0;
    for(size_t i=1;i<=alt_count;i++)if(alt_off[i]<alt_off[i-1])return 0;
    for(size_t i=0;i<alt_count;i++) {
        if(alt_owner[i]>=count)return 0;
        if(i && alt_owner[i]<alt_owner[i-1])return 0;
    }
    if(home_index!=UINT32_MAX && home_index>=count)return 0;
    if(deleted_count>count)return 0;
    return 1;
}

int sift_actual_name(const char *path,uint8_t *out,size_t capacity) {
    struct attrlist al={0}; al.bitmapcount=ATTR_BIT_MAP_COUNT; al.commonattr=ATTR_CMN_NAME;
    struct { uint32_t length; attrreference_t ref; char bytes[1024]; } value;
    if(getattrlist(path,&al,&value,sizeof(value),FSOPT_NOFOLLOW)!=0)return -1;
    const char *name=(const char *)&value.ref+value.ref.attr_dataoffset;
    size_t n=strnlen(name,value.ref.attr_length);
    if(n>capacity)return -1;
    memcpy(out,name,n); return (int)n;
}

uint64_t sift_resident_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if(task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count)!=KERN_SUCCESS)return 0;
    return info.resident_size;
}
