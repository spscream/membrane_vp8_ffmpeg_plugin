#include "decoder.h"

void handle_destroy_state(UnifexEnv *env, State *state) {
  UNIFEX_UNUSED(env);

  if (state->codec_ctx != NULL) {
    avcodec_free_context(&state->codec_ctx);
  }

  if (state->sws_context != NULL) {
    sws_freeContext(state->sws_context);
  }
}

UNIFEX_TERM create(UnifexEnv *env) {
  UNIFEX_TERM res;
  State *state = unifex_alloc_state(env);
  state->codec_ctx = NULL;
  state->sws_context = NULL;

#if (LIBAVCODEC_VERSION_MAJOR < 58)
  avcodec_register_all();
#endif
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_VP8);
  if (!codec) {
    res = create_result_error(env, "nocodec");
    goto exit_create;
  }

  state->codec_ctx = avcodec_alloc_context3(codec);
  if (!state->codec_ctx) {
    res = create_result_error(env, "codec_alloc");
    goto exit_create;
  }

  if (avcodec_open2(state->codec_ctx, codec, NULL) < 0) {
    res = create_result_error(env, "codec_open");
    goto exit_create;
  }

  res = create_result_ok(env, state);
exit_create:
  unifex_release_state(env, state);
  return res;
}

static int get_frames(UnifexEnv *env, AVPacket *pkt,
                      UnifexPayload ***ret_frames,
                      int64_t **best_effort_timestamps, int *max_frames,
                      int *frame_cnt, int *out_width, int *out_height, int use_shm, State *state) {
  AVFrame *frame = av_frame_alloc();

  AVFrame *out_frame = av_frame_alloc();
  out_frame->format = AV_PIX_FMT_YUV420P;
  out_frame->width = 640;
  out_frame->height = 480;

  UnifexPayload **frames = unifex_alloc((*max_frames) * sizeof(*frames));
  int64_t *timestamps = unifex_alloc((*max_frames) * sizeof(*timestamps));

  struct SwsContext *resize_context = sws_alloc_context();
  int ret = sws_init_context(resize_context, NULL, NULL);
  if(ret < 0) {
    printf("sws_init_context error: %s\n", av_err2str(ret));
    ret = DECODER_SEND_PKT_ERROR;
    goto exit_get_frames;
  }

  int num_bytes = av_image_get_buffer_size(AV_PIX_FMT_YUV420P, 640, 480, 1);
  uint8_t* out_frame_buffer = (uint8_t *)av_malloc(num_bytes*sizeof(uint8_t));

  ret = av_image_fill_arrays(out_frame->data, out_frame->linesize, out_frame_buffer, AV_PIX_FMT_YUV420P, 640, 480, 1);

  if (ret < 0){
    printf("av_image_fill_arrays error: %s\n", av_err2str(ret));
    ret = DECODER_SEND_PKT_ERROR;
    goto exit_get_frames;
  }
  
  ret = avcodec_send_packet(state->codec_ctx, pkt);
  if (ret < 0) {
    printf("avcodec_send_packet error: %s\n", av_err2str(ret));
    ret = DECODER_SEND_PKT_ERROR;
    goto exit_get_frames;
  }

  ret = avcodec_receive_frame(state->codec_ctx, frame);
  while (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
    if (frame->width != state->codec_ctx->width || frame->height != state->codec_ctx->height){
      printf("detected input frame format changed: %dx%d -> %d -> %d\n", frame->width, frame->height, state->codec_ctx->width, state->codec_ctx->height);
    }

    if (ret < 0) {
    printf("avcodec_receive_frame error: %s\n", av_err2str(ret));
    ret = DECODER_SEND_PKT_ERROR;
      ret = DECODER_DECODE_ERROR;
      goto exit_get_frames;
    }
    
    resize_context = sws_getContext(
      frame->width, frame->height, AV_PIX_FMT_YUV420P,
      640, 480, AV_PIX_FMT_YUV420P, SWS_FAST_BILINEAR,
      NULL, NULL, NULL
    );

    sws_scale(resize_context, (const uint8_t *const *)frame->data,
    frame->linesize, 0, frame->height, out_frame->data, out_frame->linesize);

    if (*frame_cnt >= (*max_frames)) {
      *max_frames *= 2;
      frames = unifex_realloc(frames, (*max_frames) * sizeof(*frames));
      timestamps =
          unifex_realloc(timestamps, (*max_frames) * sizeof(*timestamps));
    }

    /* char *pix_format; */
    /* switch (frame->format) { */
    /*   case AV_PIX_FMT_YUV420P: */
    /*     pix_format = "I420"; */
    /*   case AV_PIX_FMT_YUV422P: */
    /*     pix_format = "I422"; */
    /*   default: */
    /*     pix_format = "UNKNOWN"; */
    /* } */
    /*  */
    //printf("w: %d, h: %d f: %s k: %d\r\n", frame->width, frame->height, pix_format, frame->key_frame);

    size_t payload_size = av_image_get_buffer_size(
          AV_PIX_FMT_YUV420P, out_frame->width, out_frame->height, 1
        );

    frames[*frame_cnt] = unifex_alloc(sizeof(UnifexPayload));

    UnifexPayloadType payload_type;
    if (use_shm) {
      payload_type = UNIFEX_PAYLOAD_SHM;
    } else {
      payload_type = UNIFEX_PAYLOAD_BINARY;
    }
    unifex_payload_alloc(env, payload_type, payload_size, frames[*frame_cnt]);
    timestamps[*frame_cnt] = frame->best_effort_timestamp;

    av_image_copy_to_buffer(
        frames[*frame_cnt]->data, payload_size,
        (const uint8_t *const *)out_frame->data, (const int *)out_frame->linesize,
        state->codec_ctx->pix_fmt, out_frame->width, out_frame->height, 1);

    (*frame_cnt)++;

    ret = avcodec_receive_frame(state->codec_ctx, frame);
  }
  ret = 0;
exit_get_frames:
  *out_width = state->codec_ctx->width;
  *out_height = state->codec_ctx->height;
  *ret_frames = frames;
  *best_effort_timestamps = timestamps;
  av_frame_free(&frame);
  av_frame_free(&out_frame);
  return ret;
}

