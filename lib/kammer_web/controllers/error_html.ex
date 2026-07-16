defmodule KammerWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """

  # Renders a plain-text page based on the template name. For example,
  # "404.html" becomes "Not Found". The LiveView web UI is gone (#187),
  # so the only HTML responses left are error pages and the syndication
  # feeds — neither needs the component/layout machinery.
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
