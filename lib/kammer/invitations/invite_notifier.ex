defmodule Kammer.Invitations.InviteNotifier do
  @moduledoc """
  Email delivery for admin email invites (SPEC §3). Localized to the
  community's default language — the recipient has no account yet, so
  their personal locale is unknown.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Swoosh.Email

  alias Kammer.Communities.Community
  alias Kammer.Groups.Group
  alias Kammer.Invitations.Invite
  alias Kammer.Mailer

  @doc """
  Delivers the invite link to the invited email address.
  """
  @spec deliver_invite(Invite.t(), Kammer.Accounts.User.t(), Community.t(), Group.t() | nil) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_invite(%Invite{} = invite, inviter, %Community{} = community, group) do
    Gettext.with_locale(KammerWeb.Gettext, community.default_locale, fn ->
      target_name =
        case group do
          nil -> community.name
          %Group{name: group_name} -> "#{group_name} (#{community.name})"
        end

      url = KammerWeb.Endpoint.url() <> "/invite/#{invite.token}"

      email =
        new()
        |> to(invite.invited_email)
        |> from(mail_from())
        |> subject(
          gettext("%{inviter} invited you to join %{target}",
            inviter: inviter.display_name,
            target: target_name
          )
        )
        |> text_body("""
        #{gettext("Hi,")}

        #{gettext("%{inviter} has invited you to join %{target} on %{product}.", inviter: inviter.display_name, target: target_name, product: product_name())}

        #{gettext("Accept the invitation by visiting the link below:")}

        #{url}

        #{gettext("If you weren't expecting this invitation, you can ignore this email.")}
        """)

      with {:ok, _metadata} <- Mailer.deliver(email) do
        {:ok, email}
      end
    end)
  end

  defp mail_from do
    from_config = Application.get_env(:kammer, :mail_from, [])

    {Keyword.get(from_config, :name, product_name()),
     Keyword.get(from_config, :address, "kammer@localhost")}
  end

  defp product_name do
    Application.get_env(:kammer, :product_name, "Kammer")
  end
end
