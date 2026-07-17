defmodule KammerWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://gettext.hexdocs.pm), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: KammerWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.
  """
  use Gettext.Backend, otp_app: :kammer

  @doc """
  Runs `fun` with the instance's default locale — the locale for
  everything aimed at guests, who have no locale preference of their
  own (guest and newsletter emails, the server-rendered unsubscribe
  pages, stored decision-poll texts).
  """
  @spec with_instance_locale((-> result)) :: result when result: var
  def with_instance_locale(fun) do
    locale = Kammer.Communities.get_instance_settings().default_locale || "en"
    Gettext.with_locale(__MODULE__, to_string(locale), fun)
  end
end
