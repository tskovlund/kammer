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
            response: json_response("Instance metadata and feature discovery", object())
          )
      },
      "/api/v1/auth/request-link" => %PathItem{
        post:
          operation("Request a sign-in link", :auth_request_link, [],
            security: [],
            request_body: body(object(%{email: %Schema{type: :string, format: :email}})),
            response: json_response("Always {status: sent} — no account enumeration", object())
          )
      },
      "/api/v1/auth/exchange" => %PathItem{
        post:
          operation("Exchange magic token for device token", :auth_exchange, [],
            security: [],
            request_body:
              body(
                object(%{
                  magic_token: %Schema{type: :string},
                  device_name: %Schema{type: :string, nullable: true}
                })
              ),
            response: json_response("Device token and user", object())
          )
      },
      "/api/v1/auth/device-token" => %PathItem{
        delete:
          operation("Revoke this device token", :auth_revoke, [],
            response: json_response("Revoked", object())
          )
      },
      "/api/v1/home" => %PathItem{
        get:
          operation("Merged Home across communities", :home_show, [],
            response: json_response("Upcoming events and recent activity, labeled", object())
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
            request_body:
              body(
                object(%{
                  body_markdown: %Schema{type: :string},
                  acknowledgment_required: %Schema{type: :string, nullable: true},
                  poll: %Schema{type: :object, nullable: true}
                })
              ),
            response: data_response(Schemas.Post)
          )
      },
      "/api/v1/communities/{community_slug}/groups/{group_slug}/posts/{post_id}/comments" =>
        %PathItem{
          post:
            operation(
              "Comment on a post",
              :comments_create,
              [path_param(:community_slug), path_param(:group_slug), path_param(:post_id)],
              request_body:
                body(
                  object(%{
                    body_markdown: %Schema{type: :string},
                    parent_comment_id: %Schema{type: :string, nullable: true}
                  })
                ),
              response: data_response(Schemas.Comment)
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
            response: data_response(Schemas.Event)
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
            response: json_response("The recorded status", object())
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
    %Operation{
      summary: summary,
      operationId: to_string(operation_id),
      parameters: parameters,
      security: Keyword.get(opts, :security),
      requestBody: Keyword.get(opts, :request_body),
      responses: %{
        200 => Keyword.fetch!(opts, :response),
        401 => %Reference{"$ref": "#/components/schemas/Error"} |> error_response(),
        404 => %Reference{"$ref": "#/components/schemas/Error"} |> error_response()
      }
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
      }
    })
  end

  defp body(schema) do
    %RequestBody{
      required: true,
      content: %{"application/json" => %MediaType{schema: schema}}
    }
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
