/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Decode cached H.264 packets, excluding demuxing, filtering and output work.
 * Build from a configured build directory:
 * cc -O2 -I. -I.. ../tools/h264_decode_bench.c libavformat/libavformat.a \
 *    libavcodec/libavcodec.a libavutil/libavutil.a -lm -pthread -o h264_decode_bench
 * Usage: h264_decode_bench INPUT LOOPS THREADS RUNS
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/error.h"
#include "libavutil/cpu.h"

static void check(int ret)
{
    if (ret < 0) {
        fprintf(stderr, "%s\n", av_err2str(ret));
        exit(1);
    }
}

static double seconds(clockid_t clock)
{
    struct timespec t;
    if (clock_gettime(clock, &t))
        exit(1);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int drain(AVCodecContext *ctx, AVFrame *frame)
{
    int frames = 0, ret;
    while ((ret = avcodec_receive_frame(ctx, frame)) >= 0) {
        frames++;
        av_frame_unref(frame);
    }
    if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF)
        check(ret);
    return frames;
}

/* A stable profiling boundary: Callgrind can collect only this function
 * and its callees, excluding stream probing and decoder setup. */
av_noinline int64_t h264_bench_decode_cached(AVCodecContext *ctx, AVFrame *frame,
                                            AVPacket **packets, int count)
{
    int64_t frames = 0;
    avcodec_flush_buffers(ctx);
    for (int i = 0; i < count; i++) {
        check(avcodec_send_packet(ctx, packets[i]));
        frames += drain(ctx, frame);
    }
    check(avcodec_send_packet(ctx, NULL));
    return frames + drain(ctx, frame);
}

int main(int argc, char **argv)
{
    AVFormatContext *fmt = NULL;
    AVCodecContext *ctx;
    AVPacket *pkt, **packets = NULL;
    AVFrame *frame;
    int stream, count = 0, loops, threads, runs, ret;
    if (argc != 5 || (loops = atoi(argv[2])) < 1 ||
        (threads = atoi(argv[3])) < 1 || (runs = atoi(argv[4])) < 1) {
        fprintf(stderr, "Usage: %s INPUT LOOPS THREADS RUNS\n", argv[0]);
        return 1;
    }
    av_log_set_level(AV_LOG_ERROR);
    if (getenv("H264_BENCH_CPU_FLAGS")) {
        unsigned flags = av_get_cpu_flags();
        check(av_parse_cpu_caps(&flags, getenv("H264_BENCH_CPU_FLAGS")));
        av_force_cpu_flags(flags);
    }
    fprintf(stderr, "CPU flags: 0x%x\n", av_get_cpu_flags());
    check(avformat_open_input(&fmt, argv[1], NULL, NULL));
    check(avformat_find_stream_info(fmt, NULL));
    stream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    check(stream);
    if (fmt->streams[stream]->codecpar->codec_id != AV_CODEC_ID_H264)
        return 1;
    ctx = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_H264));
    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    if (!ctx || !pkt || !frame)
        return 1;
    check(avcodec_parameters_to_context(ctx, fmt->streams[stream]->codecpar));
    ctx->thread_count = threads;
    check(avcodec_open2(ctx, ctx->codec, NULL));
    while ((ret = av_read_frame(fmt, pkt)) >= 0) {
        if (pkt->stream_index == stream) {
            AVPacket **tmp = av_realloc_array(packets, count + 1, sizeof(*packets));
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
    avformat_close_input(&fmt);
    if (!count)
        return 1;
    puts("run,frames,cpu_seconds,wall_seconds");
    for (int run = 0; run < runs; run++) {
        int64_t frames = 0;
        double cpu = seconds(CLOCK_PROCESS_CPUTIME_ID);
        double wall = seconds(CLOCK_MONOTONIC);
        for (int loop = 0; loop < loops; loop++)
            frames += h264_bench_decode_cached(ctx, frame, packets, count);
        wall = seconds(CLOCK_MONOTONIC) - wall;
        cpu = seconds(CLOCK_PROCESS_CPUTIME_ID) - cpu;
        printf("%d,%" PRId64 ",%.9f,%.9f\n", run, frames, cpu, wall);
        fflush(stdout);
    }
    for (int i = 0; i < count; i++)
        av_packet_free(&packets[i]);
    av_free(packets);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
    return 0;
}
