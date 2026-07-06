defmodule KammerWeb.PageController do
  use KammerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