UNIFEX_TERM decode(UnifexEnv *env, UnifexPayload *payload, int64_t pts,
                   int64_t dts, int use_shm, State *state) {
  UNIFEX_TERM res_term;
  AVPacket *pkt = NULL;
  int max_frames = 16, frame_cnt = 0;
  int out_width, out_height;
  UnifexPayload **out_frames = NULL;
  int64_t *pts_list = NULL;
  pkt = av_packet_alloc();
  pkt->data = payload->data;
  pkt->size = payload->size;
  pkt->dts = dts;
  pkt->pts = pts;

  int ret = 0;
  if (pkt->size > 0) {
    ret = get_frames(env, pkt, &out_frames, &pts_list, &max_frames, &frame_cnt,
                     &out_width, &out_height, use_shm, state);
  }

  switch (ret) {
  case DECODER_SEND_PKT_ERROR:
    res_term = decode_result_error(env, "send_pkt");
    break;
  case DECODER_DECODE_ERROR:
    res_term = decode_result_error(env, "decode");
    break;
  default:
    res_term =
        decode_result_ok(env, pts_list, frame_cnt, out_frames, frame_cnt, out_width, out_height);
  }

  if (out_frames != NULL) {
    for (int i = 0; i < frame_cnt; i++) {
      if (out_frames[i] != NULL) {
        unifex_payload_release(out_frames[i]);
        unifex_free(out_frames[i]);
      }
    }
    unifex_free(out_frames);
  }
  if (pts_list != NULL) {
    unifex_free(pts_list);
  }

  av_packet_free(&pkt);
  return res_term;
}

