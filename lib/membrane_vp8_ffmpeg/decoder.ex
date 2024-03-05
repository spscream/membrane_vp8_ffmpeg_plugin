defmodule Membrane.VP8.FFmpeg.Decoder do
  @moduledoc """
  Membrane element that decodes video in VP8 format. It is backed by decoder from FFmpeg.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.Native
  alias Membrane.Buffer
  alias Membrane.VP8.FFmpeg.Common
  alias Membrane.RawVideo

  def_options use_shm?: [
                spec: boolean(),
                description:
                  "If true, native decoder will use shared memory (via `t:Shmex.t/0`) for storing frames",
                default: false
              ]

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: %Membrane.RemoteStream{}

  def_output_pad :output,
    flow_control: :auto,
    accepted_format: %RawVideo{pixel_format: format, aligned: true} when format in [:I420, :I422]

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      decoder_ref: nil, format_changed?: false, use_shm?: opts.use_shm?,
      out_width: nil, out_height: nil
    }
    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    Membrane.Logger.info("handle_setup, creting decoder")
    {[], %{state | decoder_ref: Native.create!()}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %{decoder_ref: decoder_ref, use_shm?: use_shm?} = state

    dts = Common.to_vp8_time_base_truncated(buffer.dts)
    pts = Common.to_vp8_time_base_truncated(buffer.pts)

    Membrane.Logger.debug("vp8 handle_buffer, pts: #{inspect pts} dts: #{inspect dts}")

    case Native.decode(
           buffer.payload,
           pts,
           dts,
           use_shm?,
           decoder_ref
         ) do
      {:ok, pts_list_h264_base, frames, out_width, out_height} ->
        bufs = wrap_frames(pts_list_h264_base, frames)
        #in_stream_format = ctx.pads.input.stream_format
        {stream_format, state} = update_stream_format_if_needed(state, out_width, out_height)

        {stream_format ++ bufs, state}

      {:error, reason} ->
        #raise "Native decoder failed to decode the payload: #{inspect(reason)}"
        Membrane.Logger.warning("vp8 decoder got error: #{inspect reason}, skipping, buffer: #{inspect buffer, pretty: true, limit: :infinity}")
        {[], state}
    end
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    Membrane.Logger.info("handle_stream_format, #{inspect stream_format} set format_changed?: true")
    # only redeclaring decoder - new stream_format will be generated in handle_buffer, after decoding key_frame
    {[], %{state | decoder_ref: Native.create!(), format_changed?: true}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    with {:ok, best_effort_pts_list, frames} <-
           Native.flush(state.use_shm?, state.decoder_ref),
         bufs <- wrap_frames(best_effort_pts_list, frames) do
      actions = bufs ++ [end_of_stream: :output]
      {actions, state}
    else
      {:error, reason} -> raise "Native decoder failed to flush: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_parent_notification(:reset_decoder, _ctx, state) do
    Membrane.Logger.warning("reset_decoder #{inspect state.decoder_ref}")

    {[], state}
  end

  defp wrap_frames([], []), do: []

  defp wrap_frames(pts_list, frames) do
    Enum.zip(pts_list, frames)
    |> Enum.map(fn {pts, frame} ->
      %Buffer{pts: Common.to_membrane_time_base_truncated(pts), payload: frame}
    end)
    |> then(&[buffer: {:output, &1}])
  end

  defp update_stream_format_if_needed(
         %{format_changed?: true, decoder_ref: decoder_ref} = state,
         _out_widht, _out_height
       ) do
    {[stream_format: {:output, generate_stream_format(decoder_ref, state.out_width, state.out_height)}],
     %{state | format_changed?: false}}
  end
  defp update_stream_format_if_needed(%{out_width: out_width, out_height: out_height} = state, out_width, out_height) do
    {[], state}
  end
  defp update_stream_format_if_needed(%{out_width: _out_width, out_height: _out_height} = state, out_width, out_height) do
    Membrane.Logger.info("generate_stream_format_change: #{out_width} #{out_height}")
    {[stream_format: {:output, generate_stream_format(state.decoder_ref, out_width, out_height)}],
      %{state | out_width: out_width, out_height: out_height}
    }
    {[], %{state | out_width: out_width, out_height: out_height}}
  end

  defp update_stream_format_if_needed(%{format_changed?: false} = state, _out_height, _out_width) do
    {[], state}
  end

  defp generate_stream_format(decoder_ref, out_width, out_height) do
    {:ok, width, height, pix_fmt} = Native.get_metadata(decoder_ref)

    %RawVideo{
      aligned: true,
      pixel_format: pix_fmt,
      framerate: {1, 30},
      width: 640,
      height: 480
    }
  end
end
