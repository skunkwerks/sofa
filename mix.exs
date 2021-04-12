defmodule Sofa.MixProject do
  use Mix.Project

  def project do
    [tag, version] = version()

    [
      app: :sofa,
      version: tag,
      id: version,
      description: "Sofa " <> version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      # http://erlang.org/doc/man/dialyzer.html
      dialyzer: [
        flags: ["-Wunmatched_returns", :error_handling, :race_conditions],
        list_unused_filters: true
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sofa.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.2"},
      {:tesla, "~> 1.4"}
    ]
  end

  defp version() do
    case File.dir?(".git") do
      false -> from_hex()
      true -> from_git()
    end
  end

  defp from_hex() do
    File.read!(".version") |> String.split(":")
  end

  defp from_git() do
    # pulls version information from "nearest" git tag or sha hash-ish
    {hashish, 0} =
      System.cmd("git", ~w[describe --dirty --abbrev=7 --tags --always --first-parent])

    full_version = String.trim(hashish)

    tag_version =
      hashish
      |> String.split("-")
      |> List.first()
      |> String.replace_prefix("v", "")
      |> String.trim()

    tag_version =
      case Version.parse(tag_version) do
        :error -> "0.0.0-#{tag_version}"
        _ -> tag_version
      end

    # stash the tag so that it's rolled into the next commit and therefore
    # available in hex packages when git tag info may not be present
    File.write!(".version", "#{tag_version}: #{full_version}")

    [tag_version, full_version]
  end
end
