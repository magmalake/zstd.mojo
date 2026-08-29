/*
 * zstd.mojo — minimal libzstd wrapper for Mojo FFI.
 *
 * Mirrors zlib.mojo's shim pattern (ffi/zlib_wrapper.c): thin, ABI-hygienic
 * C functions that hide the parts of libzstd's API that don't map cleanly
 * across the FFI boundary — building ZSTD_inBuffer/ZSTD_outBuffer structs,
 * and libzstd's size_t-with-magic-sentinel error signaling. Everything else
 * (level, frame sizes, error codes/names) passes straight through so the
 * Mojo side can use libzstd's own ZSTD_isError / ZSTD_getErrorName directly.
 *
 * Build: shim/pixi.toml (pixi-build-cmake) -> $CONDA_PREFIX/lib/libzstdmojo.so
 */

#include <zstd.h>
#include <zstd_errors.h>
#include <string.h>

/* ------------------------------------------------------------------------ */
/* One-shot                                                                  */
/* ------------------------------------------------------------------------ */

size_t zstdm_compress_bound(size_t src_len) {
    return ZSTD_compressBound(src_len);
}

size_t zstdm_compress(const void *src, size_t src_len,
                      void *dst, size_t dst_cap, int level) {
    return ZSTD_compress(dst, dst_cap, src, src_len, level);
}

size_t zstdm_decompress(const void *src, size_t src_len,
                        void *dst, size_t dst_cap) {
    return ZSTD_decompress(dst, dst_cap, src, src_len);
}

/*
 * Frame content size, normalized to a value Mojo can branch on with a plain
 * signed comparison: >=0 known size, -1 unknown (e.g. streamed with no
 * recorded size), -2 error (not a valid zstd frame header). Mirrors
 * ZSTD_getFrameContentSize's unsigned-wraparound sentinels
 * (ZSTD_CONTENTSIZE_UNKNOWN / ZSTD_CONTENTSIZE_ERROR) without exposing that
 * comparison to the Mojo side.
 */
long long zstdm_frame_content_size(const void *src, size_t src_len) {
    unsigned long long sz = ZSTD_getFrameContentSize(src, src_len);
    if (sz == ZSTD_CONTENTSIZE_UNKNOWN) return -1;
    if (sz == ZSTD_CONTENTSIZE_ERROR) return -2;
    return (long long)sz;
}

int zstdm_is_error(size_t code) {
    return ZSTD_isError(code) ? 1 : 0;
}

const char *zstdm_error_name(size_t code) {
    return ZSTD_getErrorName(code);
}

/* ------------------------------------------------------------------------ */
/* Streaming: compress (ZSTD_CCtx doubles as the modern ZSTD_CStream)        */
/* ------------------------------------------------------------------------ */

void *zstdm_create_cctx(void) {
    return (void *)ZSTD_createCCtx();
}

size_t zstdm_free_cctx(void *cctx) {
    return ZSTD_freeCCtx((ZSTD_CCtx *)cctx);
}

size_t zstdm_cctx_set_level(void *cctx, int level) {
    return ZSTD_CCtx_setParameter((ZSTD_CCtx *)cctx, ZSTD_c_compressionLevel, level);
}

/*
 * Feeds src[*src_pos .. src_len) through the streaming compressor, writing
 * into dst[*dst_pos .. dst_cap). Builds the ZSTD_inBuffer/ZSTD_outBuffer
 * structs internally (Mojo never replicates their layout) and writes back
 * the advanced positions in place. end_op: 0 = continue, 1 = flush,
 * 2 = end (matches ZSTD_EndDirective, stable since libzstd 1.4).
 *
 * Returns the ZSTD_compressStream2 hint (>=0; 0 after end_op=2 means the
 * frame is fully flushed) or a libzstd error code — check with
 * zstdm_is_error / zstdm_error_name.
 */
size_t zstdm_compress_stream2(
    void *cctx,
    const void *src, size_t src_len, size_t *src_pos,
    void *dst, size_t dst_cap, size_t *dst_pos,
    int end_op
) {
    ZSTD_inBuffer in;
    ZSTD_outBuffer out;
    size_t ret;

    memset(&in, 0, sizeof(in));
    in.src = src;
    in.size = src_len;
    in.pos = *src_pos;

    memset(&out, 0, sizeof(out));
    out.dst = dst;
    out.size = dst_cap;
    out.pos = *dst_pos;

    ret = ZSTD_compressStream2(
        (ZSTD_CCtx *)cctx, &out, &in, (ZSTD_EndDirective)end_op
    );

    *src_pos = in.pos;
    *dst_pos = out.pos;
    return ret;
}

/* ------------------------------------------------------------------------ */
/* Streaming: decompress (ZSTD_DCtx doubles as the modern ZSTD_DStream)      */
/* ------------------------------------------------------------------------ */

void *zstdm_create_dctx(void) {
    return (void *)ZSTD_createDCtx();
}

size_t zstdm_free_dctx(void *dctx) {
    return ZSTD_freeDCtx((ZSTD_DCtx *)dctx);
}

/*
 * Same shape as zstdm_compress_stream2 for the decompress side. Returns 0
 * when a frame is exactly finished, >0 as a hint of how many more input
 * bytes a well-formed frame likely needs next, or an error code.
 */
size_t zstdm_decompress_stream(
    void *dctx,
    const void *src, size_t src_len, size_t *src_pos,
    void *dst, size_t dst_cap, size_t *dst_pos
) {
    ZSTD_inBuffer in;
    ZSTD_outBuffer out;
    size_t ret;

    memset(&in, 0, sizeof(in));
    in.src = src;
    in.size = src_len;
    in.pos = *src_pos;

    memset(&out, 0, sizeof(out));
    out.dst = dst;
    out.size = dst_cap;
    out.pos = *dst_pos;

    ret = ZSTD_decompressStream((ZSTD_DCtx *)dctx, &out, &in);

    *src_pos = in.pos;
    *dst_pos = out.pos;
    return ret;
}
