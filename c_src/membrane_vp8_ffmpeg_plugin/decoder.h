#pragma once

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wall"
#pragma GCC diagnostic ignored "-Wextra"
#include <erl_nif.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#pragma GCC diagnostic pop

typedef struct _vp8_decoder_state {
  AVCodecContext *codec_ctx;
  struct SwsContext *sws_context;
} State;

#include "_generated/decoder.h"

#define DECODER_SEND_PKT_ERROR -1
#define DECODER_DECODE_ERROR -2