UNIFEX_TERM reset(UnifexEnv *env, int use_shm, State *state) {
  UNIFEX_TERM res_term;
  int max_frames = 8, frame_cnt = 0;
  int out_width, out_height;
  UnifexPayload **out_frames = NULL;
  int64_t *pts_list = NULL;

  int ret = get_frames(env, NULL, &out_frames, &pts_list, &max_frames,
                       &frame_cnt, &out_width, &out_height, use_shm, state);

  switch (ret) {
  case DECODER_SEND_PKT_ERROR:
    res_term = reset_result_error(env, "send_pkt");
    goto exit_reset;
  case DECODER_DECODE_ERROR:
    res_term = reset_result_error(env, "decode");
    goto exit_reset;
  }

  if (state->codec_ctx != NULL) {
    avcodec_free_context(&state->codec_ctx);
  }

  state->codec_ctx = NULL;

#if (LIBAVCODEC_VERSION_MAJOR < 58)
  avcodec_register_all();
#endif
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_VP8);
  if (!codec) {
    res_term = reset_result_error(env, "nocodec");
    goto exit_reset;
  }

  state->codec_ctx = avcodec_alloc_context3(codec);
  if (!state->codec_ctx) {
    res_term = reset_result_error(env, "codec_alloc");
    goto exit_reset;
  }

  if (avcodec_open2(state->codec_ctx, codec, NULL) < 0) {
    res_term = reset_result_error(env, "codec_open");
    goto exit_reset;
  }

  res_term = reset_result_ok(env, pts_list, frame_cnt, out_frames, frame_cnt, state);

  if (out_frames != NULL) {
    for (int i = 0; i < frame_cnt; i++) {
      if (out_frames[i] != NULL) {
        unifex_payload_release(out_frames[i]);
        unifex_free(out_frames[i]);
      }
    }
    unifex_free(out_frames);
  }
  if (pts_list != NULL) {
    unifex_free(pts_list);
  }

exit_reset:
  unifex_release_state(env, state);
  return res_term;
}

UNIFEX_TERM flush(UnifexEnv *env, int use_shm, State *state) {
  UNIFEX_TERM res_term;
  int max_frames = 8, frame_cnt = 0;
  int out_width, out_height;
  UnifexPayload **out_frames = NULL;
  int64_t *pts_list = NULL;

  int ret = get_frames(env, NULL, &out_frames, &pts_list, &max_frames,
                       &frame_cnt, &out_width, &out_height, use_shm, state);

  switch (ret) {
  case DECODER_SEND_PKT_ERROR:
    res_term = flush_result_error(env, "send_pkt");
    break;
  case DECODER_DECODE_ERROR:
    res_term = flush_result_error(env, "decode");
    break;
  default:
    res_term = flush_result_ok(env, pts_list, frame_cnt, out_frames, frame_cnt);
  }

  if (out_frames != NULL) {
    for (int i = 0; i < frame_cnt; i++) {
      if (out_frames[i] != NULL) {
        unifex_payload_release(out_frames[i]);
        unifex_free(out_frames[i]);
      }
    }
    unifex_free(out_frames);
  }
  if (pts_list != NULL) {
    unifex_free(pts_list);
  }

  return res_term;
}

UNIFEX_TERM get_metadata(UnifexEnv *env, State *state) {
  char *pix_format;
  switch (state->codec_ctx->pix_fmt) {
  case AV_PIX_FMT_YUVJ420P:
  case AV_PIX_FMT_YUV420P:
    pix_format = "I420";
    break;
  case AV_PIX_FMT_YUVJ422P:
  case AV_PIX_FMT_YUV422P:
    pix_format = "I422";
    break;
  default:
    return get_metadata_result_error_pix_fmt(env);
  }
  return get_metadata_result_ok(env, state->codec_ctx->width,
                                state->codec_ctx->height, pix_format);
}
