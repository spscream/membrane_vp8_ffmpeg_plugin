defmodule Membrane.VP8.FFmpeg.Plugin.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/spscream/membrane_vp8_ffmpeg_plugin"

  def project do
    [
      app: :membrane_vp8_ffmpeg_plugin,
      compilers: [:unifex, :bundlex] ++ Mix.compilers(),
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "VP8 FFmpeg plugin for Membrane Framework",
      package: package(),

      # docs
      name: "Membrane VP8 FFmpeg plugin",
      source_url: @github_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:bunch, "~> 1.6"},
      {:bundlex, "~> 1.3"},
      {:unifex, "~> 1.1"},
      {:membrane_precompiled_dependency_provider, "~> 0.1.0"},
      {:membrane_core, "~> 1.0"},
      {:membrane_common_c, "~> 0.16.0"},
      {:membrane_vp8_format, "~> 0.4.0"},
      {:membrane_raw_video_format, "~> 0.3.0"},
      {:membrane_ivf_plugin, "~> 0.7.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false},
      {:membrane_raw_video_parser_plugin, "~> 0.12.0", only: :test},
      {:membrane_file_plugin, "~> 0.16.0", only: :test},
      {:membrane_h264_plugin, "~> 0.9.0", only: :test}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.VP8.FFmpeg]
    ]
  end
end
