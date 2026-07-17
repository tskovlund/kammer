defmodule KammerWeb.ApiSpec do
  @moduledoc """
  The OpenAPI document for `/api/v1` (issue #30, ADR 0014): the
  machine-readable contract the TypeScript/Swift/Kotlin clients
  generate from. Paths are declared here, next to the schemas that
  mirror the serializer; the drift test asserts every `/api/` route in
  the router appears in this document, so the contract cannot silently
  fall behind the code.
  """

  alias KammerWeb.Api.Schemas
  alias OpenApiSpex.{Components, Info, MediaType, OpenApi, Operation, PathItem}
  alias OpenApiSpex.{Parameter, Reference, RequestBody, Response, Schema, SecurityScheme, Server}

  @behaviour OpenApi

  @role_values ["owner", "admin", "member"]
  @contact_visibilities ["hidden", "members", "admins"]

  @impl OpenApi
  def spec do
    OpenApiSpex.resolve_schema_modules(%OpenApi{
      info: %Info{
        title: "Kammer API",
        version: "v1",
        description:
          "Additive-only within v1. Auth: exchange a magic-link token for a " <>
            "long-lived device token, then send `Authorization: Bearer <token>`. " <>
            "Cursors are opaque — pass them back verbatim."
      },
      servers: [%Server{url: "/"}],
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{type: "http", scheme: "bearer"},
          "guestToken" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "The guest management link's token (ADR 0026, issue #230) — " <>
                "distinct from the account device token above: it authorizes " <>
                "exactly one guest identity's own records, not an account. " <>
                "The PWA reads it from the emailed management link's URL " <>
                "fragment and sends it as a normal Bearer credential."
          }
        },
        schemas: %{"Error" => Schemas.Error.schema()}
      },
      security: [%{"bearer" => []}],
      paths: paths()
    })
  end

  # One entry per route in the router's /api/v1 scopes — the drift test
  # enforces the bijection.
  defp paths do
    %{
      "/api/v1/instance" => %PathItem{
        get:
          operation("Instance capabilities", :instance_show, [],
            security: [],
            response:
              json_response(
                "Instance metadata, versions, and feature discovery",
                Schemas.Instance
              )
          )
      },
      "/api/v1/auth/register" => %PathItem{
        post:
          operation("Register an account", :auth_register, [],
            security: [],
            status: 201,
            request_body:
              body(
                object(%{
                  email: %Schema{type: :string, format: :email},
                  display_name: %Schema{type: :string}
                })
              ),
            response:
              json_response(
                "Registered — confirmation email sent",
                Schemas.AuthRegisterResponse
              )
          )
      },
      "/api/v1/auth/request-link" => %PathItem{
        post:
          operation("Request a sign-in link", :auth_request_link, [],
            security: [],
            request_body: body(object(%{email: %Schema{type: :string, format: :email}})),
            response:
              json_response(
                "Always {status: sent} — no account enumeration",
                Schemas.StatusResponse
              )
          )
      },
      "/api/v1/auth/exchange" => %PathItem{
        post:
          operation(
            "Exchange a magic token, or an emailed sign-in code, for a device token",
            :auth_exchange,
            [],
            security: [],
            request_body:
              body(
                object(%{
                  magic_token: %Schema{
                    type: :string,
                    nullable: true,
                    description: "The emailed magic-link token. Either this, or email + code."
                  },
                  email: %Schema{type: :string, format: :email, nullable: true},
                  code: %Schema{
                    type: :string,
                    nullable: true,
                    description: "The 8-character sign-in code from the email (case-insensitive)"
                  },
                  device_name: %Schema{type: :string, nullable: true}
                })
              ),
            response: json_response("Device token and user", Schemas.AuthExchangeResponse)
          )
      },
      "/api/v1/auth/passkey/challenge" => %PathItem{
        post:
          operation(
            "Start a passkey sign-in (WebAuthn assertion options)",
            :auth_passkey_challenge,
            [],
            security: [],
            response:
              json_response(
                "Assertion options; usernameless, no email asked for",
                Schemas.PasskeyChallengeResponse
              )
          )
      },
      "/api/v1/auth/passkey/verify" => %PathItem{
        post:
          operation("Verify a passkey assertion for a device token", :auth_passkey_verify, [],
            security: [],
            request_body:
              body(
                object(%{
                  challenge_token: %Schema{
                    type: :string,
                    description: "Returned verbatim from the challenge operation"
                  },
                  credential_id: %Schema{type: :string, description: "base64url, no padding"},
                  authenticator_data: %Schema{
                    type: :string,
                    description: "base64url, no padding"
                  },
                  signature: %Schema{type: :string, description: "base64url, no padding"},
                  client_data_json: %Schema{type: :string, description: "base64url, no padding"},
                  device_name: %Schema{type: :string, nullable: true}
                })
              ),
            response: json_response("Device token and user", Schemas.AuthExchangeResponse)
          )
      },
      "/api/v1/auth/device-token" => %PathItem{
        delete:
          operation("Revoke this device token", :auth_revoke, [],
            response: json_response("Revoked", Schemas.StatusResponse)
          )
      },
      "/api/v1/auth/step-up/passkey/challenge" => %PathItem{
        post:
          operation(
            "Start a step-up passkey assertion (issue #294): re-assert a root of trust " <>
              "before a credential change; on verify, the calling device token becomes " <>
              "stepped up for a short window",
            :step_up_passkey_challenge,
            [],
            response:
              json_response(
                "Assertion options scoped to the caller's own credentials",
                %Schema{
                  type: :object,
                  properties: %{data: Schemas.StepUpPasskeyChallenge},
                  required: [:data]
                }
              )
          )
      },
      "/api/v1/auth/step-up/passkey/verify" => %PathItem{
        post:
          operation(
            "Verify a step-up passkey assertion. Marks the CALLING device token stepped " <>
              "up — mints nothing. Every failure (stale/tampered challenge token, bad " <>
              "assertion, a credential owned by another account) is one neutral 422",
            :step_up_passkey_verify,
            [],
            request_body:
              body(
                object(%{
                  challenge_token: %Schema{
                    type: :string,
                    description: "Returned verbatim from the step-up challenge operation"
                  },
                  credential_id: %Schema{type: :string, description: "base64url, no padding"},
                  authenticator_data: %Schema{
                    type: :string,
                    description: "base64url, no padding"
                  },
                  signature: %Schema{type: :string, description: "base64url, no padding"},
                  client_data_json: %Schema{type: :string, description: "base64url, no padding"}
                })
              ),
            response: json_response("Stepped up — retry the gated action", Schemas.StatusResponse)
          )
      },
      "/api/v1/auth/step-up/request-link" => %PathItem{
        post:
          operation(
            "Email the account's own address a single-use step-up confirmation link " <>
              "bound to the calling device (issue #294). Shares the magic-link email " <>
              "budget; the link's public confirm endpoint may be opened in any browser",
            :step_up_request_link,
            [],
            extra_errors: [429],
            response: json_response("Always {status: sent} when allowed", Schemas.StatusResponse)
          )
      },
      "/api/v1/auth/step-up/confirm" => %PathItem{
        post:
          operation(
            "Consume an emailed step-up token (public — the link may land in a different " <>
              "browser than the requesting app). Steps up only the one device-token row " <>
              "the link was minted for; the requesting client then retries its action",
            :step_up_confirm,
            [],
            security: [],
            request_body: body(token_body()),
            response: json_response("Stepped up", Schemas.StatusResponse)
          )
      },
      "/api/v1/me" => %PathItem{
        get:
          operation("The caller's own profile", :me_show, [],
            response: single_response(Schemas.Profile)
          ),
        put:
          operation("Update the caller's profile and preferences", :me_update, [],
            request_body: body(profile_params()),
            response: single_response(Schemas.Profile)
          ),
        delete:
          operation(
            "Delete the account (SPEC §12): confirm_email must match the account's address. " <>
              "Requires a fresh step-up (issue #323) — 401 `step_up_required` otherwise",
            :me_delete,
            [],
            request_body:
              body(
                object(%{
                  confirm_email: %Schema{
                    type: :string,
                    format: :email,
                    description: "The account's own email, typed back to confirm intent"
                  }
                })
              ),
            response:
              json_response(
                "Deleted — identity gone, personal rows cascaded, authored content anonymized",
                Schemas.StatusResponse
              )
          )
      },
      "/api/v1/me/calendar-token" => %PathItem{
        get:
          operation(
            "The caller's iCal subscription URL (their merged-events feed)",
            :me_calendar_token,
            [],
            response: single_response(Schemas.CalendarToken)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/calendar-token" => %PathItem{
        get:
          operation(
            "A group's iCal subscription URL (viewable groups with events on)",
            :groups_calendar_token,
            [path_param(:community_slug), path_param(:group_slug)],
            response: single_response(Schemas.CalendarToken)
          )
      },
      "/api/v1/me/email-change" => %PathItem{
        post:
          operation(
            "Request an email change: a confirmation link is emailed to the new address. " <>
              "Requires a fresh step-up (issue #294) — 401 `step_up_required` otherwise",
            :email_change_request,
            [],
            request_body: body(object(%{email: %Schema{type: :string, format: :email}})),
            response:
              json_response(
                "Confirmation sent — nothing changes until the link is confirmed",
                Schemas.StatusResponse
              )
          )
      },
      "/api/v1/me/email-change/confirm" => %PathItem{
        post:
          operation(
            "Confirm an email change by consuming the emailed single-use token",
            :email_change_confirm,
            [],
            request_body: body(token_body()),
            response:
              json_response(
                "Confirmed. Device tokens are bound to the address they were issued " <>
                  "under, so the change invalidated all of them — swap in the fresh " <>
                  "device_token; every other device signs out.",
                %Schema{
                  type: :object,
                  properties: %{
                    data: Schemas.Profile,
                    device_token: %Schema{
                      type: :string,
                      description: "Replacement credential for the confirming device"
                    }
                  },
                  required: [:data, :device_token]
                }
              )
          )
      },
      "/api/v1/me/export" => %PathItem{
        get:
          operation(
            "The caller's complete data export (SPEC §12) as one zip. " <>
              "Requires a fresh step-up (issue #323) — 401 `step_up_required` otherwise",
            :me_export,
            [],
            extra_errors: [400],
            response: binary_response("The export zip: data.json plus every uploaded file")
          )
      },
      "/api/v1/me/devices" => %PathItem{
        get:
          operation(
            "The caller's devices: browser sessions and API device tokens (issue #174)",
            :devices_index,
            [],
            response: data_response(Schemas.Device)
          )
      },
      "/api/v1/me/devices/{device_id}" => %PathItem{
        delete:
          operation(
            "Revoke a device by id — revoking an API device also severs its live sockets. " <>
              "Revoking any device other than the caller's own requires a fresh step-up " <>
              "(issue #294) — 401 `step_up_required` otherwise; self-revoke is ungated",
            :devices_revoke,
            [path_param(:device_id)],
            response: json_response("Revoked", Schemas.StatusResponse)
          )
      },
      "/api/v1/me/passkeys/challenge" => %PathItem{
        post:
          operation(
            "Start passkey enrollment (WebAuthn registration options, ADR 0018). " <>
              "Requires a fresh step-up (issue #294) — 401 `step_up_required` otherwise",
            :passkeys_challenge,
            [],
            response: single_response(Schemas.PasskeyRegistrationChallenge)
          )
      },
      "/api/v1/me/passkeys" => %PathItem{
        get:
          operation(
            "The caller's registered passkeys (issue #260 port 5b)",
            :passkeys_index,
            [],
            response: data_response(Schemas.Passkey)
          ),
        post:
          operation(
            "Finish passkey enrollment: verify the attestation and store the credential. " <>
              "Every failure — stale/tampered token, bad attestation, duplicate credential — " <>
              "is one neutral 422. Requires a fresh step-up (issue #294) — 401 " <>
              "`step_up_required` otherwise",
            :passkeys_create,
            [],
            status: 201,
            request_body:
              body(%Schema{
                type: :object,
                properties: %{
                  challenge_token: %Schema{
                    type: :string,
                    description: "Returned verbatim from the challenge operation"
                  },
                  attestation_object: %Schema{type: :string, description: "base64url, no padding"},
                  client_data_json: %Schema{type: :string, description: "base64url, no padding"},
                  nickname: %Schema{
                    type: :string,
                    nullable: true,
                    description: "Optional label the owner gives the passkey"
                  }
                },
                required: [:challenge_token, :attestation_object, :client_data_json]
              }),
            response: single_response(Schemas.Passkey)
          )
      },
      "/api/v1/me/passkeys/{passkey_id}" => %PathItem{
        delete:
          operation(
            "Remove a registered passkey by id (owner-scoped). Requires a fresh " <>
              "step-up (issue #294) — 401 `step_up_required` otherwise",
            :passkeys_delete,
            [path_param(:passkey_id)],
            response: json_response("Revoked", Schemas.StatusResponse)
          )
      },
      "/api/v1/invites/{token}" => %PathItem{
        get:
          operation(
            "Preview what an invite opens (public — the token is the credential)",
            :invites_preview,
            [path_param(:token)],
            security: [],
            response: single_response(Schemas.InvitePreview)
          )
      },
      "/api/v1/invites/{token}/accept" => %PathItem{
        post:
          operation(
            "Accept an invite: join the community (and group), learn any required fields still missing",
            :invites_accept,
            [path_param(:token)],
            response: single_response(Schemas.InviteAcceptResponse)
          )
      },
      "/api/v1/communities/{community_slug}/members" => %PathItem{
        get:
          operation(
            "The member directory (SPEC §4), redacted per viewer; filterable by visible custom fields",
            :members_index,
            [
              path_param(:community_slug),
              query_param(
                :filter,
                "filter[<field_id>]=<value> pairs; only fields visible to the caller apply"
              )
            ],
            response:
              json_response("The roster and its visible field definitions", %Schema{
                type: :object,
                properties: %{
                  data: %Schema{type: :array, items: Schemas.Member},
                  fields: %Schema{type: :array, items: Schemas.CustomField}
                },
                required: [:data, :fields]
              })
          )
      },
      "/api/v1/communities/{community_slug}/members/{user_id}/role" => %PathItem{
        put:
          operation(
            "Change a member's community role (admins; owner transitions need the owner)",
            :members_update_role,
            [path_param(:community_slug), path_param(:user_id)],
            request_body: body(object(%{role: %Schema{type: :string, enum: @role_values}})),
            response: single_response(role_change_schema())
          )
      },
      "/api/v1/communities/{community_slug}/members/{user_id}" => %PathItem{
        delete:
          operation(
            "Remove a member from the community and all its groups (admins; owners can't be removed)",
            :members_remove,
            [path_param(:community_slug), path_param(:user_id)],
            extra_errors: [422],
            response: json_response("Removed", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/membership" => %PathItem{
        delete:
          operation(
            "Leave the community (owners must transfer ownership first — 422 owner_cannot_leave)",
            :community_leave,
            [path_param(:community_slug)],
            extra_errors: [422],
            response: json_response("Left", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/profile" => %PathItem{
        get:
          operation(
            "The caller's custom-field answers in this community (ADR 0020)",
            :community_profile_show,
            [path_param(:community_slug)],
            response: single_response(Schemas.CommunityProfile)
          ),
        put:
          operation(
            "Set custom-field answers (blank clears; unknown fields are ignored)",
            :community_profile_update,
            [path_param(:community_slug)],
            request_body:
              body(
                object(%{
                  values: %Schema{
                    type: :object,
                    additionalProperties: %Schema{type: :string},
                    description: "Field id → answer"
                  }
                })
              ),
            response: single_response(Schemas.CommunityProfile)
          )
      },
      "/api/v1/communities/{community_slug}/custom-fields" => %PathItem{
        get:
          operation(
            "The community's custom profile-field definitions (managers; issue #259)",
            :custom_fields_index,
            [path_param(:community_slug)],
            response: data_response(Schemas.CustomField)
          ),
        post:
          operation(
            "Add a custom profile field (managers)",
            :custom_fields_create,
            [path_param(:community_slug)],
            status: 201,
            request_body: body(Schemas.CustomFieldParams),
            response: single_response(Schemas.CustomField)
          )
      },
      "/api/v1/communities/{community_slug}/custom-fields/{id}" => %PathItem{
        put:
          operation(
            "Edit a custom field's label, visibility, or required flag (managers; type and options are fixed at creation)",
            :custom_fields_update,
            [path_param(:community_slug), path_param(:id)],
            request_body:
              body(
                object(%{
                  label: %Schema{type: :string},
                  visibility: %Schema{type: :string, enum: ["members", "admins"]},
                  required: %Schema{type: :boolean}
                })
              ),
            response: single_response(Schemas.CustomField)
          ),
        delete:
          operation(
            "Delete a custom field and every answer to it (managers)",
            :custom_fields_delete,
            [path_param(:community_slug), path_param(:id)],
            response: json_response("Deleted", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/invites" => %PathItem{
        get:
          operation(
            "Active community-wide invites (admins)",
            :community_invites_index,
            [path_param(:community_slug)],
            response: data_response(Schemas.Invite)
          ),
        post:
          operation(
            "Create a community-wide invite; invited_email delivers it and binds redemption to that address",
            :community_invites_create,
            [path_param(:community_slug)],
            status: 201,
            request_body: body(invite_params()),
            response: single_response(Schemas.Invite)
          )
      },
      "/api/v1/communities/{community_slug}/invites/{invite_id}" => %PathItem{
        delete:
          operation(
            "Revoke an invite (community- or group-scoped; requires the right to create it)",
            :invites_revoke,
            [path_param(:community_slug), path_param(:invite_id)],
            response: single_response(Schemas.Invite)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/invites" => %PathItem{
        get:
          operation(
            "Active invites into a group (group admins)",
            :group_invites_index,
            group_params(),
            response: data_response(Schemas.Invite)
          ),
        post:
          operation(
            "Create a group invite (joining also joins the community)",
            :group_invites_create,
            group_params(),
            status: 201,
            request_body: body(invite_params()),
            response: single_response(Schemas.Invite)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/members" => %PathItem{
        get:
          operation(
            "The group's members (group viewers)",
            :group_members_index,
            group_params(),
            response: data_response(Schemas.GroupMember)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/members/{user_id}/role" =>
        %PathItem{
          put:
            operation(
              "Change a member's group role (group admins; owner transitions need owner powers)",
              :group_members_update_role,
              group_params() ++ [path_param(:user_id)],
              request_body: body(object(%{role: %Schema{type: :string, enum: @role_values}})),
              response: single_response(role_change_schema())
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/members/{user_id}" => %PathItem{
        delete:
          operation(
            "Remove a member from the group (group admins; owners can't be removed)",
            :group_members_remove,
            group_params() ++ [path_param(:user_id)],
            extra_errors: [422],
            response: json_response("Removed", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/membership" => %PathItem{
        put:
          operation(
            "Join per the group's policy: open joins, request_approval files a request, invite_only 403s",
            :group_join,
            group_params(),
            request_body:
              optional_body(
                object(%{
                  message: %Schema{
                    type: :string,
                    nullable: true,
                    description: "Optional note shown with a join request"
                  }
                })
              ),
            response: json_response("status is `joined` or `requested`", Schemas.StatusResponse)
          ),
        delete:
          operation(
            "Leave the group (owners must transfer ownership first — 422 owner_cannot_leave)",
            :group_leave,
            group_params(),
            extra_errors: [422],
            response: json_response("Left", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/join-requests" => %PathItem{
        get:
          operation(
            "Pending join requests (approvers only)",
            :join_requests_index,
            group_params(),
            response: data_response(Schemas.JoinRequest)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/join-requests/{request_id}/approval" =>
        %PathItem{
          put:
            operation(
              "Approve a join request, creating the membership (422 when the person is banned)",
              :join_requests_approve,
              group_params() ++ [path_param(:request_id)],
              extra_errors: [422],
              response: json_response("Approved", Schemas.StatusResponse)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/join-requests/{request_id}" =>
        %PathItem{
          delete:
            operation(
              "Deny a join request",
              :join_requests_deny,
              group_params() ++ [path_param(:request_id)],
              response: json_response("Denied", Schemas.StatusResponse)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/notification-level" => %PathItem{
        get:
          operation(
            "The caller's notification level for this group (SPEC §9)",
            :notification_level_show,
            group_params(),
            response: single_response(Schemas.NotificationLevel)
          ),
        put:
          operation(
            "Set the caller's notification level for this group",
            :notification_level_update,
            group_params(),
            request_body:
              body(
                object(%{
                  level: %Schema{
                    type: :string,
                    enum: ["everything", "highlights", "mentions_only", "muted"]
                  }
                })
              ),
            response: single_response(Schemas.NotificationLevel)
          )
      },
      "/api/v1/home" => %PathItem{
        get:
          operation("Merged Home across communities", :home_show, [],
            response:
              json_response("Upcoming events and recent activity, labeled", Schemas.HomeResponse)
          )
      },
      "/api/v1/communities" => %PathItem{
        get:
          operation("The device owner's communities", :communities_index, [],
            response: data_response(Schemas.Community)
          ),
        post:
          operation(
            "Create a community (gated by the instance policy; the creator becomes its owner)",
            :communities_create,
            [],
            status: 201,
            request_body: body(Schemas.CommunityParams),
            response: single_response(Schemas.Community)
          )
      },
      "/api/v1/communities/{community_slug}" => %PathItem{
        put:
          operation(
            "Update community settings",
            :communities_update,
            [path_param(:community_slug)],
            request_body: body(Schemas.CommunityParams),
            response: single_response(Schemas.Community)
          )
      },
      "/api/v1/communities/{community_slug}/groups" => %PathItem{
        get:
          operation("Visible groups of a community", :groups_index, [path_param(:community_slug)],
            response: data_response(Schemas.Group)
          ),
        post:
          operation("Create a group", :groups_create, [path_param(:community_slug)],
            status: 201,
            request_body: body(Schemas.GroupParams),
            response: single_response(Schemas.Group)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}" => %PathItem{
        put:
          operation("Update group settings", :groups_update, group_params(),
            request_body: body(Schemas.GroupParams),
            response: single_response(Schemas.Group)
          ),
        delete:
          operation(
            "Delete a group and all of its content — group owners, and " <>
              "community admins (their sole power over sealed groups, ADR 0005)",
            :groups_delete,
            group_params(),
            response: single_response(Schemas.StatusOnly)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/features" => %PathItem{
        put:
          operation("Set a group's enabled features", :groups_features, group_params(),
            request_body: body(Schemas.GroupFeaturesParams),
            response: single_response(Schemas.Group)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/archive" => %PathItem{
        put:
          operation("Archive a group", :groups_archive, group_params(),
            response: single_response(Schemas.Group)
          ),
        delete:
          operation("Unarchive a group", :groups_unarchive, group_params(),
            response: single_response(Schemas.Group)
          )
      },
      "/api/v1/communities/{community_slug}/moderation/reports" => %PathItem{
        get:
          operation(
            "The open moderation report queue",
            :moderation_reports,
            [
              path_param(:community_slug)
            ],
            response: data_response(Schemas.Report)
          )
      },
      "/api/v1/communities/{community_slug}/moderation/reports/{report_id}/resolve" => %PathItem{
        post:
          operation(
            "Resolve a report by removing its content",
            :moderation_resolve,
            [path_param(:community_slug), path_param(:report_id)],
            response: single_response(Schemas.ReportAction)
          )
      },
      "/api/v1/communities/{community_slug}/moderation/reports/{report_id}/dismiss" => %PathItem{
        post:
          operation(
            "Dismiss a report (the content stays)",
            :moderation_dismiss,
            [path_param(:community_slug), path_param(:report_id)],
            response: single_response(Schemas.ReportAction)
          )
      },
      "/api/v1/communities/{community_slug}/moderation/bans" => %PathItem{
        get:
          operation("Active community bans", :moderation_bans, [path_param(:community_slug)],
            response: data_response(Schemas.Ban)
          ),
        post:
          operation("Ban a member", :moderation_ban, [path_param(:community_slug)],
            status: 201,
            request_body: body(Schemas.BanParams),
            response: single_response(Schemas.Ban)
          )
      },
      "/api/v1/communities/{community_slug}/moderation/bans/{ban_id}" => %PathItem{
        delete:
          operation(
            "Lift a ban",
            :moderation_unban,
            [path_param(:community_slug), path_param(:ban_id)],
            response: single_response(Schemas.StatusOnly)
          )
      },
      "/api/v1/communities/{community_slug}/audit-log" => %PathItem{
        get:
          operation(
            "The community audit log (newest first)",
            :audit_log,
            [
              path_param(:community_slug)
            ],
            response: data_response(Schemas.AuditEvent)
          )
      },
      "/api/v1/instance/moderation/bans" => %PathItem{
        get:
          operation(
            "Active instance-wide email bans (operators only)",
            :instance_bans,
            [],
            response: data_response(Schemas.Ban)
          ),
        post:
          operation(
            "Ban an email instance-wide (operators only): purges the " <>
              "account's memberships everywhere and blocks rejoin on every community",
            :instance_ban,
            [],
            status: 201,
            request_body: body(Schemas.InstanceBanParams),
            response: single_response(Schemas.Ban)
          )
      },
      "/api/v1/instance/moderation/bans/{ban_id}" => %PathItem{
        delete:
          operation(
            "Lift an instance-wide ban",
            :instance_unban,
            [path_param(:ban_id)],
            response: single_response(Schemas.StatusOnly)
          )
      },
      "/api/v1/instance/settings" => %PathItem{
        get:
          operation("Read instance settings (operators only)", :instance_settings, [],
            response: single_response(Schemas.InstanceSettings)
          ),
        put:
          operation("Update instance settings (operators only)", :instance_update_settings, [],
            request_body: body(Schemas.InstanceSettingsParams),
            response: single_response(Schemas.InstanceSettings)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts" => %PathItem{
        get:
          operation(
            "Group feed page (cursor-paginated)",
            :posts_index,
            [
              path_param(:community_slug),
              path_param(:group_slug),
              query_param(:after, "Opaque cursor from next_cursor"),
              query_param(:limit, "1..100, default 25")
            ],
            response: data_response(Schemas.Post)
          ),
        post:
          operation(
            "Create a post",
            :posts_create,
            [path_param(:community_slug), path_param(:group_slug)],
            status: 201,
            request_body:
              body(
                object(%{
                  body_markdown: %Schema{type: :string},
                  acknowledgment_required: %Schema{type: :boolean, nullable: true},
                  poll: Schemas.PollParams,
                  stored_file_ids: %Schema{
                    type: :array,
                    nullable: true,
                    items: %Schema{type: :string, format: :uuid},
                    description:
                      "Ids from the uploads endpoint, in display order — " <>
                        "must be the caller's own uploads into this group"
                  }
                })
              ),
            response: single_response(Schemas.Post)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/uploads" => %PathItem{
        post:
          operation(
            "Upload a feed attachment (multipart)",
            :uploads_create,
            [path_param(:community_slug), path_param(:group_slug)],
            status: 201,
            request_body: multipart_body(),
            # 413: file over UPLOAD_MAX_MB or the group's storage quota.
            extra_errors: [413],
            response: single_response(Schemas.StoredFile)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/files" => %PathItem{
        get:
          operation(
            "Browse a folder: its subfolders, files, and breadcrumb chain",
            :file_library_index,
            group_params() ++ [query_param(:folder_id, "The folder to open; omit for the root")],
            response: single_response(Schemas.FileListing)
          ),
        post:
          operation(
            "Upload a new file into a folder (multipart)",
            :file_library_upload,
            group_params(),
            status: 201,
            request_body: file_multipart_body(),
            # 413: file over UPLOAD_MAX_MB or the space's storage quota.
            extra_errors: [413],
            response: single_response(Schemas.LibraryFile)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/files/{file_id}" => %PathItem{
        get:
          operation(
            "A file with its version history (ADR 0017)",
            :file_library_show,
            file_params(),
            response: single_response(Schemas.LibraryFile)
          ),
        delete:
          operation(
            "Delete a file and all its versions (uploader or manager)",
            :file_library_delete,
            file_params(),
            response: single_response(Schemas.LibraryFile)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/files/{file_id}/versions" =>
        %PathItem{
          post:
            operation(
              "Upload a new version of an existing file (multipart)",
              :file_library_upload_version,
              file_params(),
              status: 201,
              request_body: file_multipart_body(),
              extra_errors: [413],
              response: single_response(Schemas.LibraryFile)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/files/{file_id}/versions/{version_id}" =>
        %PathItem{
          delete:
            operation(
              "Delete one version (uploader or manager; never the last)",
              :file_library_delete_version,
              file_params() ++ [path_param(:version_id)],
              # 422 last_version when it's the only remaining version.
              extra_errors: [422],
              response: single_response(Schemas.FileVersion)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/folders" => %PathItem{
        post:
          operation(
            "Create a folder (writers; depth-limited)",
            :file_library_create_folder,
            group_params(),
            status: 201,
            request_body:
              body(
                object(%{
                  name: %Schema{type: :string},
                  parent_folder_id: %Schema{type: :string, format: :uuid, nullable: true}
                })
              ),
            response: single_response(Schemas.Folder)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/folders/{folder_id}/overrides" =>
        %PathItem{
          put:
            operation(
              "Set a folder's read/write preset overrides (managers)",
              :file_library_update_folder,
              folder_params(),
              request_body:
                body(
                  object(%{
                    read_override: %Schema{type: :string, enum: ["inherit", "admins_only"]},
                    write_override: %Schema{type: :string, enum: ["inherit", "admins_only"]}
                  })
                ),
              response: single_response(Schemas.Folder)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/folders/{folder_id}" => %PathItem{
        delete:
          operation(
            "Delete a folder (managers). Files fall back to the root and take its visibility — a restrictive read override does not follow them",
            :file_library_delete_folder,
            folder_params(),
            response: single_response(Schemas.Folder)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}" => %PathItem{
        put:
          operation(
            "Edit a post's body (author)",
            :posts_update,
            post_params(),
            request_body: body(object(%{body_markdown: %Schema{type: :string}})),
            response: single_response(Schemas.Post)
          ),
        delete:
          operation(
            "Delete a post — soft/tombstone (author) or `?hard=true` (moderator)",
            :posts_delete,
            post_params() ++ [query_param(:hard, "true for a moderator hard delete")],
            response: single_response(Schemas.Post)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/pin" => %PathItem{
        put:
          operation("Pin a post (moderator)", :posts_pin, post_params(),
            response: single_response(Schemas.Post)
          ),
        delete:
          operation("Unpin a post (moderator)", :posts_unpin, post_params(),
            response: single_response(Schemas.Post)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/reactions" =>
        %PathItem{
          post:
            operation(
              "Toggle my emoji reaction on a post",
              :posts_react,
              post_params(),
              request_body: body(object(%{emoji: %Schema{type: :string}})),
              response: single_response(Schemas.Post)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/poll/votes" =>
        %PathItem{
          put:
            operation(
              "Set my poll selection (empty list to unvote)",
              :poll_vote,
              post_params(),
              request_body:
                body(
                  object(%{
                    option_ids: %Schema{
                      type: :array,
                      items: %Schema{type: :string, format: :uuid},
                      description:
                        "The full selection: single-choice polls keep the " <>
                          "first id, multiple-choice polls keep them all"
                    }
                  })
                ),
              response: single_response(Schemas.Poll)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/acknowledgment" =>
        %PathItem{
          put:
            operation(
              "Acknowledge a post (idempotent)",
              :posts_acknowledge,
              post_params(),
              extra_errors: [422],
              response: single_response(Schemas.Post)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/acknowledgments" =>
        %PathItem{
          get:
            operation(
              "Who has and hasn't acknowledged (author/admins)",
              :posts_acknowledgments,
              post_params(),
              response:
                single_response(%Schema{
                  type: :object,
                  properties: %{
                    acknowledged: %Schema{type: :array, items: Schemas.Author},
                    pending: %Schema{type: :array, items: Schemas.Author}
                  },
                  required: [:acknowledged, :pending]
                })
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/report" =>
        %PathItem{
          post:
            operation(
              "Report a post to the moderators (reporting it again answers the same)",
              :posts_report,
              post_params(),
              status: 201,
              request_body: body(report_body()),
              response: single_response(Schemas.StatusOnly)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments" =>
        %PathItem{
          post:
            operation(
              "Comment on a post",
              :comments_create,
              post_params(),
              status: 201,
              request_body:
                body(
                  object(%{
                    body_markdown: %Schema{type: :string},
                    parent_comment_id: %Schema{type: :string, nullable: true}
                  })
                ),
              response: single_response(Schemas.Comment)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments/{comment_id}" =>
        %PathItem{
          put:
            operation(
              "Edit a comment's body (author)",
              :comments_update,
              comment_params(),
              request_body: body(object(%{body_markdown: %Schema{type: :string}})),
              response: single_response(Schemas.Comment)
            ),
          delete:
            operation(
              "Delete a comment — soft (author) or hard (moderator); answers the tombstone",
              :comments_delete,
              comment_params(),
              response: single_response(Schemas.Comment)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments/{comment_id}/reactions" =>
        %PathItem{
          post:
            operation(
              "Toggle my emoji reaction on a comment",
              :comments_react,
              comment_params(),
              request_body: body(object(%{emoji: %Schema{type: :string}})),
              response: single_response(Schemas.Comment)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments/{comment_id}/report" =>
        %PathItem{
          post:
            operation(
              "Report a comment to the moderators (reporting it again answers the same)",
              :comments_report,
              comment_params(),
              status: 201,
              request_body: body(report_body()),
              response: single_response(Schemas.StatusOnly)
            )
        },
      "/api/v1/files/{file_id}" => %PathItem{
        get:
          operation(
            "A stored file's display bytes (inline images, downloads otherwise)",
            :files_show,
            [path_param(:file_id)],
            response: binary_response("The file — served with its own content type")
          )
      },
      "/api/v1/files/{file_id}/thumbnail" => %PathItem{
        get:
          operation(
            "An image's thumbnail (WebP)",
            :files_thumbnail,
            [path_param(:file_id)],
            response: binary_response("The thumbnail bytes")
          )
      },
      "/api/v1/files/{file_id}/download" => %PathItem{
        get:
          operation(
            "A stored file as a forced download",
            :files_download,
            [path_param(:file_id)],
            response: binary_response("The file bytes as an attachment")
          )
      },
      "/api/v1/communities/{community_slug}/events" => %PathItem{
        get:
          operation("Upcoming events", :events_index, [path_param(:community_slug)],
            response: data_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/series/{series_id}" => %PathItem{
        get:
          operation(
            "A recurring series' organizer view (occurrences + attendance matrix)",
            :events_series,
            [path_param(:community_slug), path_param(:series_id)],
            response: single_response(Schemas.EventSeriesDetail)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/events" => %PathItem{
        post:
          operation(
            "Create an event, or a recurring series",
            :events_create,
            [path_param(:community_slug), path_param(:group_slug)],
            status: 201,
            request_body: body(Schemas.EventParams),
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}" => %PathItem{
        get:
          operation(
            "Event details with my_rsvp",
            :events_show,
            event_params(),
            response: single_response(Schemas.Event)
          ),
        put:
          operation(
            "Edit this occurrence (creator/moderator)",
            :events_update,
            event_params(),
            request_body: body(Schemas.EventParams),
            response: single_response(Schemas.Event)
          ),
        delete:
          operation(
            "Delete an event (creator/moderator)",
            :events_delete,
            event_params(),
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/ics" => %PathItem{
        get:
          operation(
            "This event as a downloadable ICS file (issue #307)",
            :events_ics,
            event_params(),
            response: binary_response("The event as a text/calendar attachment", "text/calendar")
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/rsvp" => %PathItem{
        put:
          operation(
            "Set my RSVP — a yes beyond the event's capacity answers waitlisted (issue #318)",
            :events_rsvp,
            event_params(),
            request_body:
              body(object(%{status: %Schema{type: :string, enum: ["yes", "no", "maybe"]}})),
            response:
              single_response(%Schema{
                type: :object,
                properties: %{
                  event_id: %Schema{type: :string, format: :uuid},
                  status: %Schema{type: :string, enum: ["yes", "no", "maybe", "waitlisted"]}
                },
                required: [:event_id, :status]
              })
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/cancellation" => %PathItem{
        put:
          operation("Cancel this occurrence (ADR 0019)", :events_cancel, event_params(),
            response: single_response(Schemas.Event)
          ),
        delete:
          operation("Reinstate a cancelled occurrence", :events_uncancel, event_params(),
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/slots" => %PathItem{
        post:
          operation("Add a signup slot (creator/moderator)", :events_create_slot, event_params(),
            request_body:
              body(
                object(%{
                  title: %Schema{type: :string},
                  capacity: %Schema{type: :integer, minimum: 1}
                })
              ),
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/slots/{slot_id}" => %PathItem{
        delete:
          operation(
            "Delete a slot and its claims (creator/moderator)",
            :events_delete_slot,
            event_slot_params(),
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/slots/{slot_id}/claim" => %PathItem{
        put:
          operation("Claim a slot", :events_claim_slot, event_slot_params(),
            # 422 slot_full when capacity is reached (never overbooks).
            extra_errors: [422],
            response: single_response(Schemas.Event)
          ),
        delete:
          operation("Release my claim on a slot", :events_unclaim_slot, event_slot_params(),
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/comments" => %PathItem{
        post:
          operation("Comment on an event", :events_create_comment, event_params(),
            status: 201,
            request_body:
              body(
                object(%{
                  body_markdown: %Schema{type: :string},
                  parent_comment_id: %Schema{type: :string, nullable: true}
                })
              ),
            response: single_response(Schemas.Comment)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}" => %PathItem{
        put:
          operation(
            "Edit an event comment (author)",
            :events_update_comment,
            event_comment_params(),
            request_body: body(object(%{body_markdown: %Schema{type: :string}})),
            response: single_response(Schemas.Comment)
          ),
        delete:
          operation(
            "Delete an event comment — soft (author) or hard (moderator)",
            :events_delete_comment,
            event_comment_params(),
            response: single_response(Schemas.Comment)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}/reactions" =>
        %PathItem{
          post:
            operation(
              "Toggle my emoji reaction on an event comment",
              :events_react_comment,
              event_comment_params(),
              request_body: body(object(%{emoji: %Schema{type: :string}})),
              response: single_response(Schemas.Comment)
            )
        },
      "/api/v1/communities/{community_slug}/events/{event_id}/comments/{comment_id}/report" =>
        %PathItem{
          post:
            operation(
              "Report an event comment to the moderators (reporting it again answers the same)",
              :events_report_comment,
              event_comment_params(),
              status: 201,
              request_body: body(report_body()),
              response: single_response(Schemas.StatusOnly)
            )
        },
      "/api/v1/notifications" => %PathItem{
        get:
          operation(
            "The device owner's notifications (cursor-paginated, newest first)",
            :notifications_index,
            [
              query_param(:after, "Opaque cursor from next_cursor"),
              query_param(:limit, "1..100, default 25")
            ],
            response: data_response(Schemas.Notification)
          )
      },
      "/api/v1/notifications/read-all" => %PathItem{
        put:
          operation("Mark all notifications read", :notifications_mark_all_read, [],
            response: json_response("Marked read", Schemas.StatusResponse)
          )
      },
      "/api/v1/notifications/{notification_id}/read" => %PathItem{
        put:
          operation(
            "Mark one notification read",
            :notifications_mark_read,
            [path_param(:notification_id)],
            response: json_response("Marked read", Schemas.StatusResponse)
          )
      },
      "/api/v1/push-subscriptions" => %PathItem{
        post:
          operation("Register a Web Push subscription", :push_subscriptions_create, [],
            status: 201,
            request_body:
              body(
                object(%{
                  endpoint: %Schema{type: :string},
                  keys:
                    object(%{
                      p256dh: %Schema{type: :string},
                      auth: %Schema{type: :string}
                    })
                })
              ),
            response: json_response("Subscribed (idempotent upsert)", Schemas.StatusResponse)
          ),
        delete:
          operation(
            "Remove a Web Push subscription by endpoint",
            :push_subscriptions_delete,
            [query_param(:endpoint, "The subscription's endpoint URL")],
            response: json_response("Deleted (idempotent)", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/search" => %PathItem{
        get:
          operation(
            "Global search across the community (SPEC §16)",
            :search,
            [
              path_param(:community_slug),
              query_param(:q, "The search query; a blank query returns empty sections")
            ],
            response: single_response(Schemas.SearchResults)
          )
      },
      "/api/v1/communities/{community_slug}/availability" => %PathItem{
        get:
          operation(
            "Open date-finding polls across the community",
            :availability_index,
            [path_param(:community_slug)],
            response: data_response(Schemas.AvailabilityPoll)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/availability" => %PathItem{
        post:
          operation(
            "Create a date-finding poll",
            :availability_create,
            group_params(),
            status: 201,
            request_body:
              body(
                object(%{
                  title: %Schema{type: :string},
                  options: %Schema{
                    type: :array,
                    minItems: 1,
                    items: %Schema{type: :string, format: :"date-time"},
                    description: "Candidate dates as ISO 8601 date-times"
                  }
                })
              ),
            response: single_response(Schemas.AvailabilityPoll)
          )
      },
      "/api/v1/communities/{community_slug}/availability/{poll_id}" => %PathItem{
        get:
          operation(
            "A poll with its candidate dates and answers",
            :availability_show,
            poll_params(),
            response: single_response(Schemas.AvailabilityPoll)
          )
      },
      "/api/v1/communities/{community_slug}/availability/{poll_id}/responses" => %PathItem{
        put:
          operation(
            "Set my answer for one candidate date (upsert)",
            :availability_respond,
            poll_params(),
            # 422 poll_closed once the poll is closed.
            extra_errors: [422],
            request_body:
              body(
                object(%{
                  option_id: %Schema{type: :string, format: :uuid},
                  answer: %Schema{type: :string, enum: ["yes", "if_needed", "no"]}
                })
              ),
            response: single_response(Schemas.AvailabilityPoll)
          )
      },
      "/api/v1/communities/{community_slug}/availability/{poll_id}/closure" => %PathItem{
        put:
          operation(
            "Close a poll without converting (creator/moderator)",
            :availability_close,
            poll_params(),
            extra_errors: [422],
            response: single_response(Schemas.AvailabilityPoll)
          )
      },
      "/api/v1/communities/{community_slug}/availability/{poll_id}/conversion" => %PathItem{
        put:
          operation(
            "Close a poll by converting the chosen date into an event (creator/moderator)",
            :availability_convert,
            poll_params(),
            extra_errors: [422],
            request_body: body(object(%{option_id: %Schema{type: :string, format: :uuid}})),
            response: single_response(Schemas.AvailabilityPoll)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/assignments" => %PathItem{
        get:
          operation(
            "The group's assignment list",
            :assignments_index,
            group_params(),
            response: data_response(Schemas.Assignment)
          ),
        post:
          operation(
            "Create an assignment",
            :assignments_create,
            group_params(),
            status: 201,
            request_body: body(assignment_body()),
            response: single_response(Schemas.Assignment)
          )
      },
      "/api/v1/communities/{community_slug}/assignments/{assignment_id}" => %PathItem{
        get:
          operation(
            "An assignment with its claims and discussion",
            :assignments_show,
            assignment_params(),
            response: single_response(Schemas.Assignment)
          ),
        put:
          operation(
            "Edit an assignment (creator/moderator)",
            :assignments_update,
            assignment_params(),
            request_body: body(assignment_body()),
            response: single_response(Schemas.Assignment)
          ),
        delete:
          operation(
            "Delete an assignment and its claims and discussion (creator/moderator)",
            :assignments_delete,
            assignment_params(),
            response: single_response(Schemas.Assignment)
          )
      },
      "/api/v1/communities/{community_slug}/assignments/{assignment_id}/claim" => %PathItem{
        put:
          operation(
            "Claim an assignment (several people may)",
            :assignments_claim,
            assignment_params(),
            # 422 when the assignment is already done.
            extra_errors: [422],
            response: single_response(Schemas.Assignment)
          ),
        delete:
          operation(
            "Release my own claim",
            :assignments_unclaim,
            assignment_params(),
            response: single_response(Schemas.Assignment)
          )
      },
      "/api/v1/communities/{community_slug}/assignments/{assignment_id}/completion" => %PathItem{
        put:
          operation(
            "Mark the assignment done",
            :assignments_complete,
            assignment_params(),
            extra_errors: [422],
            response: single_response(Schemas.Assignment)
          ),
        delete:
          operation(
            "Reopen a done assignment",
            :assignments_reopen,
            assignment_params(),
            response: single_response(Schemas.Assignment)
          )
      },
      "/api/v1/communities/{community_slug}/assignments/{assignment_id}/comments" => %PathItem{
        post:
          operation(
            "Comment on an assignment (the shared engine, ADR 0007)",
            :assignments_create_comment,
            assignment_params(),
            status: 201,
            request_body:
              body(
                object(%{
                  body_markdown: %Schema{type: :string},
                  parent_comment_id: %Schema{type: :string, nullable: true}
                })
              ),
            response: single_response(Schemas.Comment)
          )
      },
      "/api/v1/communities/{community_slug}/assignments/{assignment_id}/comments/{comment_id}/report" =>
        %PathItem{
          post:
            operation(
              "Report an assignment comment to the moderators (reporting it again answers the same)",
              :assignments_report_comment,
              assignment_comment_params(),
              status: 201,
              request_body: body(report_body()),
              response: single_response(Schemas.StatusOnly)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/decisions" => %PathItem{
        get:
          operation(
            "The group's decisions register (newest first)",
            :decisions_index,
            group_params(),
            response: data_response(Schemas.Decision)
          ),
        post:
          operation(
            "Raise a motion — creates the feed post (with the default vote) and the register entry",
            :decisions_create,
            group_params(),
            status: 201,
            request_body:
              body(
                object(%{
                  title: %Schema{type: :string},
                  motion_markdown: %Schema{
                    type: :string,
                    nullable: true,
                    description: "The motion body; the title is used as the body when omitted"
                  },
                  with_vote: %Schema{
                    type: :boolean,
                    nullable: true,
                    description: "Attach the default For/Against/Abstain vote (default true)"
                  }
                })
              ),
            response: single_response(Schemas.Decision)
          )
      },
      "/api/v1/communities/{community_slug}/decisions/{decision_id}" => %PathItem{
        get:
          operation(
            "A register entry",
            :decisions_show,
            decision_params(),
            response: single_response(Schemas.Decision)
          )
      },
      "/api/v1/communities/{community_slug}/decisions/{decision_id}/outcome" => %PathItem{
        put:
          operation(
            "Record (or amend, pre-1.0) the outcome (proposer/moderator)",
            :decisions_record_outcome,
            decision_params(),
            request_body:
              body(
                object(%{
                  outcome: %Schema{type: :string, enum: ["adopted", "rejected", "noted"]},
                  outcome_note: %Schema{type: :string, nullable: true}
                })
              ),
            response: single_response(Schemas.Decision)
          )
      },
      "/api/v1/setup" => %PathItem{
        get:
          operation("Whether first-run setup has completed", :setup_status, [],
            security: [],
            response: json_response("Setup status", Schemas.SetupStatus)
          ),
        post:
          operation(
            "Complete first-run setup (operator, instance, first community and group)",
            :setup_complete,
            [],
            security: [],
            status: 201,
            request_body: body(setup_body()),
            response: json_response("The completed instance", Schemas.SetupResult)
          )
      },
      "/api/v1/legal/{key}" => %PathItem{
        get:
          operation("A public legal page (privacy or imprint)", :legal_show, [path_param(:key)],
            security: [],
            response: json_response("The legal page", Schemas.LegalPage)
          ),
        put:
          operation(
            "Publish a legal page's text (operators only), replacing the built-in template",
            :legal_update,
            [path_param(:key)],
            request_body: body(Schemas.LegalPageParams),
            response: json_response("The updated legal page", Schemas.LegalPage)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/guest-rsvp" => %PathItem{
        post:
          operation(
            "Request a guest RSVP — emails a confirm link (SPEC §6)",
            :guest_request_rsvp,
            [path_param(:community_slug), path_param(:event_id)],
            security: [],
            status: 202,
            request_body: body(guest_rsvp_body()),
            response: json_response("Confirmation email sent", Schemas.StatusResponse)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/slots/{slot_id}/guest-claim" =>
        %PathItem{
          post:
            operation(
              "Request a guest signup-slot claim — emails a confirm link",
              :guest_request_claim,
              [path_param(:community_slug), path_param(:event_id), path_param(:slot_id)],
              security: [],
              status: 202,
              request_body: body(guest_identity_body()),
              response: json_response("Confirmation email sent", Schemas.StatusResponse)
            )
        },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/guest-comment" =>
        %PathItem{
          post:
            operation(
              "Request a guest comment — emails a confirm link (SPEC §3)",
              :guest_request_comment,
              [path_param(:community_slug), path_param(:group_slug), path_param(:post_id)],
              security: [],
              status: 202,
              request_body: body(guest_comment_body()),
              response: json_response("Confirmation email sent", Schemas.StatusResponse)
            )
        },
      "/api/v1/guest/rsvp/confirm" => %PathItem{
        post:
          operation("Confirm a guest RSVP from the emailed link", :guest_confirm_rsvp, [],
            security: [],
            request_body: body(token_body()),
            response: json_response("Recorded", Schemas.GuestConfirmation)
          )
      },
      "/api/v1/guest/claim/confirm" => %PathItem{
        post:
          operation(
            "Confirm a guest signup claim from the emailed link",
            :guest_confirm_claim,
            [],
            security: [],
            request_body: body(token_body()),
            response: json_response("Recorded", Schemas.GuestConfirmation)
          )
      },
      "/api/v1/guest/comment/confirm" => %PathItem{
        post:
          operation(
            "Confirm a guest comment from the emailed link",
            :guest_confirm_comment,
            [],
            security: [],
            request_body: body(token_body()),
            response: json_response("Submitted for moderation", Schemas.GuestConfirmation)
          )
      },
      "/api/v1/guest/manage" => %PathItem{
        get:
          operation(
            "A guest's full inventory behind their management link (SPEC §12)",
            :guest_manage,
            [],
            security: [%{"guestToken" => []}],
            response: json_response("The guest's data", Schemas.GuestManageState)
          ),
        delete:
          operation(
            "Erase a guest and everything they created",
            :guest_erase,
            [],
            security: [%{"guestToken" => []}],
            response: json_response("Erased", Schemas.StatusResponse)
          )
      },
      "/api/v1/guest/manage/rsvps/{event_id}" => %PathItem{
        put:
          operation(
            "Change a guest RSVP answer",
            :guest_set_rsvp,
            [path_param(:event_id)],
            security: [%{"guestToken" => []}],
            request_body:
              body(object(%{status: %Schema{type: :string, enum: ["yes", "no", "maybe"]}})),
            response: json_response("Refreshed inventory", Schemas.GuestManageState)
          )
      },
      "/api/v1/guest/manage/claims/{claim_id}" => %PathItem{
        delete:
          operation(
            "Release a guest signup claim",
            :guest_release_claim,
            [path_param(:claim_id)],
            security: [%{"guestToken" => []}],
            response: json_response("Refreshed inventory", Schemas.GuestManageState)
          )
      },
      "/api/v1/guest/manage/subscriptions/{subscription_id}" => %PathItem{
        put:
          operation(
            "Change a newsletter subscription's cadence",
            :guest_set_cadence,
            [path_param(:subscription_id)],
            security: [%{"guestToken" => []}],
            request_body:
              body(
                object(%{cadence: %Schema{type: :string, enum: ["per_post", "daily", "weekly"]}})
              ),
            response: json_response("Refreshed inventory", Schemas.GuestManageState)
          ),
        delete:
          operation(
            "Unsubscribe from a group newsletter",
            :guest_unsubscribe,
            [path_param(:subscription_id)],
            security: [%{"guestToken" => []}],
            response: json_response("Refreshed inventory", Schemas.GuestManageState)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/newsletter" => %PathItem{
        post:
          operation(
            "Request a guest newsletter subscription — emails a confirm link (SPEC §8)",
            :newsletter_subscribe,
            [path_param(:community_slug), path_param(:group_slug)],
            security: [],
            status: 202,
            request_body: body(newsletter_body()),
            response: json_response("Confirmation email sent", Schemas.StatusResponse)
          )
      },
      "/api/v1/newsletter/confirm" => %PathItem{
        post:
          operation(
            "Confirm a newsletter subscription from the emailed link",
            :newsletter_confirm,
            [],
            security: [],
            request_body: body(token_body()),
            response: json_response("Subscribed", Schemas.GuestConfirmation)
          )
      },
      "/api/v1/public/communities" => %PathItem{
        get:
          operation(
            "The instance's community directory — communities that opted into the " <>
              "anonymous landing page via listed_on_instance (issue #260)",
            :public_communities_index,
            [],
            security: [],
            response: data_response(Schemas.Community)
          )
      },
      "/api/v1/public/communities/{community_slug}" => %PathItem{
        get:
          operation(
            "A community's public face and its public_listed groups (issue #185)",
            :public_community_show,
            [path_param(:community_slug)],
            security: [],
            response: single_response(Schemas.PublicCommunity)
          )
      },
      "/api/v1/public/communities/{community_slug}/groups/{group_slug}" => %PathItem{
        get:
          operation(
            "A publicly readable group",
            :public_group_show,
            group_params(),
            security: [],
            response: single_response(Schemas.Group)
          )
      },
      "/api/v1/public/communities/{community_slug}/groups/{group_slug}/posts" => %PathItem{
        get:
          operation(
            "A publicly readable group's feed (cursor-paginated)",
            :public_group_posts,
            group_params() ++
              [
                query_param(:after, "Opaque cursor from next_cursor"),
                query_param(:limit, "1..100, default 25")
              ],
            security: [],
            response: data_response(Schemas.Post)
          )
      },
      "/api/v1/public/communities/{community_slug}/groups/{group_slug}/posts/{post_id}" =>
        %PathItem{
          get:
            operation(
              "A single post in a publicly readable group",
              :public_post_show,
              group_params() ++ [path_param(:post_id)],
              security: [],
              response: single_response(Schemas.Post)
            )
        },
      "/api/v1/public/communities/{community_slug}/events/{event_id}" => %PathItem{
        get:
          operation(
            "An event in a publicly readable group",
            :public_event_show,
            [path_param(:community_slug), path_param(:event_id)],
            security: [],
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/public/files/{file_id}" => %PathItem{
        get:
          operation(
            "A public post attachment's display bytes (inline images, downloads otherwise)",
            :public_files_show,
            [path_param(:file_id)],
            security: [],
            response: binary_response("The file — served with its own content type")
          )
      },
      "/api/v1/public/files/{file_id}/thumbnail" => %PathItem{
        get:
          operation(
            "A public post attachment's image thumbnail (WebP)",
            :public_files_thumbnail,
            [path_param(:file_id)],
            security: [],
            response: binary_response("The thumbnail bytes")
          )
      },
      "/api/v1/public/files/{file_id}/download" => %PathItem{
        get:
          operation(
            "A public post attachment as a forced download",
            :public_files_download,
            [path_param(:file_id)],
            security: [],
            response: binary_response("The file bytes as an attachment")
          )
      },
      "/api/v1/openapi.json" => %PathItem{
        get:
          operation("This document", :openapi, [],
            security: [],
            response: json_response("The OpenAPI 3 document", object())
          )
      }
    }
  end

  defp operation(summary, operation_id, parameters, opts) do
    status = Keyword.get(opts, :status, 200)
    request_body = Keyword.get(opts, :request_body)

    error = %Reference{"$ref": "#/components/schemas/Error"} |> error_response()

    # Every operation can answer 401/403/404 with the one error
    # envelope; writes (anything with a request body) can also reject
    # the payload as malformed (400) or invalid (422), or rate-limit
    # the caller (429). Bodyless writes that can still refuse the
    # resource's state (e.g. acknowledging a post that doesn't require
    # it) declare those via `:extra_errors`.
    error_statuses =
      if request_body, do: [400, 401, 403, 404, 422, 429], else: [401, 403, 404]

    error_statuses = Enum.uniq(error_statuses ++ Keyword.get(opts, :extra_errors, []))

    responses =
      error_statuses
      |> Map.new(&{&1, error})
      |> Map.put(status, Keyword.fetch!(opts, :response))

    %Operation{
      summary: summary,
      operationId: to_string(operation_id),
      parameters: parameters,
      security: Keyword.get(opts, :security),
      requestBody: request_body,
      responses: responses
    }
  end

  defp error_response(reference) do
    %Response{
      description: "Error envelope",
      content: %{"application/json" => %MediaType{schema: reference}}
    }
  end

  defp json_response(description, schema) do
    %Response{
      description: description,
      content: %{"application/json" => %MediaType{schema: schema}}
    }
  end

  defp data_response(item_schema) do
    json_response("Data envelope", %Schema{
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: item_schema},
        next_cursor: %Schema{type: :string, nullable: true}
      },
      required: [:data]
    })
  end

  # A single created/fetched resource: `data` is one object, never an
  # array, never cursored (issue #154 — describing these with the list
  # envelope steered the generated TypeScript client toward `data[0]`
  # on non-arrays).
  defp single_response(item_schema) do
    json_response("Data envelope", %Schema{
      type: :object,
      properties: %{data: item_schema},
      required: [:data]
    })
  end

  defp body(schema) do
    %RequestBody{
      required: true,
      content: %{"application/json" => %MediaType{schema: schema}}
    }
  end

  # A body the operation works without — e.g. joining a group, where
  # only the request-approval path carries an optional message.
  defp optional_body(schema) do
    %RequestBody{
      required: false,
      content: %{"application/json" => %MediaType{schema: schema}}
    }
  end

  # The response to a role change: the target and their new role.
  defp role_change_schema do
    %Schema{
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        role: %Schema{type: :string, enum: @role_values}
      },
      required: [:user_id, :role]
    }
  end

  defp invite_params do
    object(%{
      invited_email: %Schema{
        type: :string,
        format: :email,
        nullable: true,
        description: "Delivers the invite by email and binds redemption to that address"
      },
      expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
      max_uses: %Schema{type: :integer, minimum: 1, nullable: true}
    })
  end

  defp profile_params do
    object(%{
      display_name: %Schema{type: :string, nullable: true},
      locale: %Schema{type: :string, nullable: true},
      timezone: %Schema{type: :string, nullable: true},
      digest_frequency: %Schema{
        type: :string,
        enum: ["off", "daily", "weekly"],
        nullable: true
      },
      feed_sort: %Schema{
        type: :string,
        enum: ["chronological", "activity"],
        nullable: true
      },
      bio: %Schema{type: :string, nullable: true},
      pronouns: %Schema{type: :string, nullable: true},
      contact_phone: %Schema{type: :string, nullable: true},
      contact_phone_visibility: %Schema{
        type: :string,
        enum: @contact_visibilities,
        nullable: true
      },
      contact_email: %Schema{type: :string, nullable: true},
      contact_email_visibility: %Schema{
        type: :string,
        enum: @contact_visibilities,
        nullable: true
      },
      contact_note: %Schema{type: :string, nullable: true},
      contact_note_visibility: %Schema{
        type: :string,
        enum: @contact_visibilities,
        nullable: true
      }
    })
  end

  # The one non-JSON request in the API: the feed-attachment upload.
  defp multipart_body do
    %RequestBody{
      required: true,
      content: %{
        "multipart/form-data" => %MediaType{
          schema:
            object(%{
              file: %Schema{type: :string, format: :binary},
              transient: %Schema{
                type: :boolean,
                nullable: true,
                description: "Skip the group file space; auto-expires in 30 days"
              }
            })
        }
      }
    }
  end

  # The file-library uploads: bytes plus an optional target folder.
  defp file_multipart_body do
    %RequestBody{
      required: true,
      content: %{
        "multipart/form-data" => %MediaType{
          schema:
            object(%{
              file: %Schema{type: :string, format: :binary},
              folder_id: %Schema{
                type: :string,
                format: :uuid,
                nullable: true,
                description: "Target folder; omit for the space root (upload only)"
              }
            })
        }
      }
    }
  end

  # The non-JSON responses: stored-file bytes, and the single-event ICS
  # download's text/calendar.
  defp binary_response(description, media_type \\ "application/octet-stream") do
    %Response{
      description: description,
      content: %{
        media_type => %MediaType{
          schema: %Schema{type: :string, format: :binary}
        }
      }
    }
  end

  defp post_params do
    [path_param(:community_slug), path_param(:group_slug), path_param(:post_id)]
  end

  defp comment_params, do: post_params() ++ [path_param(:comment_id)]

  defp event_params, do: [path_param(:community_slug), path_param(:event_id)]

  defp event_slot_params, do: event_params() ++ [path_param(:slot_id)]

  defp event_comment_params, do: event_params() ++ [path_param(:comment_id)]

  defp group_params, do: [path_param(:community_slug), path_param(:group_slug)]

  defp file_params, do: group_params() ++ [path_param(:file_id)]

  defp folder_params, do: group_params() ++ [path_param(:folder_id)]

  defp poll_params, do: [path_param(:community_slug), path_param(:poll_id)]

  defp assignment_params, do: [path_param(:community_slug), path_param(:assignment_id)]

  defp assignment_comment_params, do: assignment_params() ++ [path_param(:comment_id)]

  defp decision_params, do: [path_param(:community_slug), path_param(:decision_id)]

  # Assignment create/edit share one body; the context enforces the
  # required title (a missing one is a 422, never a create without it).
  defp assignment_body do
    object(%{
      title: %Schema{type: :string},
      notes_markdown: %Schema{type: :string, nullable: true},
      due_at: %Schema{type: :string, format: :"date-time", nullable: true}
    })
  end

  # Filing a moderation report (issue #256): posts and comments share
  # the one body.
  defp report_body do
    object(%{
      reason: %Schema{
        type: :string,
        description: "What's wrong — the moderators see exactly this text"
      }
    })
  end

  # The tokenless guest/newsletter/setup bodies (issue #185).
  defp token_body, do: object(%{token: %Schema{type: :string}})

  defp guest_identity_body do
    object(%{
      email: %Schema{type: :string, format: :email},
      display_name: %Schema{type: :string}
    })
  end

  defp guest_rsvp_body do
    object(%{
      email: %Schema{type: :string, format: :email},
      display_name: %Schema{type: :string},
      status: %Schema{type: :string, enum: ["yes", "no", "maybe"]}
    })
  end

  defp guest_comment_body do
    object(%{
      email: %Schema{type: :string, format: :email},
      display_name: %Schema{type: :string},
      body_markdown: %Schema{type: :string}
    })
  end

  defp newsletter_body do
    object(%{
      email: %Schema{type: :string, format: :email},
      display_name: %Schema{type: :string},
      cadence: %Schema{type: :string, enum: ["per_post", "daily", "weekly"], nullable: true}
    })
  end

  defp setup_body do
    object(%{
      token: %Schema{type: :string},
      operator:
        object(%{
          email: %Schema{type: :string, format: :email},
          display_name: %Schema{type: :string, nullable: true}
        }),
      instance:
        object(%{
          instance_name: %Schema{type: :string, nullable: true},
          default_locale: %Schema{type: :string, enum: ["en", "da"], nullable: true},
          community_creation_policy: %Schema{
            type: :string,
            enum: ["operators_only", "any_user"],
            nullable: true
          }
        }),
      community:
        object(%{
          name: %Schema{type: :string},
          slug: %Schema{type: :string},
          accent_color: %Schema{type: :string, nullable: true}
        }),
      group: object(%{name: %Schema{type: :string}, slug: %Schema{type: :string}}),
      demo_data: %Schema{type: :boolean, nullable: true}
    })
  end

  defp object(properties \\ %{}) do
    %Schema{type: :object, properties: properties}
  end

  defp path_param(name) do
    %Parameter{name: name, in: :path, required: true, schema: %Schema{type: :string}}
  end

  defp query_param(name, description) do
    %Parameter{
      name: name,
      in: :query,
      required: false,
      description: description,
      schema: %Schema{type: :string}
    }
  end
end
