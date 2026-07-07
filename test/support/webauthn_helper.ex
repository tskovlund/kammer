defmodule Kammer.WebauthnHelper do
  @moduledoc """
  Hand-crafts valid WebAuthn registration/authentication ceremonies
  (ES256, `attestation: "none"`) so tests can exercise the real Wax
  verification path — the same code a browser's `navigator.credentials`
  calls feed — without a browser or a CDP virtual authenticator.
  """

  @curve :secp256r1

  @doc """
  A fresh P-256 key pair, standing in for an authenticator's.
  """
  def generate_key_pair do
    {pub, priv} = :crypto.generate_key(:ecdh, @curve)
    <<4, x::binary-size(32), y::binary-size(32)>> = pub
    %{private_key: priv, x: x, y: y}
  end

  @doc """
  Builds the `{attestation_object, client_data_json}` pair a browser's
  `navigator.credentials.create/1` would return for the given
  registration `challenge`, plus the credential id and key pair used
  (needed later to build a matching authentication ceremony).
  """
  def registration_ceremony(challenge, origin, opts \\ []) do
    key_pair = Keyword.get(opts, :key_pair, generate_key_pair())
    credential_id = Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32))
    sign_count = Keyword.get(opts, :sign_count, 0)

    client_data_json = client_data_json("webauthn.create", challenge, origin)
    auth_data = attested_authenticator_data(challenge.rp_id, sign_count, credential_id, key_pair)

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data},
        "attStmt" => %{}
      })

    %{
      attestation_object: attestation_object,
      client_data_json: client_data_json,
      credential_id: credential_id,
      key_pair: key_pair
    }
  end

  @doc """
  Builds the `{credential_id, authenticator_data, signature,
  client_data_json}` tuple a browser's `navigator.credentials.get/1`
  would return for the given authentication `challenge`, signed with
  the key pair from a prior `registration_ceremony/3`.
  """
  def authentication_ceremony(challenge, origin, credential_id, key_pair, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, 0)

    client_data_json = client_data_json("webauthn.get", challenge, origin)
    auth_data = bare_authenticator_data(challenge.rp_id, sign_count)
    client_data_hash = :crypto.hash(:sha256, client_data_json)

    signature =
      :crypto.sign(:ecdsa, :sha256, auth_data <> client_data_hash, [
        key_pair.private_key,
        @curve
      ])

    %{
      credential_id: credential_id,
      authenticator_data: auth_data,
      signature: signature,
      client_data_json: client_data_json
    }
  end

  defp client_data_json(type, challenge, origin) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge.bytes, padding: false),
      "origin" => origin
    })
  end

  # Flags byte, high to low: ED AT _ BS BE UV _ UP. AT (attested
  # credential data present) + UP (user present) for registration.
  defp attested_authenticator_data(rp_id, sign_count, credential_id, key_pair) do
    rp_id_hash = :crypto.hash(:sha256, rp_id)
    flags = <<0b01000001>>

    cose_key_cbor =
      CBOR.encode(%{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: key_pair.x},
        -3 => %CBOR.Tag{tag: :bytes, value: key_pair.y}
      })

    # All-zero AAGUID: a software authenticator has none.
    attested_credential_data =
      <<0::128>> <>
        <<byte_size(credential_id)::unsigned-big-integer-size(16)>> <>
        credential_id <> cose_key_cbor

    rp_id_hash <>
      flags <> <<sign_count::unsigned-big-integer-size(32)>> <> attested_credential_data
  end

  # UP only — no attested credential data on an authentication.
  defp bare_authenticator_data(rp_id, sign_count) do
    rp_id_hash = :crypto.hash(:sha256, rp_id)
    flags = <<0b00000001>>

    rp_id_hash <> flags <> <<sign_count::unsigned-big-integer-size(32)>>
  end
end
