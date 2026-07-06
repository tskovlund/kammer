defmodule KammerWeb.LayoutsTest do
  use KammerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KammerWeb.Layouts

  describe "app/1" do
    test "renders the inner content inside the application chrome" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash}>Inner page content</Layouts.app>
        """)

      assert html =~ "Inner page content"
    end
  end

  describe "flash_group/1" do
    test "renders client and server error flashes" do
      html = render_component(&Layouts.flash_group/1, flash: %{})

      assert html =~ "client-error"
      assert html =~ "server-error"
    end

    test "renders an info flash message" do
      html = render_component(&Layouts.flash_group/1, flash: %{"info" => "Welcome back"})

      assert html =~ "Welcome back"
    end
  end

  describe "theme_toggle/1" do
    test "renders system, light, and dark options" do
      html = render_component(&Layouts.theme_toggle/1, %{})

      assert html =~ ~s(data-phx-theme="system")
      assert html =~ ~s(data-phx-theme="light")
      assert html =~ ~s(data-phx-theme="dark")
    end
  end
end
