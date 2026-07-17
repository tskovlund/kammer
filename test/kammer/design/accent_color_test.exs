defmodule Kammer.Design.AccentColorTest do
  @moduledoc """
  Property suite for the accent palette (SPEC §21): any admin-chosen accent
  must yield WCAG-AA-safe tints on both light and dark surfaces.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Kammer.Design.AccentColor

  @light_surface {0xFA, 0xF9, 0xF6}
  @dark_surface {0x16, 0x15, 0x13}

  defp hex_color_generator do
    gen all(value <- StreamData.integer(0..0xFFFFFF)) do
      "#" <> String.pad_leading(Integer.to_string(value, 16), 6, "0")
    end
  end

  property "derived accents meet 4.5:1 on their surface for any input color" do
    check all(hex_color <- hex_color_generator()) do
      palette = AccentColor.palette(hex_color)

      light_accent = AccentColor.parse_hex(palette.light.accent)
      dark_accent = AccentColor.parse_hex(palette.dark.accent)

      assert AccentColor.contrast_ratio(light_accent, @light_surface) >= 4.5,
             "light accent #{palette.light.accent} from #{hex_color} fails AA"

      assert AccentColor.contrast_ratio(dark_accent, @dark_surface) >= 4.5,
             "dark accent #{palette.dark.accent} from #{hex_color} fails AA"
    end
  end

  property "on-accent text meets 4.5:1 on the accent for any input color" do
    check all(hex_color <- hex_color_generator()) do
      palette = AccentColor.palette(hex_color)

      light_accent = AccentColor.parse_hex(palette.light.accent)
      on_light_accent = AccentColor.parse_hex(palette.light.on_accent)
      dark_accent = AccentColor.parse_hex(palette.dark.accent)
      on_dark_accent = AccentColor.parse_hex(palette.dark.on_accent)

      assert AccentColor.contrast_ratio(on_light_accent, light_accent) >= 4.5
      assert AccentColor.contrast_ratio(on_dark_accent, dark_accent) >= 4.5
    end
  end

  test "malformed input falls back to the default accent instead of crashing" do
    assert AccentColor.parse_hex("not-a-color") ==
             AccentColor.parse_hex(AccentColor.default_accent())

    assert AccentColor.css_variables("garbage") =~ "--accent:"
  end

  test "css_variables emits all eight properties" do
    css = AccentColor.css_variables("#4A6FA5")

    for property_name <- ~w(--accent --accent-strong --accent-soft --on-accent
                            --accent-dark --accent-strong-dark --accent-soft-dark
                            --on-accent-dark) do
      assert css =~ property_name
    end
  end
end
