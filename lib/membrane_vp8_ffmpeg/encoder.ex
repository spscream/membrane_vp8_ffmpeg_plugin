defmodule Membrane.VP8.FFmpeg.Encoder do
  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.Native
  alias Membrane.Buffer
  alias Membrane.RawVideo
  alias Membrane.VP8
  alias Membrane.VP8.FFmpeg.Common

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: %RawVideo{pixel_format: format, aligned: true} when format in [:I420, :I422]

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %Membrane.RemoteStream{}

  def_options use_shm?: [
                spec: boolean(),
                description:
                  "If true, native encoder will use shared memory (via `t:Shmex.t/0`) for storing frames",
                default: false
              ],
              max_b_frames: [
                spec: non_neg_integer() | nil,
                description:
                  "Maximum number of B-frames between non-B-frames. Set to 0 to encode video without b-frames",
                default: nil
              ],
              gop_size: [
                spec: non_neg_integer() | nil,
                description: "Number of frames in a group of pictures.",
                default: nil
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state =
      opts
      |> Map.put(:encoder_ref, nil)

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    Membrane.Logger.info("handle_stream_format, #{inspect stream_format} #{inspect state}")

    {timebase_num, timebase_den} =
      case stream_format.framerate do
        nil -> {1, 30}
        {0, _framerate_den} -> {1, 30}
        {framerate_num, framerate_den} -> {framerate_den, framerate_num}
        frames_per_second when is_integer(frames_per_second) -> {1, frames_per_second}
      end

    with buffers <- flush_encoder_if_exists(state),
         {:ok, new_encoder_ref} <-
      Native.create(
        stream_format.width,
        stream_format.height,
        stream_format.pixel_format,
        state.max_b_frames || -1,
        state.gop_size || -1,
        timebase_num,
        timebase_den
      )
    do
      stream_format = create_new_stream_format(stream_format, state)
      actions = buffers ++ [stream_format: stream_format]
      {actions, %{state | encoder_ref: new_encoder_ref}}
    else
      {:error, reason} -> raise "Failed to create native encoder: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %{encoder_ref: encoder_ref, use_shm?: use_shm?} = state
    pts = Common.to_vp8_time_base_truncated(buffer.pts)

    #Membrane.Logger.info("vp8 handle_buffer, pts: #{inspect pts}")

    case Native.encode(
      buffer.payload,
      pts,
      use_shm?,
      encoder_ref
    ) do
      {:ok, dts_list, pts_list, frames} ->
        bufs = wrap_frames(dts_list, pts_list, frames)

        {bufs, state}

      {:error, reason} ->
        raise "Native encoder failed to encode the payload: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    buffers = flush_encoder_if_exists(state)
    actions = buffers ++ [end_of_stream: :output]
    {actions, state}
  end

  defp flush_encoder_if_exists(%{encoder_ref: nil}), do: []

  defp flush_encoder_if_exists(%{encoder_ref: encoder_ref, use_shm?: use_shm?}) do
    with {:ok, dts_list, pts_list, frames} <- Native.flush(use_shm?, encoder_ref) do
      wrap_frames(dts_list, pts_list, frames)
    else
      {:error, reason} -> raise "Native encoder failed to flush: #{inspect(reason)}"
    end
  end

  defp wrap_frames([], [], []), do: []

  defp wrap_frames(dts_list, pts_list, frames) do
    Enum.zip([dts_list, pts_list, frames])
    |> Enum.map(fn {dts, pts, frame} ->
      %Buffer{
        pts: Common.to_membrane_time_base_truncated(pts),
        dts: Common.to_membrane_time_base_truncated(dts),
        payload: frame
      }
    end)
    |> then(&[buffer: {:output, &1}])
  end

  defp create_new_stream_format(_stream_format, _state) do
    {:output, %Membrane.RemoteStream{content_format: VP8, type: :packetized}}
  end
end
