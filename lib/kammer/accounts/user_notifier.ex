defmodule Kammer.Accounts.UserNotifier do
  @moduledoc """
  Authentication emails: magic-link sign-in, first-time confirmation, and
  email-change instructions. Localized per user (SPEC §1: EN and DA
  complete, including emails). These emails are inherently content-minimal
  (SPEC §9).
  """

  use Gettext, backend: KammerWeb.Gettext

  import Swoosh.Email

  alias Kammer.Accounts.User
  alias Kammer.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(mail_from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp mail_from do
    from_config = Application.get_env(:kammer, :mail_from, [])
    product_name = Application.get_env(:kammer, :product_name, "Kammer")

    {Keyword.get(from_config, :name, product_name),
     Keyword.get(from_config, :address, "kammer@localhost")}
  end

  @doc """
  Deliver instructions to update a user email.
  """
  @spec deliver_update_email_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_update_email_instructions(user, url) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(user.email, gettext("Confirm your new email address"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("You can change your email by visiting the link below:")}

      #{url}

      #{gettext("If you didn't request this change, please ignore this email.")}
      """)
    end)
  end

  @doc """
  Deliver instructions to log in with a magic link. Unconfirmed users get
  the confirmation wording; the mechanism is identical.
  """
  @spec deliver_login_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _confirmed -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(user.email, gettext("Your sign-in link"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("You can sign in to your account by visiting the link below:")}

      #{url}

      #{gettext("The link is valid for 15 minutes and can be used once.")}

      #{gettext("If you didn't request this email, please ignore it.")}
      """)
    end)
  end

  defp deliver_confirmation_instructions(user, url) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(user.email, gettext("Confirm your account"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("You can confirm your account and sign in by visiting the link below:")}

      #{url}

      #{gettext("If you didn't create an account with us, please ignore this email.")}
      """)
    end)
  end
end
