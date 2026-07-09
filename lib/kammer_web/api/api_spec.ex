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
            "Delete a folder (managers; files fall back to the root)",
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
      "/api/v1/communities/{community_slug}/events/{event_id}/rsvp" => %PathItem{
        put:
          operation(
            "Set my RSVP",
            :events_rsvp,
            event_params(),
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

  defp event_params, do: [path_param(:community_slug), path_param(:event_id)]

  defp event_slot_params, do: event_params() ++ [path_param(:slot_id)]

  defp event_comment_params, do: event_params() ++ [path_param(:comment_id)]

  defp group_params, do: [path_param(:community_slug), path_param(:group_slug)]

  defp file_params, do: group_params() ++ [path_param(:file_id)]

  defp folder_params, do: group_params() ++ [path_param(:folder_id)]

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
