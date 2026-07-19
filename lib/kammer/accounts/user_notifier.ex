defmodule Kammer.Accounts.UserNotifier do
  @moduledoc """
  Account emails, all localized per user (SPEC §1: EN and DA complete,
  including emails) and inherently content-minimal (SPEC §9):

    * authentication — magic-link sign-in, first-time confirmation,
      email-change instructions, and step-up confirmations (issue #294);
    * account-lifecycle security notices, sent to the affected address
      after the fact — email changed (#258), account deleted, and data
      exported (#338) — the one signal a hijacked account's real owner
      still receives.
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
    product_name = Kammer.product_name()

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
  Tell the OLD address its account's email just changed (issue #258).
  The one signal a hijacked account's real owner still receives — the
  new address gets the confirm link, every other email follows the
  account — so it names the new address and says what to do if the
  change wasn't theirs.
  """
  @spec deliver_email_changed_notice(User.t(), String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_email_changed_notice(user, old_email, new_email) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(old_email, gettext("Your account email was changed"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("The email address for your account was just changed to %{new_email}.", new_email: new_email)}

      #{gettext("If you made this change, you can ignore this email.")}

      #{gettext("If you did NOT make this change, your account may be compromised — contact your instance's administrator immediately.")}
      """)
    end)
  end

  @doc """
  Tell an account's own address that the account was permanently
  deleted (issue #338). Deletion is one of the two most consequential,
  irreversible actions behind the step-up gate (#323); like the
  email-changed notice, this is the one after-the-fact signal a
  hijacked account's real owner still receives. The caller sends it
  once the delete has committed, using the in-memory struct whose
  email survives the row's removal.
  """
  @spec deliver_account_deleted_notice(User.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_account_deleted_notice(user) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(user.email, gettext("Your account was deleted"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("Your account on %{instance} was permanently deleted, along with your personal data.", instance: Kammer.product_name())}

      #{gettext("If this was you, no further action is needed.")}

      #{gettext("If you did NOT delete your account, it may have been compromised — contact your instance's administrator immediately.")}
      """)
    end)
  end

  @doc """
  Tell an account's address that a full copy of its data was just
  exported and downloaded (issue #338). The export bundles every
  stored byte of the account's PII into one download — a step-up-gated
  action (#323) worth more to an attacker than to an accident — so an
  unexpected one is the signal a device token is in the wrong hands.
  """
  @spec deliver_account_exported_notice(User.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_account_exported_notice(user) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(user.email, gettext("A copy of your data was downloaded"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("A full copy of your account's data on %{instance} was just exported and downloaded.", instance: Kammer.product_name())}

      #{gettext("If this was you, no further action is needed.")}

      #{gettext("If you did NOT request this export, your account may have been compromised — contact your instance's administrator immediately.")}
      """)
    end)
  end

  @doc """
  Deliver the step-up confirmation link (issue #294, ADR 0029): the
  emailed proof-of-mailbox a device presents before a gated,
  security-sensitive action when it has no usable passkey. The
  elevation is action-generic, so the body cannot say which specific
  action prompted it — instead it names the gated class including its
  most consequential members (account deletion and the full data
  export, issue #323), and says what to do if the recipient didn't
  ask: an unexpected one of these is the signal a device token is in
  the wrong hands.
  """
  @spec deliver_step_up_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_step_up_instructions(user, url) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(user.email, gettext("Confirm it's you"), """
      #{gettext("Hi %{name},", name: user.display_name)}

      #{gettext("A device signed in to your account wants to make a security-sensitive change — managing passkeys or devices, changing your email address, deleting the account, or downloading a copy of all its data. Confirm it's you by visiting the link below:")}

      #{url}

      #{gettext("The link is valid for 15 minutes and can be used once.")}

      #{gettext("If you didn't request this, don't click the link — someone may have access to your account. Review your devices and sign out anything you don't recognize.")}
      """)
    end)
  end

  @doc """
  Deliver instructions to log in with a magic link. Unconfirmed users get
  the confirmation wording; the mechanism is identical. With a `code`
  (the PWA flow, issue #177) the email also shows the short sign-in
  code for typing into the app on another device.
  """
  @spec deliver_login_instructions(User.t(), String.t(), String.t() | nil) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_login_instructions(user, url, code \\ nil) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url, code)
      _confirmed -> deliver_magic_link_instructions(user, url, code)
    end
  end

  defp deliver_magic_link_instructions(user, url, code) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(
        user.email,
        gettext("Your sign-in link"),
        email_body([
          gettext("Hi %{name},", name: user.display_name),
          gettext("You can sign in to your account by visiting the link below:"),
          url,
          code && gettext("Or enter this sign-in code in the app:"),
          code,
          validity_line(code),
          gettext("If you didn't request this email, please ignore it.")
        ])
      )
    end)
  end

  defp deliver_confirmation_instructions(user, url, code) do
    Gettext.with_locale(KammerWeb.Gettext, user.locale, fn ->
      deliver(
        user.email,
        gettext("Confirm your account"),
        email_body([
          gettext("Hi %{name},", name: user.display_name),
          gettext("You can confirm your account and sign in by visiting the link below:"),
          url,
          code && gettext("Or enter this sign-in code in the app:"),
          code,
          code && validity_line(code),
          gettext("If you didn't create an account with us, please ignore this email.")
        ])
      )
    end)
  end

  defp validity_line(nil), do: gettext("The link is valid for 15 minutes and can be used once.")

  defp validity_line(_code),
    do: gettext("The link and code are valid for 15 minutes and can each be used once.")

  defp email_body(paragraphs) do
    paragraphs
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end
end
