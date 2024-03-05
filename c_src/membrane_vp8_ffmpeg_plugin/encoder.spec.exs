module Membrane.VP8.FFmpeg.Encoder.Native

state_type "State"

spec create(
       width :: int,
       height :: int,
       pix_fmt :: atom,
       max_b_frames :: int,
       gop_size :: int,
       timebase_num :: int,
       timebase_den :: int
     ) :: {:ok :: label, state} | {:error :: label, reason :: atom}

spec get_frame_size(state) :: {:ok :: label, frame_size :: int} | {:error :: label}

spec encode(payload, pts :: int64, use_shm :: bool, state) ::
       {:ok :: label, dts_list :: [int64], pts_list :: [int64], [payload]}
       | {:error :: label, reason :: atom}

spec flush(use_shm :: bool, state) ::
       {:ok :: label, dts_list :: [int64], pts_list :: [int64], frames :: [payload]}
       | {:error :: label, reason :: atom}

dirty :cpu, flush: 1, encode: 3
