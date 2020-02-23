defmodule ScenicDriverNervesTouch.MixProject do
  use Mix.Project

  @app_name :scenic_driver_nerves_waveshare_touch
  @version "0.1.0"
  @github "https://github.com/moogle19/scenic_driver_nerves_waveshare_touch"

  def project do
    [
      app: @app_name,
      version: @version,
      package: package(),
      description: description(),
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:input_event, "~> 0.4"},
      {:scenic, "~> 0.10"},
      {:ex_doc, "~> 0.19", only: [:dev, :test], runtime: false}
    ]
  end

  defp description() do
    """
    Scenic.Driver.Nerves.WaveshareTouch - Scenic driver providing touch input from WaveShare displays for Nerves devices.
    This project is base on the Scenic Touch Driver written by Boyd Multerer with so adjustments to work with the 7 inch WaveShare Display (Rev. C)
    """
  end

  defp package do
    [
      name: @app_name,
      contributors: ["Boyd Multerer", "Kevin Seidel"],
      maintainers: ["Kevin Seidel"],
      licenses: ["Apache 2"],
      links: %{Github: @github}
    ]
  end
end
