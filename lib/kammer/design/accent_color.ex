defmodule Kammer.Design.AccentColor do
  @moduledoc """
  Derives a WCAG-AA-safe accent palette from a community's single accent
  color (SPEC §21): branding is structural — switching communities re-tints
  the interface — and any admin-chosen color must yield accessible tints.

  Given one hex color this module computes, for light and dark surfaces:

    * `accent` — the interactive color, lightness-adjusted until it has at
      least 4.5:1 contrast against the surface;
    * `accent-strong` — a hover/active variant;
    * `accent-soft` — a low-opacity wash for backgrounds;
    * `on-accent` — ink or paper, whichever contrasts better on `accent`.

  All functions are pure; the palette is emitted as CSS custom properties.
  """

  import Bitwise

  @type rgb() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  # §21 surfaces: paper-white/off-white, near-black ink (not pure #fff/#000).
  @light_surface {0xFA, 0xF9, 0xF6}
  @dark_surface {0x16, 0x15, 0x13}
  @paper {0xFA, 0xF9, 0xF6}
  @ink {0x1C, 0x1B, 0x19}

  @minimum_contrast 4.5
  # Derivation targets a margin above AA so that the on-accent color (ink or
  # paper, whichever wins) also clears 4.5:1 — a mid-tone sitting exactly at
  # 4.5 against the surface can fail against both extremes.
  @derivation_target 5.0

  @doc """
  The CSS custom-property block for a community accent, covering both
  themes. Returns a safe string for a `style` attribute.
  """
  @spec css_variables(String.t()) :: String.t()
  def css_variables(hex_color) do
    palette = palette(hex_color)

    "--accent: #{palette.light.accent}; " <>
      "--accent-strong: #{palette.light.accent_strong}; " <>
      "--accent-soft: #{palette.light.accent_soft}; " <>
      "--on-accent: #{palette.light.on_accent}; " <>
      "--accent-dark: #{palette.dark.accent}; " <>
      "--accent-strong-dark: #{palette.dark.accent_strong}; " <>
      "--accent-soft-dark: #{palette.dark.accent_soft}; " <>
      "--on-accent-dark: #{palette.dark.on_accent};"
  end

  @doc """
  The full derived palette for one accent color.
  """
  @spec palette(String.t()) :: %{light: map(), dark: map()}
  def palette(hex_color) do
    base_rgb = parse_hex(hex_color)

    light_accent = ensure_contrast(base_rgb, @light_surface)
    dark_accent = ensure_contrast(base_rgb, @dark_surface)

    %{
      light: %{
        accent: to_hex(light_accent),
        accent_strong: to_hex(shift_lightness(light_accent, -0.08)),
        accent_soft: soft_wash(light_accent, 0.12),
        on_accent: to_hex(readable_on(light_accent))
      },
      dark: %{
        accent: to_hex(dark_accent),
        accent_strong: to_hex(shift_lightness(dark_accent, 0.08)),
        accent_soft: soft_wash(dark_accent, 0.16),
        on_accent: to_hex(readable_on(dark_accent))
      }
    }
  end

  @doc """
  WCAG 2.x contrast ratio between two colors, from 1.0 to 21.0.
  """
  @spec contrast_ratio(rgb(), rgb()) :: float()
  def contrast_ratio(rgb_one, rgb_two) do
    luminance_one = relative_luminance(rgb_one)
    luminance_two = relative_luminance(rgb_two)

    {lighter, darker} =
      if luminance_one >= luminance_two,
        do: {luminance_one, luminance_two},
        else: {luminance_two, luminance_one}

    (lighter + 0.05) / (darker + 0.05)
  end

  @doc """
  Adjusts the color's lightness (keeping hue and saturation) until it
  clears the derivation target (#{@derivation_target}:1 — AA plus margin)
  against the surface; the public guarantee is #{@minimum_contrast}:1.
  """
  @spec ensure_contrast(rgb(), rgb()) :: rgb()
  def ensure_contrast(rgb, surface_rgb) do
    if contrast_ratio(rgb, surface_rgb) >= @derivation_target do
      rgb
    else
      surface_is_light? = relative_luminance(surface_rgb) > 0.5
      direction = if surface_is_light?, do: -0.02, else: 0.02
      adjust_until_contrast(rgb, surface_rgb, direction, 0)
    end
  end

  defp adjust_until_contrast(rgb, _surface, _direction, 60), do: rgb

  defp adjust_until_contrast(rgb, surface_rgb, direction, step) do
    adjusted = shift_lightness(rgb, direction)

    cond do
      contrast_ratio(adjusted, surface_rgb) >= @derivation_target -> adjusted
      adjusted == rgb -> rgb
      true -> adjust_until_contrast(adjusted, surface_rgb, direction, step + 1)
    end
  end

  @doc """
  Parses `#RRGGBB` into an RGB tuple. Falls back to the default accent on
  malformed input — palette derivation must never crash page rendering.
  """
  @spec parse_hex(String.t()) :: rgb()
  def parse_hex("#" <> hex) when byte_size(hex) == 6 do
    case Integer.parse(hex, 16) do
      {value, ""} -> {value >>> 16 &&& 0xFF, value >>> 8 &&& 0xFF, value &&& 0xFF}
      _invalid -> parse_hex(default_accent())
    end
  end

  def parse_hex(_invalid), do: parse_hex(default_accent())

  @doc "The instance default accent color."
  @spec default_accent() :: String.t()
  def default_accent, do: "#3E6B48"

  ## Internals — color math

  defp relative_luminance({red, green, blue}) do
    [linear_red, linear_green, linear_blue] =
      Enum.map([red, green, blue], fn channel ->
        proportion = channel / 255

        if proportion <= 0.04045 do
          proportion / 12.92
        else
          :math.pow((proportion + 0.055) / 1.055, 2.4)
        end
      end)

    0.2126 * linear_red + 0.7152 * linear_green + 0.0722 * linear_blue
  end

  defp readable_on(rgb) do
    if contrast_ratio(rgb, @paper) >= contrast_ratio(rgb, @ink), do: @paper, else: @ink
  end

  defp soft_wash({red, green, blue}, opacity) do
    "rgba(#{red}, #{green}, #{blue}, #{opacity})"
  end

  defp shift_lightness(rgb, delta) do
    {hue, saturation, lightness} = rgb_to_hsl(rgb)
    hsl_to_rgb({hue, saturation, clamp(lightness + delta, 0.0, 1.0)})
  end

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp rgb_to_hsl({red, green, blue}) do
    red_proportion = red / 255
    green_proportion = green / 255
    blue_proportion = blue / 255

    maximum = Enum.max([red_proportion, green_proportion, blue_proportion])
    minimum = Enum.min([red_proportion, green_proportion, blue_proportion])
    lightness = (maximum + minimum) / 2

    if maximum == minimum do
      {0.0, 0.0, lightness}
    else
      delta = maximum - minimum

      saturation =
        if lightness > 0.5, do: delta / (2 - maximum - minimum), else: delta / (maximum + minimum)

      hue =
        cond do
          maximum == red_proportion ->
            offset = if green_proportion < blue_proportion, do: 6, else: 0
            (green_proportion - blue_proportion) / delta + offset

          maximum == green_proportion ->
            (blue_proportion - red_proportion) / delta + 2

          true ->
            (red_proportion - green_proportion) / delta + 4
        end

      {hue / 6, saturation, lightness}
    end
  end

  defp hsl_to_rgb({hue, saturation, lightness}) do
    if saturation == 0.0 do
      channel = round(lightness * 255)
      {channel, channel, channel}
    else
      second =
        if lightness < 0.5 do
          lightness * (1 + saturation)
        else
          lightness + saturation - lightness * saturation
        end

      first = 2 * lightness - second

      {
        round(hue_to_channel(first, second, hue + 1 / 3) * 255),
        round(hue_to_channel(first, second, hue) * 255),
        round(hue_to_channel(first, second, hue - 1 / 3) * 255)
      }
    end
  end

  defp hue_to_channel(first, second, hue) do
    hue =
      cond do
        hue < 0 -> hue + 1
        hue > 1 -> hue - 1
        true -> hue
      end

    cond do
      hue < 1 / 6 -> first + (second - first) * 6 * hue
      hue < 1 / 2 -> second
      hue < 2 / 3 -> first + (second - first) * (2 / 3 - hue) * 6
      true -> first
    end
  end

  defp to_hex({red, green, blue}) do
    "#" <>
      String.pad_leading(Integer.to_string(red, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(green, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(blue, 16), 2, "0")
  end
end
