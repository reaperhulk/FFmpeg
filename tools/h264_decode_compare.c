/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Linux-only, single-thread, cached-packet A/B benchmark.
 * See tools/h264-optimization-notes.md for build and measurement instructions.
 * Compile with H264_BENCH_VARIANT to build each isolated decoder library.
 */
#define _GNU_SOURCE
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/error.h"

static void check(int ret)
{
    if (ret < 0) {
        fprintf(stderr, "%s\n", av_err2str(ret));
        exit(1);
    }
}

#ifdef H264_BENCH_VARIANT
#include "libavutil/cpu.h"

typedef struct Decoder {
    AVCodecContext *ctx;
    AVFrame *frame;
} Decoder;

void *decoder_open(const AVCodecParameters *params)
{
    Decoder *d = av_mallocz(sizeof(*d));
    if (!d)
        exit(1);
#ifdef H264_BENCH_NO_BMI2
    av_force_cpu_flags(av_get_cpu_flags() & ~AV_CPU_FLAG_BMI2);
#endif
    d->ctx = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_H264));
    d->frame = av_frame_alloc();
    if (!d->ctx || !d->frame)
        exit(1);
    check(avcodec_parameters_to_context(d->ctx, params));
    d->ctx->thread_count = 1;
    check(avcodec_open2(d->ctx, d->ctx->codec, NULL));
    return d;
}

int decoder_packet(void *opaque, const AVPacket *pkt)
{
    Decoder *d = opaque;
    int frames = 0, ret;
    check(avcodec_send_packet(d->ctx, pkt));
    while ((ret = avcodec_receive_frame(d->ctx, d->frame)) >= 0) {
        av_frame_unref(d->frame);
        frames++;
    }
    if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF)
        check(ret);
    return frames;
}

void decoder_flush(void *opaque)
{
    Decoder *d = opaque;
    avcodec_flush_buffers(d->ctx);
}

void decoder_close(void *opaque)
{
    Decoder *d = opaque;
    avcodec_free_context(&d->ctx);
    av_frame_free(&d->frame);
    av_free(d);
}

#else
#include <dlfcn.h>

typedef struct Variant {
    void *library, *decoder;
    void *(*open)(const AVCodecParameters *);
    int (*send)(void *, const AVPacket *);
    void (*flush)(void *);
    void (*close)(void *);
} Variant;

static double seconds(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t))
        exit(1);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int compare_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void *symbol(void *library, const char *name)
{
    void *result = dlsym(library, name);
    if (!result) {
        fprintf(stderr, "%s\n", dlerror());
        exit(1);
    }
    return result;
}

int main(int argc, char **argv)
{
    AVFormatContext *fmt = NULL;
    AVPacket *pkt, **packets = NULL;
    Variant v[2] = { 0 };
    double *times;
    int stream, count = 0, loops, runs, ret;

    if (argc != 6 || (loops = atoi(argv[4])) < 1 ||
        (runs = atoi(argv[5])) < 1) {
        fprintf(stderr, "Usage: %s INPUT BASELINE.so CANDIDATE.so LOOPS RUNS\n", argv[0]);
        return 1;
    }
    av_log_set_level(AV_LOG_ERROR);
    check(avformat_open_input(&fmt, argv[1], NULL, NULL));
    check(avformat_find_stream_info(fmt, NULL));
    stream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    check(stream);
    if (fmt->streams[stream]->codecpar->codec_id != AV_CODEC_ID_H264)
        return 1;
    pkt = av_packet_alloc();
    if (!pkt)
        return 1;
    while ((ret = av_read_frame(fmt, pkt)) >= 0) {
        if (pkt->stream_index == stream) {
            AVPacket **tmp;
            if (count == INT_MAX - 1)
                return 1;
            tmp = av_realloc_array(packets, count + 1, sizeof(*packets));
            if (!tmp)
                return 1;
            packets = tmp;
            packets[count] = av_packet_clone(pkt);
            if (!packets[count++])
                return 1;
        }
        av_packet_unref(pkt);
    }
    if (ret != AVERROR_EOF)
        check(ret);
    if (!count || (size_t)(count + 1) > SIZE_MAX / 2 / loops / sizeof(*times))
        return 1;
    times = av_malloc_array(2 * (size_t)(count + 1) * loops, sizeof(*times));
    if (!times)
        return 1;
    for (int i = 0; i < 2; i++) {
        v[i].library = dlopen(argv[2 + i], RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
        if (!v[i].library) {
            fprintf(stderr, "%s\n", dlerror());
            return 1;
        }
        v[i].open  = symbol(v[i].library, "decoder_open");
        v[i].send  = symbol(v[i].library, "decoder_packet");
        v[i].flush = symbol(v[i].library, "decoder_flush");
        v[i].close = symbol(v[i].library, "decoder_close");
        v[i].decoder = v[i].open(fmt->streams[stream]->codecpar);
        if (!v[i].decoder)
            return 1;
    }
    puts("run,frames,baseline_cpu,candidate_cpu,speedup,median_packet_baseline,median_packet_candidate,median_speedup");
    for (int run = 0; run < runs; run++) {
        double total[2] = { 0 }, median[2] = { 0 };
        int64_t frames[2] = { 0 };
        for (int loop = 0; loop < loops; loop++) {
            v[0].flush(v[0].decoder);
            v[1].flush(v[1].decoder);
            for (int packet = 0; packet <= count; packet++) {
                for (int order = 0; order < 2; order++) {
                    int i = (packet + loop + run + order) & 1;
                    size_t index = ((size_t)i * (count + 1) + packet) * loops + loop;
                    double start = seconds(), elapsed;
                    frames[i] += v[i].send(v[i].decoder, packet == count ? NULL : packets[packet]);
                    elapsed = seconds() - start;
                    total[i] += elapsed;
                    times[index] = elapsed;
                }
            }
        }
        if (frames[0] != frames[1]) {
            fprintf(stderr, "Decoded frame counts differ\n");
            return 1;
        }
        for (int i = 0; i < 2; i++) {
            for (int packet = 0; packet <= count; packet++) {
                double *t = times + ((size_t)i * (count + 1) + packet) * loops;
                qsort(t, loops, sizeof(*t), compare_double);
                median[i] += loops & 1 ? t[loops / 2] :
                                        (t[loops / 2 - 1] + t[loops / 2]) / 2;
            }
        }
        printf("%d,%" PRId64 ",%.9f,%.9f,%.6f,%.9f,%.9f,%.6f\n",
               run, frames[0], total[0], total[1], total[0] / total[1],
               median[0], median[1], median[0] / median[1]);
        fflush(stdout);
    }
    for (int i = 0; i < 2; i++) {
        v[i].close(v[i].decoder);
        dlclose(v[i].library);
    }
    for (int i = 0; i < count; i++)
        av_packet_free(&packets[i]);
    av_free(times);
    av_free(packets);
    av_packet_free(&pkt);
    avformat_close_input(&fmt);
    return 0;
}
#endif
