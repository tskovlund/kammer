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
          "bearer" => %SecurityScheme{type: "http", scheme: "bearer"}
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
            response: json_response("Instance metadata and feature discovery", Schemas.Instance)
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
          )
      },
      "/api/v1/communities/{community_slug}/groups" => %PathItem{
        get:
          operation("Visible groups of a community", :groups_index, [path_param(:community_slug)],
            response: data_response(Schemas.Group)
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
            response: single_response(Schemas.StoredFile)
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
      "/api/v1/communities/{community_slug}/events/{event_id}" => %PathItem{
        get:
          operation(
            "Event details with my_rsvp",
            :events_show,
            [path_param(:community_slug), path_param(:event_id)],
            response: single_response(Schemas.Event)
          )
      },
      "/api/v1/communities/{community_slug}/events/{event_id}/rsvp" => %PathItem{
        put:
          operation(
            "Set my RSVP",
            :events_rsvp,
            [path_param(:community_slug), path_param(:event_id)],
            request_body:
              body(object(%{status: %Schema{type: :string, enum: ["yes", "no", "maybe"]}})),
            response:
              single_response(%Schema{
                type: :object,
                properties: %{
                  event_id: %Schema{type: :string, format: :uuid},
                  status: %Schema{type: :string, enum: ["yes", "no", "maybe"]}
                },
                required: [:event_id, :status]
              })
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

  # The non-JSON responses: stored-file bytes.
  defp binary_response(description) do
    %Response{
      description: description,
      content: %{
        "application/octet-stream" => %MediaType{
          schema: %Schema{type: :string, format: :binary}
        }
      }
    }
  end

  defp post_params do
    [path_param(:community_slug), path_param(:group_slug), path_param(:post_id)]
  end

  defp comment_params, do: post_params() ++ [path_param(:comment_id)]

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
