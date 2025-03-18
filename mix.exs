defmodule Sofa.MixProject do
  use Mix.Project

  @source "https://github.com/skunkwerks/sofa"
  @owner "https://skunkwerks.at/"
  @hexdoc "https://hexdocs.pm/sofa"
  def project do
    [tag, version] = version()

    [
      app: :sofa,
      deps: deps(),
      description: "Sofa, an idiomatic relaxing CouchDB client " <> version,
      # http://erlang.org/doc/man/dialyzer.html
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.17",
      id: version,
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: tag
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sofa.Application, []}
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

  defp dialyzer do
    [
      flags: ["-Wunmatched_returns", :error_handling],
      list_unused_filters: true,
      plt_local_path: System.user_home!() <> "/.mix/plts/sofa"
    ]
  end

  defp docs do
    [tag, _version] = version()

    [
      main: "readme",
      canonical: @hexdoc,
      source_ref: "#{tag}",
      source_url: @source,
      extras: ["README.md", "CHANGELOG.md", "LICENSE", ".version"]
    ]
  end

  defp package do
    [
      maintainers: ["Dave Cottlehuber"],
      licenses: ["BSD-2-Clause"],
      links: %{"github" => @source, "owner" => @owner}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:ex_doc, "~> 0.3", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:mint, "~> 1.7"},
      {:tesla, "~> 1.14"}
    ]
  end
end
