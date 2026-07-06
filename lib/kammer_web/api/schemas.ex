defmodule KammerWeb.Api.Schemas do
  @moduledoc """
  OpenAPI schemas for the JSON API (issue #30): these mirror
  `KammerWeb.Api.Serializer` field for field — the serializer is the
  wire truth, this is its published description, and the drift test in
  `test/kammer_web/api/openapi_test.exs` keeps the two honest.
  """

  alias OpenApiSpex.Schema

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Error",
      description: "The one error envelope: stable code, human message.",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, example: "not_found"},
            message: %Schema{type: :string},
            details: %Schema{type: :object, nullable: true}
          },
          required: [:code, :message]
        }
      },
      required: [:error]
    })
  end

  defmodule Community do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Community",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true}
      },
      required: [:id, :name, :slug]
    })
  end

  defmodule Group do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        visibility: %Schema{
          type: :string,
          enum: ["private", "community", "public_link", "public_listed"]
        },
        features: %Schema{type: :array, items: %Schema{type: :string}},
        sealed: %Schema{type: :boolean},
        archived: %Schema{type: :boolean}
      },
      required: [:id, :name, :slug, :visibility, :features, :sealed, :archived]
    })
  end

  defmodule Author do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Author",
      type: :object,
      nullable: true,
      properties: %{
        type: %Schema{type: :string, enum: ["user", "group"]},
        id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string}
      },
      required: [:type, :id, :display_name]
    })
  end

  defmodule Comment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Comment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        parent_comment_id: %Schema{type: :string, format: :uuid, nullable: true},
        author: Author,
        body_markdown: %Schema{type: :string, nullable: true},
        deleted: %Schema{type: :boolean},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :deleted, :inserted_at]
    })
  end

  defmodule Poll do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Poll",
      type: :object,
      nullable: true,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        multiple_choice: %Schema{type: :boolean},
        anonymous: %Schema{type: :boolean},
        closes_at: %Schema{type: :string, format: :"date-time", nullable: true},
        options: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              text: %Schema{type: :string},
              votes: %Schema{type: :integer}
            },
            required: [:id, :text, :votes]
          }
        }
      },
      required: [:id, :multiple_choice, :anonymous, :options]
    })
  end

  defmodule Post do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Post",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        author: Author,
        body_markdown: %Schema{type: :string, nullable: true},
        deleted: %Schema{type: :boolean},
        published_at: %Schema{type: :string, format: :"date-time"},
        edited_at: %Schema{type: :string, format: :"date-time", nullable: true},
        pinned: %Schema{type: :boolean},
        acknowledgment_required: %Schema{type: :boolean},
        comment_count: %Schema{type: :integer, nullable: true},
        reactions: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :integer},
          description: "Emoji → count"
        },
        poll: Poll,
        comments: %Schema{type: :array, items: Comment}
      },
      required: [:id, :group_id, :deleted, :published_at, :pinned, :acknowledgment_required]
    })
  end

  defmodule Event do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Event",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        description_markdown: %Schema{type: :string, nullable: true},
        starts_at: %Schema{type: :string, format: :"date-time"},
        ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
        all_day: %Schema{type: :boolean},
        timezone: %Schema{type: :string},
        location_name: %Schema{type: :string, nullable: true},
        location_url: %Schema{type: :string, nullable: true},
        rsvp_counts: %Schema{
          type: :object,
          properties: %{
            yes: %Schema{type: :integer},
            maybe: %Schema{type: :integer},
            no: %Schema{type: :integer}
          },
          required: [:yes, :maybe, :no]
        },
        my_rsvp: %Schema{type: :string, enum: ["yes", "no", "maybe"], nullable: true}
      },
      required: [:id, :group_id, :title, :starts_at, :all_day, :timezone, :rsvp_counts]
    })
  end
end
