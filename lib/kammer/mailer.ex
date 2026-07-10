defmodule Kammer.Mailer do
  @moduledoc "The app's Swoosh mailer — the single outbound-email gateway."
  use Swoosh.Mailer, otp_app: :kammer
end
